import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_tracking_01/main.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/views/auth/login_page.dart';

// 起動時の画面(AuthGate)が、docs/basic-design/screens.mdのとおりログインの状態に合わせて画面を切り替えることの確認。
// AuthControllerを偽物に差し替え、メイン画面(位置情報・地図・同期に依存する)の代わりに_Homeを出す

class _FakeAuthController extends AuthController {
  // ログイン状態の復元の結果。完了をテストから決める
  final Completer<AuthState> restored;

  _FakeAuthController(this.restored);

  @override
  Future<AuthState> build() => restored.future;

  // メールアドレスの@より前をユーザーIDにする
  @override
  Future<void> login({required String email, required String password}) async {
    state = AsyncData(AuthState(userId: email.split('@').first, emailVerified: true));
  }
}

// メイン画面の代わり。作り直されたか(前のユーザーの状態を引き継いでいないか)をcreatedで数える
class _Home extends StatefulWidget {
  static int created = 0;
  final String userId;

  const _Home(this.userId);

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    _Home.created++;
  }

  @override
  Widget build(BuildContext context) => Text('home: ${widget.userId}');
}

Future<_FakeAuthController> _pumpGate(WidgetTester tester, Completer<AuthState> restored) async {
  final fake = _FakeAuthController(restored);
  await tester.pumpWidget(ProviderScope(
    // 復元の失敗を自動で再試行させない(テストの終わりにタイマーが残るため)
    retry: (retryCount, error) => null,
    overrides: [authControllerProvider.overrideWith(() => fake)],
    child: MaterialApp(home: AuthGate(signedInBuilder: (userId) => _Home(userId))),
  ));
  return fake;
}

Future<void> _login(WidgetTester tester, String email) async {
  await tester.enterText(find.byKey(const Key('login_email')), email);
  await tester.enterText(find.byKey(const Key('login_password')), 'password');
  await tester.tap(find.byKey(const Key('login_submit')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => _Home.created = 0);

  testWidgets('ログイン状態の復元中はスプラッシュを出す', (tester) async {
    final restored = Completer<AuthState>();
    await _pumpGate(tester, restored);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);

    restored.complete(const AuthState());
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('未ログインならログイン画面を出す', (tester) async {
    await _pumpGate(tester, Completer()..complete(const AuthState()));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(_Home.created, 0);
  });

  testWidgets('復元に失敗した(端末の保存領域が読めない等)場合も、ログイン画面を出す', (tester) async {
    final restored = Completer<AuthState>();
    await _pumpGate(tester, restored);
    restored.completeError(Exception('storage unavailable'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('ログイン中ならメイン画面を出す', (tester) async {
    await _pumpGate(tester, Completer()..complete(const AuthState(userId: 'user-1', emailVerified: true)));
    await tester.pumpAndSettle();

    expect(find.text('home: user-1'), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
  });

  testWidgets('ログイン画面でログインすると、メイン画面に切り替わる', (tester) async {
    await _pumpGate(tester, Completer()..complete(const AuthState()));
    await tester.pumpAndSettle();

    await _login(tester, 'user-1@example.com');

    expect(find.text('home: user-1'), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
  });

  testWidgets('同じユーザーの状態が変わってもメイン画面は作り直さず、ユーザーが変わったら作り直す', (tester) async {
    final fake = await _pumpGate(tester, Completer()..complete(const AuthState(userId: 'user-1', emailVerified: true)));
    await tester.pumpAndSettle();
    expect(_Home.created, 1);

    // 再ログインが必要になった(同じユーザー)
    fake.markNeedsRelogin();
    await tester.pumpAndSettle();
    expect(find.text('home: user-1'), findsOneWidget);
    expect(_Home.created, 1);

    // 再ログインの画面から別のユーザーでログインした(ログイン画面を挟まずにユーザーが変わる)
    await fake.login(email: 'user-2@example.com', password: 'password');
    await tester.pumpAndSettle();

    expect(find.text('home: user-2'), findsOneWidget);
    expect(_Home.created, 2);
  });
}
