import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_service.dart';
import 'request_id_client.dart';

/// リクエストにアクセストークン(Authorization: Bearer)を付けるHTTPクライアント。
/// - 401(token_expired): リフレッシュトークンでトークンを更新し、元のリクエストを1回だけやり直す
/// - 401(unauthenticated)・更新がサーバーに拒否された: onAuthInvalidを呼ぶ(再ログインを促す)。
///   レスポンスはそのまま返すので、呼び出し元(同期処理)は失敗として扱う
/// - 更新が通信の失敗・サーバーのエラーでできなかった: http.ClientExceptionを投げる(呼び出し元は通信の失敗として扱う)。
///   そのため、呼び出し元に401が返るのは、サーバーがこの端末のログイン状態を認めなかった場合だけになる
/// - 403(email_not_verified): onEmailNotVerifiedを呼ぶ(端末の確認状態が古かった場合に、同期を止めてバナーを出す)
class AuthorizedClient extends http.BaseClient {
  final AuthService _auth;
  final http.Client _inner;
  final void Function()? onAuthInvalid;
  final void Function()? onEmailNotVerified;

  AuthorizedClient(this._auth, {http.Client? inner, this.onAuthInvalid, this.onEmailNotVerified})
    : _inner = inner ?? RequestIdClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // やり直しのためにbodyを取っておく(このアプリはhttp.Request(bodyがバイト列)しか使わない)
    final body = request is http.Request ? request.bodyBytes : null;
    final response = await _sendWithToken(request, body);
    if (response.statusCode == 403) return _handleForbidden(response);
    if (response.statusCode != 401) return response;

    final buffered = await http.Response.fromStream(response);
    if (_errorCode(buffered) == 'token_expired') {
      final outcome = await _auth.refreshTokens();
      switch (outcome) {
        case RefreshOutcome.refreshed:
          return _sendWithToken(request, body);
        case RefreshOutcome.rejected:
          onAuthInvalid?.call();
          return _toStreamed(buffered);
        case RefreshOutcome.failed:
          throw http.ClientException('token refresh failed', request.url);
      }
    }
    // トークンが不正・ログイン状態が無効(ログアウト済み・アカウントの停止や削除)
    onAuthInvalid?.call();
    return _toStreamed(buffered);
  }

  Future<http.StreamedResponse> _handleForbidden(http.StreamedResponse response) async {
    final buffered = await http.Response.fromStream(response);
    if (_errorCode(buffered) == 'email_not_verified') onEmailNotVerified?.call();
    return _toStreamed(buffered);
  }

  Future<http.StreamedResponse> _sendWithToken(http.BaseRequest original, List<int>? body) {
    final request = http.Request(original.method, original.url)
      ..headers.addAll(original.headers)
      ..followRedirects = original.followRedirects;
    if (body != null) request.bodyBytes = body;
    final token = _auth.accessToken;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    return _inner.send(request);
  }

  http.StreamedResponse _toStreamed(http.Response response) => http.StreamedResponse(
    Stream.value(response.bodyBytes),
    response.statusCode,
    headers: response.headers,
    request: response.request,
    reasonPhrase: response.reasonPhrase,
  );

  String? _errorCode(http.Response response) {
    try {
      final body = json.decode(response.body);
      return body is Map<String, dynamic> ? body['code'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void close() => _inner.close();
}
