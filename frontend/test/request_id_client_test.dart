import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test_tracking_01/auth/request_id_client.dart';

// RequestIdClientが、リクエストIDを送らず、応答のX-Request-IDと送った時刻を端末のログに出すことの確認
// (backend/docs/https-proxy.mdの「リクエストID」)

final _sentAt = DateTime.utc(2026, 11, 9, 1, 2, 3, 456);
const _requestId = '0123456789abcdef0123456789abcdef';

void main() {
  late List<String> logs;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    logs = [];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() => debugPrint = originalDebugPrint);

  RequestIdClient clientReturning(int status, {Map<String, String> headers = const {}, String body = ''}) {
    return RequestIdClient(
      MockClient((_) async => http.Response(body, status, headers: headers)),
      () => _sentAt,
    );
  }

  test('X-Request-IDは送らない', () async {
    late http.Request sent;
    final client = RequestIdClient(MockClient((request) async {
      sent = request;
      return http.Response('', 204);
    }));

    await client.get(Uri.parse('https://test/api/users/me'));

    expect(sent.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-request-id')));
  });

  test('送る前に時刻を、応答が届いたらステータスと応答のリクエストIDを出す', () async {
    final client = clientReturning(204, headers: {'x-request-id': _requestId});

    await client.get(Uri.parse('https://test/api/users/me'));

    expect(logs, [
      '[http] GET /api/users/me at=2026-11-09T01:02:03.456Z',
      '[http] GET /api/users/me 204 request_id=$_requestId',
    ]);
  });

  test('4xx・5xxならfailedとステータス・リクエストIDを出し、レスポンスはそのまま返す', () async {
    final client = clientReturning(500, headers: {'x-request-id': _requestId}, body: '{"code":"internal_error"}');

    final response = await client.post(Uri.parse('https://test/api/users/u1/sessions'), body: '{"secret":"x"}');

    expect(response.statusCode, 500);
    expect(logs.last, '[http] POST /api/users/u1/sessions failed: 500 request_id=$_requestId');
    // bodyはログに出さない
    expect(logs.join('\n'), isNot(contains('secret')));
  });

  test('通信できなければ時刻を付けてログに出し、例外はそのまま投げる', () async {
    final client = RequestIdClient(
      MockClient((_) async => throw http.ClientException('offline')),
      () => _sentAt,
    );

    await expectLater(client.get(Uri.parse('https://test/api/users/me')), throwsA(isA<http.ClientException>()));

    expect(logs.last, startsWith('[http] GET /api/users/me failed at=2026-11-09T01:02:03.456Z'));
    expect(logs.last, contains('offline'));
  });
}
