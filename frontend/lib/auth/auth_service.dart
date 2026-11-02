import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import '../repositories/tracking_repository.dart';
import '../utils/app_log.dart';
import 'auth_storage.dart';
import 'request_id_client.dart';

// APIが返したエラー(レスポンスbodyのcode)。画面で表示を分けるのに使う
class AuthException implements Exception {
  final String code;
  final int? statusCode;
  // 429(too_many_requests)のとき、再び試せるまでの秒数(Retry-Afterヘッダー)
  final int? retryAfterSeconds;

  const AuthException(this.code, {this.statusCode, this.retryAfterSeconds});

  // 通信できなかった(圏外・タイムアウト・サーバーに届かない)
  static const network = 'network';

  @override
  String toString() => 'AuthException($code, $statusCode)';
}

// ログイン・新規登録の結果
class AuthResult {
  final String userId;
  final bool emailVerified;

  const AuthResult({required this.userId, required this.emailVerified});
}

enum RefreshOutcome {
  // 新しいトークンに更新できた
  refreshed,
  // サーバーが拒否した(invalid_refresh_token)。再ログインが必要
  rejected,
  // 通信できなかった。ログイン状態はそのまま(次の機会に再び試す)
  failed,
}

/// 認証(ログイン・新規登録・トークンの更新・ログアウト・アカウントの削除)とローカルアカウント(作成・切り替え・削除・通常との相互の変更)。
/// サーバー側の仕様はbackend/docs/API設計ドラフト.mdの「認証のendpoints」、端末側の約束は
/// frontend/docs/ユーザー機能追加に伴う変更予定.mdの「認証(ブロック2)」「ローカルアカウント」
class AuthService {
  final AppDatabase _db;
  final AuthStorage _storage;
  final http.Client _client;
  final String _baseUrl;
  // 通常のアカウントでログイン中ならそのユーザーとトークン
  StoredAuth? _current;
  // ローカルアカウントで入っているならそのユーザーID(_currentとどちらか一方だけが入る)
  String? _localUserId;
  Future<RefreshOutcome>? _refreshing;

  static const Duration _timeoutDuration = Duration(seconds: 5);
  // アカウントの削除はサーバーで記録をまとめて消すので時間がかかる。待ちきれずに諦めると、サーバーでは削除が済んだのに
  // 端末のデータが残ってしまうため、長めに待つ
  static const Duration _deleteAccountTimeoutDuration = Duration(seconds: 30);
  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  AuthService(this._db, this._storage, {http.Client? client, String? baseUrl})
    : _client = client ?? RequestIdClient(),
      _baseUrl = baseUrl ?? TrackingRepository.defaultBaseUrl;

  // 初回起動時に作るローカルアカウントの表示名
  static const defaultLocalDisplayName = 'ローカル';

  String? get userId => _current?.userId ?? _localUserId;
  String? get accessToken => _current?.accessToken;
  bool get isLocal => _localUserId != null;

  /// 起動時に、保存してある今のユーザーを読み込む。今のユーザーのIDを返す(未ログインならnull)。
  /// 端末にユーザーが1人もいない(初回起動)なら、ローカルアカウントを作って入る
  Future<String?> restore() async {
    _current = null;
    _localUserId = null;
    final userId = await _storage.readCurrentUserId();
    if (userId == null) {
      if (await _db.hasAnyUser()) return null;
      return createLocalAccount(defaultLocalDisplayName);
    }
    final user = await _db.getUser(userId);
    if (user != null && user.isLocal) {
      _localUserId = userId;
      return userId;
    }
    // 通常のアカウントはトークンと端末のユーザーの行が揃っていなければ未ログインとして扱う
    final stored = await _storage.read();
    if (user == null || stored == null || stored.userId != userId) {
      await _storage.clear();
      return null;
    }
    _current = stored;
    return userId;
  }

  /// ローカルアカウントを作って入る。作ったユーザーのIDを返す
  Future<String> createLocalAccount(String displayName) async {
    final id = const Uuid().v4();
    await _db.createLocalUser(id: id, displayName: displayName);
    await switchToLocalAccount(id);
    return id;
  }

