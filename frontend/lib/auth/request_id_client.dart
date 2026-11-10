import 'package:http/http.dart' as http;
import '../utils/app_log.dart';

/// 通信のたびに端末のログに出し、応答のリクエストID(X-Request-ID)を記録するHTTPクライアント。
/// リクエストIDはサーバー(リバースプロキシ)が作り、サーバーは同じIDをアクセスログ・アプリのログ・監査ログに残すので、
/// 端末の通信をサーバーのログから探せる(backend/docs/https-proxy.mdの「リクエストID」)。端末からはIDを送らない。
/// - 送る前に、時刻(UTC)を付けて1行出す(応答が届かなかった場合は、この時刻でサーバーのログを探す)
/// - 応答が届いたら、ステータスとリクエストIDを1行出す(4xx・5xxは`failed`)
/// - 通信できなかったら、時刻を付けて1行出す
/// bodyは出さない(位置情報・パスワードが入るため)。
class RequestIdClient extends http.BaseClient {
  static const header = 'X-Request-ID';

  final http.Client _inner;
  final DateTime Function() _now;

  RequestIdClient([http.Client? inner, DateTime Function()? now])
    : _inner = inner ?? http.Client(),
      _now = now ?? DateTime.now;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final target = '${request.method} ${request.url.path}';
    appLog('http', '$target at=${_timestamp()}');
    try {
      final response = await _inner.send(request);
      final requestId = response.headers[header.toLowerCase()];
      final result = response.statusCode >= 400 ? 'failed: ${response.statusCode}' : '${response.statusCode}';
      appLog('http', '$target $result request_id=$requestId');
      return response;
    } catch (e) {
      appLog('http', '$target failed at=${_timestamp()}', error: e);
      rethrow;
    }
  }

  String _timestamp() => _now().toUtc().toIso8601String();

  @override
  void close() => _inner.close();
}
