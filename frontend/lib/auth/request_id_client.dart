import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../utils/app_log.dart';

/// リクエストごとにリクエストID(UUID)を作ってX-Request-IDヘッダーで送り、端末のログに出すHTTPクライアント。
/// サーバーは同じIDをアクセスログ・アプリのログ・監査ログに残すので、端末で失敗したリクエストをサーバーのログから探せる
/// (backend/docs/API設計ドラフト.mdの「リクエストID」)。
/// - 送る前に1行出す(応答が届かずにタイムアウトした場合でも、IDが端末のログに残るように)
/// - 失敗(4xx・5xx・通信できない)したら、もう1行出す
/// bodyは出さない(位置情報・パスワードが入るため)。
class RequestIdClient extends http.BaseClient {
  static const header = 'X-Request-ID';
  static const _uuid = Uuid();

  final http.Client _inner;

  RequestIdClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final requestId = request.headers[header] ??= _uuid.v4();
    final target = '${request.method} ${request.url.path}';
    appLog('http', '$target request_id=$requestId');
    try {
      final response = await _inner.send(request);
      if (response.statusCode >= 400) {
        appLog('http', '$target failed: ${response.statusCode} request_id=$requestId');
      }
      return response;
    } catch (e) {
      appLog('http', '$target failed request_id=$requestId', error: e);
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
