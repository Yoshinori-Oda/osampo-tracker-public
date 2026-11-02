import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../auth/auth_service.dart';
import '../auth/auth_storage.dart';
import '../auth/authorized_client.dart';
import '../database/app_database.dart';
import 'tracking_providers.dart';

// ログイン状態。userIdがnullなら未ログイン(ログイン画面を出す)
class AuthState {
  final String? userId;
  // メールアドレスの確認が済んでいるか(falseなら同期しない)
  final bool emailVerified;
  // ログイン状態が無効になった(トークンの更新の拒否・ログアウト済み等)。再ログインするまで同期しない
  final bool needsRelogin;
  // ローカルアカウント(同期しない)で入っている
  final bool isLocal;

  const AuthState({this.userId, this.emailVerified = false, this.needsRelogin = false, this.isLocal = false});

  bool get signedIn => userId != null;
  bool get canSync => signedIn && !isLocal && emailVerified && !needsRelogin;

  AuthState copyWith({bool? emailVerified, bool? needsRelogin}) => AuthState(
    userId: userId,
    emailVerified: emailVerified ?? this.emailVerified,
    needsRelogin: needsRelogin ?? this.needsRelogin,
    isLocal: isLocal,
  );
}

final authStorageProvider = Provider<AuthStorage>((ref) => SecureAuthStorage());

final authServiceProvider = Provider<AuthService>((ref) {
  final service = AuthService(ref.watch(databaseProvider), ref.watch(authStorageProvider));
  ref.onDispose(service.dispose);
  return service;
});

// 同期・アカウントの操作に使う、アクセストークン付きのHTTPクライアント
final authorizedClientProvider = Provider<http.Client>((ref) {
  final client = AuthorizedClient(
    ref.watch(authServiceProvider),
    onAuthInvalid: () => ref.read(authControllerProvider.notifier).markNeedsRelogin(),
    onEmailNotVerified: () => ref.read(authControllerProvider.notifier).markEmailNotVerified(),
  );
  ref.onDispose(client.close);
  return client;
});

class AuthController extends AsyncNotifier<AuthState> {
  AuthService get _service => ref.read(authServiceProvider);

  @override
  Future<AuthState> build() async {
    final userId = await _service.restore();
    if (userId == null) return const AuthState();
    final user = await ref.read(databaseProvider).getUser(userId);
    return AuthState(userId: userId, emailVerified: user?.emailVerified ?? false, isLocal: user?.isLocal ?? false);
  }

  AuthState get _current => state.value ?? const AuthState();

  // エラーはAuthExceptionとして呼び出し元(画面)に投げる
  Future<void> login({required String email, required String password}) async {
    final result = await _service.login(email: email, password: password);
    state = AsyncData(AuthState(userId: result.userId, emailVerified: result.emailVerified));
  }

  Future<void> signup({required String email, required String password, String? displayName}) async {
    final result = await _service.signup(email: email, password: password, displayName: displayName);
    state = AsyncData(AuthState(userId: result.userId, emailVerified: result.emailVerified));
  }

  // 今のローカルアカウントの記録を、ログインした既存のアカウントに移す(ローカル→通常)。ユーザーIDが変わるので収録中は呼ばない
  Future<void> loginFromLocal({required String email, required String password}) async {
    final result = await _service.login(email: email, password: password, mergeLocalAccount: true);
    state = AsyncData(AuthState(userId: result.userId, emailVerified: result.emailVerified));
  }

  // 今のローカルアカウントの記録を、新規登録したアカウントに移す(ローカル→通常)。ユーザーIDが変わるので収録中は呼ばない
  Future<void> signupFromLocal({required String email, required String password, String? displayName}) async {
    final result = await _service.signup(
      email: email,
      password: password,
      displayName: displayName,
      mergeLocalAccount: true,
    );
    state = AsyncData(AuthState(userId: result.userId, emailVerified: result.emailVerified));
  }

  // ローカルアカウントを作って入る
  Future<void> createLocalAccount(String displayName) async {
    final userId = await _service.createLocalAccount(displayName);
    state = AsyncData(AuthState(userId: userId, isLocal: true));
  }

  // ローカルアカウントに切り替える(通常のアカウントでログイン中なら、先にログアウトしておく)
  Future<void> switchToLocalAccount(String userId) async {
    await _service.switchToLocalAccount(userId);
    state = AsyncData(AuthState(userId: userId, isLocal: true));
  }

