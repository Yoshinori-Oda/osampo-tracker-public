import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_tracking_01/auth/auth_service.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/views/auth/login_page.dart';
import 'package:test_tracking_01/views/auth/signup_page.dart';

// ログイン画面が、入力の確認・エラーの表示・再ログインのときの画面の閉じ方を正しく行うことの確認。
// APIは呼ばず、AuthControllerを偽物に差し替える

class _FakeAuthController extends AuthController {
  // ログインの結果(null: 成功、それ以外: 投げる例外)
  final Object? error;
  // 渡すと、ログインの完了をテストから決める(送信中の表示の確認用)
  final Completer<void>? pending;
  final calls = <(String, String)>[];

  _FakeAuthController({this.error, this.pending});

  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<void> login({required String email, required String password}) async {
    calls.add((email, password));
    if (pending != null) await pending!.future;
    if (error != null) throw error!;
    state = const AsyncData(AuthState(userId: 'user-1', emailVerified: true));
  }
}

final _email = find.byKey(const Key('login_email'));
final _password = find.byKey(const Key('login_password'));
final _submit = find.byKey(const Key('login_submit'));

Widget _app(_FakeAuthController fake, Widget home) => ProviderScope(
  overrides: [authControllerProvider.overrideWith(() => fake)],
  child: MaterialApp(home: home),
);

Future<void> _fillAndSubmit(WidgetTester tester, String email, String password) async {
  await tester.enterText(_email, email);
  await tester.enterText(_password, password);
  await tester.tap(_submit);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未入力なら送らずに、入力を促す', (tester) async {
    final fake = _FakeAuthController();
    await tester.pumpWidget(_app(fake, const LoginPage()));

    await _fillAndSubmit(tester, '  ', '');

    expect(fake.calls, isEmpty);
    expect(find.text('メールアドレスを入力してください'), findsOneWidget);
    expect(find.text('パスワードを入力してください'), findsOneWidget);
  });

  testWidgets('メールアドレスの前後の空白を除き、パスワードはそのまま送る', (tester) async {
    final fake = _FakeAuthController();
    await tester.pumpWidget(_app(fake, const LoginPage()));

    await _fillAndSubmit(tester, ' test@example.com ', ' pass word ');

    expect(fake.calls, [('test@example.com', ' pass word ')]);
  });

  testWidgets('送信中はボタンを押せず、終わったら戻る', (tester) async {
    final pending = Completer<void>();
    final fake = _FakeAuthController(pending: pending, error: const AuthException('invalid_credentials'));
    await tester.pumpWidget(_app(fake, const LoginPage()));

    await tester.enterText(_email, 'test@example.com');
    await tester.enterText(_password, 'password');
    await tester.tap(_submit);
    await tester.pump();

    expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
    expect(find.descendant(of: _submit, matching: find.byType(CircularProgressIndicator)), findsOneWidget);

    pending.complete();
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(_submit).onPressed, isNotNull);
    expect(fake.calls, hasLength(1));
  });

  for (final (error, message) in [
    (const AuthException('invalid_credentials', statusCode: 401), 'メールアドレスまたはパスワードが違います'),
    (const AuthException('account_disabled', statusCode: 403), 'このアカウントは停止されています'),
    (const AuthException(AuthException.network), 'サーバーに接続できませんでした。通信環境を確認してください'),
    (const AuthException('internal_error', statusCode: 500), 'ログインできませんでした(internal_error)'),
    (
      const AuthException('too_many_requests', statusCode: 429, retryAfterSeconds: 541),
      'ログインの試行回数が上限に達しました。10分後にもう一度試してください',
    ),
    (
      const AuthException('too_many_requests', statusCode: 429),
      'ログインの試行回数が上限に達しました。しばらくしてからもう一度試してください',
    ),
  ]) {
    testWidgets('エラー(${error.code})のメッセージを出し、画面に留まる', (tester) async {
      final fake = _FakeAuthController(error: error);
      await tester.pumpWidget(_app(fake, const LoginPage()));

      await _fillAndSubmit(tester, 'test@example.com', 'password');

      expect(find.text(message), findsOneWidget);
      expect(find.byType(LoginPage), findsOneWidget);
    });
  }

  testWidgets('AuthException以外の失敗も、メッセージを出して止まらない', (tester) async {
    final fake = _FakeAuthController(error: StateError('broken'));
    await tester.pumpWidget(_app(fake, const LoginPage()));

    await _fillAndSubmit(tester, 'test@example.com', 'password');

    expect(find.textContaining('予期しないエラーが発生しました'), findsOneWidget);
    expect(tester.widget<FilledButton>(_submit).onPressed, isNotNull);
  });

  testWidgets('再ログイン(バナーから開いた場合)は説明を出し、ログインしたら閉じて元の画面に戻る', (tester) async {
    final fake = _FakeAuthController();
    await tester.pumpWidget(_app(
      fake,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LoginPage(isRelogin: true)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('再ログイン'), findsOneWidget);
    expect(find.textContaining('ログイン状態が無効になったため'), findsOneWidget);

    await _fillAndSubmit(tester, 'test@example.com', 'password');

    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('新規登録の画面を開ける', (tester) async {
    final fake = _FakeAuthController();
    await tester.pumpWidget(_app(fake, const LoginPage()));

    expect(find.text('ログイン'), findsWidgets);
    expect(find.textContaining('ログイン状態が無効になったため'), findsNothing);

    await tester.tap(find.text('アカウントを新規登録する'));
    await tester.pumpAndSettle();

    expect(find.byType(SignupPage), findsOneWidget);
  });
}