  /// ローカルアカウントに切り替える。通常のアカウントでログイン中は使えない(先にログアウトする)
  Future<void> switchToLocalAccount(String userId) async {
    if (_current != null) throw StateError('logout before switching to a local account');
    await _storage.saveLocalUser(userId);
    _localUserId = userId;
  }

  /// ローカルアカウントとその記録を端末から消す。今のユーザーなら未ログインになる
  Future<void> deleteLocalAccount(String userId) async {
    final user = await _db.getUser(userId);
    if (user == null || !user.isLocal) return;
    await _db.deleteUserData(userId);
    if (_localUserId == userId) {
      await _storage.clear();
      _localUserId = null;
    }
  }

  /// ログインする。mergeLocalAccountなら、今のローカルアカウントの記録をそのアカウントに移す(ローカル→通常)
  Future<AuthResult> login({required String email, required String password, bool mergeLocalAccount = false}) {
    return _authenticate(
      '/auth/login',
      {'email': email, 'password': password},
      mergeLocalAccount: mergeLocalAccount,
    );
  }

  /// 新規登録する。mergeLocalAccountなら、今のローカルアカウントの記録を新しいアカウントに移す(ローカル→通常)
  Future<AuthResult> signup({
    required String email,
    required String password,
    String? displayName,
    bool mergeLocalAccount = false,
  }) {
    return _authenticate(
      '/auth/signup',
      {
        'email': email,
        'password': password,
        if (displayName != null && displayName.trim().isNotEmpty) 'display_name': displayName.trim(),
      },
      mergeLocalAccount: mergeLocalAccount,
    );
  }

  // APIを呼び、成功したら端末のユーザーの行を作って(記録を移す場合はここで移す)からトークンと今のユーザーを保存する。
  // 端末の書き換えの前に落ちても、今のユーザーは元のまま(サーバーに残るログイン状態はリフレッシュトークンの期限で無効になる)
  Future<AuthResult> _authenticate(String path, Map<String, dynamic> body, {bool mergeLocalAccount = false}) async {
    final mergeFrom = mergeLocalAccount ? _localUserId : null;
    if (mergeLocalAccount && mergeFrom == null) throw StateError('no local account to merge');
    final payload = {...body, 'device_id': await _storage.deviceId()};
    final http.Response response;
    try {
      response = await _client
        .post(Uri.parse('$_baseUrl$path'), headers: _jsonHeaders, body: jsonEncode(payload))
        .timeout(_timeoutDuration);
    } catch (e) {
      // 接続先の誤り(実機・Androidエミュレータのlocalhost)・平文HTTPの禁止・タイムアウト等を見分けるため、原因を出す
      appLog('auth', '$path failed ($_baseUrl)', error: e);
      throw const AuthException(AuthException.network);
    }
    if (response.statusCode ~/ 100 != 2) {
      throw _exceptionFrom(response);
    }

    final tokens = json.decode(response.body) as Map<String, dynamic>;
    final user = tokens['user'] as Map<String, dynamic>;
    // sessions.user_idの外部キーのため、ユーザーの行を先に作ってからログイン状態を保存する
    await _db.saveServerUser(
      id: user['id'] as String,
      email: user['email'] as String,
      displayName: user['display_name'] as String,
      emailVerified: user['email_verified'] as bool,
      mergeFromLocalUserId: mergeFrom,
    );
    await _saveTokens(userId: user['id'] as String, tokens: tokens);
    _localUserId = null;
    return AuthResult(userId: user['id'] as String, emailVerified: user['email_verified'] as bool);
  }

  Future<void> _saveTokens({required String userId, required Map<String, dynamic> tokens}) async {
    final auth = StoredAuth(
      userId: userId,
      accessToken: tokens['access_token'] as String,
      refreshToken: tokens['refresh_token'] as String,
    );
    await _storage.save(auth);
    _current = auth;
  }

