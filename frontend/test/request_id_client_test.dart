import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test_tracking_01/auth/request_id_client.dart';

// RequestIdClientが、リクエストごとにX-Request-IDを付け、失敗したらそのIDを端末のログに出すことの確認
// (backend/docs/API設計ドラフト.mdの「リクエストID」)

final _uuidPattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  late List<String> logs;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    logs = [];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() => debugPrint = originalDebugPrint);

  test('リクエストごとに別のUUIDをX-Request-IDで送る', () async {
    final sent = <http.Request>[];
    final client = RequestIdClient(MockClient((request) async {
      sent.add(request);
      return http.Response('', 204);
    }));

    await client.get(Uri.parse('http://test/api/users/me'));
    await client.get(Uri.parse('http://test/api/users/me'));

    final ids = sent.map((r) => r.headers[RequestIdClient.header]!).toList();
    expect(ids, everyElement(matches(_uuidPattern)));
    expect(ids.toSet(), hasLength(2));
    // 送る前にIDを出す(応答が届かなかった場合でも、IDが残るように)
    expect(logs, ['[http] GET /api/users/me request_id=${ids[0]}', '[http] GET /api/users/me request_id=${ids[1]}']);
  });

  test('既にX-Request-IDが付いていれば、そのまま送る', () async {
    late http.Request sent;
    final client = RequestIdClient(MockClient((request) async {
      sent = request;
      return http.Response('', 204);
    }));

    await client.get(Uri.parse('http://test/health'), headers: {RequestIdClient.header: 'given-request-id'});

    expect(sent.headers[RequestIdClient.header], 'given-request-id');
  });

  test('4xx・5xxならステータスとリクエストIDをログに出し、レスポンスはそのまま返す', () async {
    final client = RequestIdClient(MockClient((_) async => http.Response('{"code":"internal_error"}', 500)));

    final response = await client.post(Uri.parse('http://test/api/users/u1/sessions'), body: '{"secret":"x"}');

    expect(response.statusCode, 500);
    final requestId = RegExp(r'request_id=(\S+)').firstMatch(logs.first)!.group(1);
    expect(logs.last, '[http] POST /api/users/u1/sessions failed: 500 request_id=$requestId');
    // bodyはログに出さない
    expect(logs.join('\n'), isNot(contains('secret')));
  });

  test('通信できなければリクエストIDをログに出して、例外はそのまま投げる', () async {
    final client = RequestIdClient(MockClient((_) async => throw http.ClientException('offline')));

    await expectLater(client.get(Uri.parse('http://test/api/users/me')), throwsA(isA<http.ClientException>()));

    expect(logs.last, startsWith('[http] GET /api/users/me failed request_id='));
    expect(logs.last, contains('offline'));
  });
}