  // ローカルアカウントを端末から消す。今のユーザーならログイン画面に戻る
  Future<void> deleteLocalAccount(String userId) async {
    await _service.deleteLocalAccount(userId);
    if (_current.userId == userId) state = const AsyncData(AuthState());
  }

  // 今のローカルアカウントの表示名を変える(端末のユーザーだけを書き換える)
  Future<void> renameLocalAccount(String displayName) async {
    final userId = _current.userId;
    if (userId == null || !_current.isLocal) return;
    await ref.read(databaseProvider).setLocalDisplayName(userId, displayName);
  }

  // 通常のアカウントをローカルアカウントにする(サーバーのアカウントを削除する)。ユーザーIDは変わらないので収録中もできる。
  // エラーはAuthExceptionとして投げる
  Future<void> convertToLocal() async {
    final userId = _current.userId;
    if (userId == null || _current.isLocal) return;
    await _service.convertToLocal(ref.read(authorizedClientProvider));
    state = AsyncData(AuthState(userId: userId, isLocal: true));
  }

  // ローカルアカウントでは同期しないので、同期の途中で受けた401(通常→ローカルの変更でサーバーのアカウントを消した直後等)は無視する
  void markNeedsRelogin() {
    if (_current.signedIn && !_current.isLocal && !_current.needsRelogin) {
      state = AsyncData(_current.copyWith(needsRelogin: true));
    }
  }

  // サーバーがメールアドレスを未確認と判断した(端末の確認状態が古かった)。確認が済むまで同期しない
  Future<void> markEmailNotVerified() async {
    final userId = _current.userId;
    if (userId == null || _current.isLocal || !_current.emailVerified) return;
    state = AsyncData(_current.copyWith(emailVerified: false));
    await ref.read(databaseProvider).setEmailVerified(userId, false);
  }

  // サーバーの自分の情報(メールアドレスの確認状態)を取り込む。起動時・フォアグラウンド復帰時に呼ぶ
  Future<void> refreshProfile() async {
    final userId = _current.userId;
    if (userId == null || _current.isLocal || _current.needsRelogin) return;
    if (!await _service.refreshProfile(ref.read(authorizedClientProvider))) return;
    final user = await ref.read(databaseProvider).getUser(userId);
    state = AsyncData(_current.copyWith(emailVerified: user?.emailVerified ?? false));
  }

  // メールアドレスの確認コードを(再)発行する。次に再発行できるまでの秒数を返す。エラーはAuthExceptionとして投げる
  Future<int> sendVerificationCode() => _service.sendVerificationCode(ref.read(authorizedClientProvider));

  // 確認コードを照合し、合っていれば確認済みにする。canSyncがtrueになるので、MainPageが止まっていた同期を再開する
  Future<void> confirmEmail(String code) async {
    await _service.confirmVerificationCode(ref.read(authorizedClientProvider), code);
    state = AsyncData(_current.copyWith(emailVerified: true));
  }

  // パスワードを変える(この端末はログインしたまま)。エラーはAuthExceptionとして投げる
  Future<void> changePassword({required String currentPassword, required String newPassword}) =>
    _service.changePassword(
      ref.read(authorizedClientProvider),
      currentPassword: currentPassword,
      newPassword: newPassword,
    );

  // 表示名を変える。端末のユーザーが更新されるので、currentUserProviderを見ている画面にも反映される
  Future<void> updateDisplayName(String displayName) =>
    _service.updateDisplayName(ref.read(authorizedClientProvider), displayName);

  Future<void> logout() async {
    await _service.logout(ref.read(authorizedClientProvider));
    state = const AsyncData(AuthState());
  }

  Future<void> deleteAccount() async {
    await _service.deleteAccount(ref.read(authorizedClientProvider));
    state = const AsyncData(AuthState());
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

// ログイン中のユーザーID。ユーザーが変わったとき(ログイン・ログアウト)だけ変わる
final currentUserIdProvider = Provider<String?>((ref) {
  return ref.watch(authControllerProvider.select((state) => state.value?.userId));
});

// 端末のローカルアカウントの一覧(アカウントの選択画面用)
final localUsersProvider = StreamProvider<List<User>>((ref) {
  return ref.watch(databaseProvider).watchLocalUsers();
});

// ログイン中のユーザーの情報(設定タブの表示用)
final currentUserProvider = StreamProvider<User?>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(null);
  return ref.watch(databaseProvider).watchUser(userId);
});