  /// リフレッシュトークンでトークンを更新する。同時に複数回呼ばれても、通信は1回にまとめる
  /// (使用済みのリフレッシュトークンを再び送ると、サーバーがその端末のログイン状態を無効にしてしまうため)
  Future<RefreshOutcome> refreshTokens() {
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<RefreshOutcome> _refresh() async {
    final current = _current;
    if (current == null) return RefreshOutcome.rejected;
    final http.Response response;
    try {
      response = await _client
        .post(
          Uri.parse('$_baseUrl/auth/refresh'),
          headers: _jsonHeaders,
          body: jsonEncode({'refresh_token': current.refreshToken}),
        )
        .timeout(_timeoutDuration);
    } catch (e) {
      appLog('auth', '/auth/refresh failed', error: e);
      return RefreshOutcome.failed;
    }
    if (response.statusCode == 200) {
      await _saveTokens(userId: current.userId, tokens: json.decode(response.body) as Map<String, dynamic>);
      return RefreshOutcome.refreshed;
    }
    return response.statusCode == 401 ? RefreshOutcome.rejected : RefreshOutcome.failed;
  }

  /// サーバーの自分の情報(メールアドレスの確認状態など)を取り込む。取り込めたらtrue
  Future<bool> refreshProfile(http.Client authorizedClient) async {
    final current = _current;
    if (current == null) return false;
    try {
      final response = await authorizedClient
        .get(Uri.parse('$_baseUrl/users/me'), headers: {'Accept': 'application/json'})
        .timeout(_timeoutDuration);
      if (response.statusCode != 200) return false;
      final user = json.decode(response.body) as Map<String, dynamic>;
      await _db.upsertUser(
        id: current.userId,
        email: user['email'] as String,
        displayName: user['display_name'] as String,
        emailVerified: user['email_verified'] as bool,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// メールアドレスの確認コードを(再)発行する(サーバーがメールを送る)。次に再発行できるまでの秒数を返す。
  /// 確認済みなら`email_already_verified`、間隔・回数の上限なら`too_many_requests`(retryAfterSecondsに待つ秒数)の
  /// AuthExceptionを投げる。仕様はbackend/docs/API設計ドラフト.mdの「メールアドレスの確認のendpoints」
  Future<int> sendVerificationCode(http.Client authorizedClient) async {
    final http.Response response;
    try {
      response = await authorizedClient
        .post(Uri.parse('$_baseUrl/users/me/email-verification'), headers: {'Accept': 'application/json'})
        .timeout(_timeoutDuration);
    } catch (_) {
      throw const AuthException(AuthException.network);
    }
    if (response.statusCode != 202) {
      throw _exceptionFrom(response);
    }
    final body = json.decode(response.body) as Map<String, dynamic>;
    return body['resend_available_in'] as int;
  }

  /// 確認コードを送って照合する。合っていれば、レスポンスのユーザー情報(確認済み)を端末のDBに書く。
  /// 違う・期限切れ等はAuthException(`invalid_verification_code`・`verification_code_expired`等)を投げる
  Future<void> confirmVerificationCode(http.Client authorizedClient, String code) async {
    final current = _current;
    if (current == null) return;
    final http.Response response;
    try {
      response = await authorizedClient
        .post(
          Uri.parse('$_baseUrl/users/me/email-verification/confirm'),
          headers: _jsonHeaders,
          body: jsonEncode({'code': code}),
        )
        .timeout(_timeoutDuration);
    } catch (_) {
      throw const AuthException(AuthException.network);
    }
    if (response.statusCode != 200) {
      throw AuthException(_errorCode(response) ?? 'unknown', statusCode: response.statusCode);
    }
    final user = json.decode(response.body) as Map<String, dynamic>;
    await _db.upsertUser(
      id: current.userId,
      email: user['email'] as String,
      displayName: user['display_name'] as String,
      emailVerified: user['email_verified'] as bool,
    );
  }

  /// パスワードを変える。現在のパスワードが違えば`invalid_current_password`のAuthExceptionを投げる。
  /// サーバーはこの端末以外のログイン状態を無効にする(この端末はログインしたまま)
  Future<void> changePassword(
    http.Client authorizedClient, {
    required String currentPassword,
    required String newPassword,
  }) async {
    final http.Response response;
    try {
      response = await authorizedClient
        .put(
          Uri.parse('$_baseUrl/users/me/password'),
          headers: _jsonHeaders,
          body: jsonEncode({'current_password': currentPassword, 'new_password': newPassword}),
        )
        .timeout(_timeoutDuration);
    } catch (_) {
      throw const AuthException(AuthException.network);
    }
    if (response.statusCode != 204) {
      throw _exceptionFrom(response);
    }
  }

  /// 表示名を変える。成功したら端末のユーザーにも書く
  Future<void> updateDisplayName(http.Client authorizedClient, String displayName) async {
    final current = _current;
    if (current == null) return;
    final http.Response response;
    try {
      response = await authorizedClient
        .patch(
          Uri.parse('$_baseUrl/users/me'),
          headers: _jsonHeaders,
          body: jsonEncode({'display_name': displayName}),
        )
        .timeout(_timeoutDuration);
    } catch (_) {
      throw const AuthException(AuthException.network);
    }
    if (response.statusCode != 200) {
      throw AuthException(_errorCode(response) ?? 'unknown', statusCode: response.statusCode);
    }
    final user = json.decode(response.body) as Map<String, dynamic>;
    await _db.upsertUser(
      id: current.userId,
      email: user['email'] as String,
      displayName: user['display_name'] as String,
      emailVerified: user['email_verified'] as bool,
    );
  }

  /// ログアウトする。サーバーでその端末のログイン状態を無効にし(失敗しても続ける)、端末のトークンを消す。
  /// ローカルのデータはそのユーザーのものとして残す。
  /// アクセストークンが期限切れなら、AuthorizedClientが更新してから送り直す(API設計ドラフト.mdの「POST /auth/logout」)
  Future<void> logout(http.Client authorizedClient) async {
    if (_current != null) {
      try {
        await authorizedClient
          .post(Uri.parse('$_baseUrl/auth/logout'))
          .timeout(_timeoutDuration);
      } catch (_) {
        // 圏外等でもログアウトは進める(サーバーのログイン状態は、リフレッシュトークンの期限切れで無効になる)。
        // トークンの更新が拒否された場合は、サーバーのログイン状態は既に無効なので、端末のトークンを消すだけでよい
      }
    }
    await _storage.clear();
    _current = null;
  }

  /// アカウントを削除する(サーバーで物理削除し、成功したら端末のそのユーザーのデータも消す)。
  /// 401(トークンの更新も拒否された場合を含む)も削除済みとみなして端末のデータを消す。前回の削除がサーバーでは済んだのに
  /// 結果が届かなかった場合、ログイン状態もユーザーも消えているので、押し直すと401になる(ログインし直すこともできない)。
  /// 自分のアカウントにしか届かない操作で、別の端末での同時の操作も想定しないため、401を削除済みとして扱ってよいとした
  Future<void> deleteAccount(http.Client authorizedClient) async {
    final current = _current;
    if (current == null) return;
    await _deleteServerAccount(authorizedClient);
    await _db.deleteUserData(current.userId);
    await _storage.clear();
    _current = null;
  }

  /// 通常のアカウントをローカルアカウントにする。サーバーのアカウントを削除し(アカウントの削除と同じく401も削除済みとみなす)、
  /// 端末の記録はローカルアカウントのものとして残す。ユーザーIDは変わらない
  Future<void> convertToLocal(http.Client authorizedClient) async {
    final current = _current;
    if (current == null) return;
    await _deleteServerAccount(authorizedClient);
    await _db.convertToLocalUser(current.userId);
    await _storage.saveLocalUser(current.userId);
    _current = null;
    _localUserId = current.userId;
  }

  // DELETE /users/me。204と401は削除済みとして戻り、それ以外はAuthExceptionを投げる
  Future<void> _deleteServerAccount(http.Client authorizedClient) async {
    final http.Response response;
    try {
      response = await authorizedClient
        .delete(Uri.parse('$_baseUrl/users/me'))
        .timeout(_deleteAccountTimeoutDuration);
    } catch (_) {
      throw const AuthException(AuthException.network);
    }
    if (response.statusCode != 204 && response.statusCode != 401) {
      throw AuthException(_errorCode(response) ?? 'unknown', statusCode: response.statusCode);
    }
  }

  // エラーのレスポンスをAuthExceptionにする。429(too_many_requests)なら待つ秒数(Retry-After)も入れる
  AuthException _exceptionFrom(http.Response response) => AuthException(
    _errorCode(response) ?? 'unknown',
    statusCode: response.statusCode,
    retryAfterSeconds: int.tryParse(response.headers['retry-after'] ?? ''),
  );

  String? _errorCode(http.Response response) {
    try {
      final body = json.decode(response.body);
      return body is Map<String, dynamic> ? body['code'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  void dispose() => _client.close();
}
