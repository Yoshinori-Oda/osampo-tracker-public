import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

// ログイン中のユーザーとトークンの組。トークンとユーザーがずれないよう、まとめて保存・削除する
class StoredAuth {
  final String userId;
  final String accessToken;
  final String refreshToken;

  const StoredAuth({required this.userId, required this.accessToken, required this.refreshToken});
}

/// トークン・今のユーザー・端末IDの保存先。テストではメモリ上の実装に差し替える。
/// 今のユーザー(current_user_id)は、通常のアカウントではトークンと組で、ローカルアカウントでは単独で保存する
abstract class AuthStorage {
  /// 端末ID。初回はUUIDを生成して保存する。ログアウトしても消さない(同じ端末として扱い続けるため)
  Future<String> deviceId();

  /// 今のユーザーとトークンの組。トークンが揃っていなければnull
  Future<StoredAuth?> read();

  /// 今のユーザーのID(トークンの有無に関係なく)
  Future<String?> readCurrentUserId();

  Future<void> save(StoredAuth auth);

  /// ローカルアカウントを今のユーザーにする(トークンは消す)
  Future<void> saveLocalUser(String userId);

  /// 今のユーザーとトークンを消す(端末IDは残す)
  Future<void> clear();
}

/// secure storage(iOSのKeychain・AndroidのKeystoreで暗号化した保存領域)に保存する実装
class SecureAuthStorage implements AuthStorage {
  static const _kDeviceId = 'device_id';
  static const _kCurrentUserId = 'current_user_id';
  static const _kAccessToken = 'access_token';
  static const _kRefreshToken = 'refresh_token';

  final FlutterSecureStorage _storage;

  SecureAuthStorage({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String> deviceId() async {
    final existing = await _storage.read(key: _kDeviceId);
    if (existing != null) return existing;
    final created = const Uuid().v4();
    await _storage.write(key: _kDeviceId, value: created);
    return created;
  }

  @override
  Future<StoredAuth?> read() async {
    final userId = await _storage.read(key: _kCurrentUserId);
    final accessToken = await _storage.read(key: _kAccessToken);
    final refreshToken = await _storage.read(key: _kRefreshToken);
    if (userId == null || accessToken == null || refreshToken == null) return null;
    return StoredAuth(userId: userId, accessToken: accessToken, refreshToken: refreshToken);
  }

  @override
  Future<String?> readCurrentUserId() => _storage.read(key: _kCurrentUserId);

  @override
  Future<void> save(StoredAuth auth) async {
    await _storage.write(key: _kCurrentUserId, value: auth.userId);
    await _storage.write(key: _kAccessToken, value: auth.accessToken);
    await _storage.write(key: _kRefreshToken, value: auth.refreshToken);
  }

  @override
  Future<void> saveLocalUser(String userId) async {
    await _storage.delete(key: _kAccessToken);
    await _storage.delete(key: _kRefreshToken);
    await _storage.write(key: _kCurrentUserId, value: userId);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kCurrentUserId);
    await _storage.delete(key: _kAccessToken);
    await _storage.delete(key: _kRefreshToken);
  }
}
