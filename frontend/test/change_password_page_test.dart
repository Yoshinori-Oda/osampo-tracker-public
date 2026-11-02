import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_tracking_01/auth/auth_service.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/views/auth/change_password_page.dart';

// パスワードの変更画面が、docs/design/screens.mdの「auth/change_password_page.dart」の仕様どおりに動くことの確認。
// APIは呼ばず、AuthControllerを偽物に差し替える

class _FakeAuthController extends AuthController {
  // 変更の結果(null: 成功、AuthException: エラー)
  final AuthException? result;
  final calls = <(String, String)>[];

  _FakeAuthController({this.result});

  @override
  Future<AuthState> build() async => const AuthState(userId: 'user-1', emailVerified: true);

  @override
  Future<void> changePassword({required String currentPassword, required String newPassword}) async {
    calls.add((currentPassword, newPassword));
    if (result != null) throw result!;
  }
}

final _current = find.byKey(const Key('change_password_current'));
final _new = find.byKey(const Key('change_password_new'));
final _confirm = find.byKey(const Key('change_password_confirm'));
final _submit = find.byKey(const Key('change_password_submit'));

Future<void> _open(WidgetTester tester, _FakeAuthController fake) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authControllerProvider.overrideWith(() => fake)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _fillAndSubmit(WidgetTester tester, String current, String newPassword, String confirm) async {
  await tester.enterText(_current, current);
  await tester.enterText(_new, newPassword);
  await tester.enterText(_confirm, confirm);
  await tester.tap(_submit);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('成功したら画面を閉じてスナックバーを出す', (tester) async {
    final fake = _FakeAuthController();
    await _open(tester, fake);

    await _fillAndSubmit(tester, 'old-password', 'new-password', 'new-password');

    expect(fake.calls, [('old-password', 'new-password')]);
    expect(find.byType(ChangePasswordPage), findsNothing);
    expect(find.text('パスワードを変更しました。他の端末はログインし直しになります'), findsOneWidget);
  });

  testWidgets('入力が足りなければ送らない(未入力・短すぎる・確認と一致しない)', (tester) async {
    final fake = _FakeAuthController();
    await _open(tester, fake);

    await _fillAndSubmit(tester, '', 'short', 'different');

    expect(fake.calls, isEmpty);
    expect(find.text('現在のパスワードを入力してください'), findsOneWidget);
    expect(find.text('パスワードは8文字以上にしてください'), findsOneWidget);
    expect(find.text('新しいパスワードと一致しません'), findsOneWidget);
    expect(find.byType(ChangePasswordPage), findsOneWidget);
  });

  testWidgets('現在のパスワードが違えば、その欄の下に出して画面は閉じない', (tester) async {
    final fake = _FakeAuthController(result: const AuthException('invalid_current_password', statusCode: 400));
    await _open(tester, fake);

    await _fillAndSubmit(tester, 'wrong-password', 'new-password', 'new-password');

    expect(find.text('現在のパスワードが違います'), findsOneWidget);
    expect(find.byType(ChangePasswordPage), findsOneWidget);
  });

  testWidgets('通信できなければ画面にエラーを出す', (tester) async {
    final fake = _FakeAuthController(result: const AuthException(AuthException.network));
    await _open(tester, fake);

    await _fillAndSubmit(tester, 'old-password', 'new-password', 'new-password');

    expect(find.text('サーバーに接続できませんでした。通信環境を確認してください'), findsOneWidget);
  });

  testWidgets('試行回数の上限(429)なら、いつ試せるかを画面に出す', (tester) async {
    final fake = _FakeAuthController(
      result: const AuthException('too_many_requests', statusCode: 429, retryAfterSeconds: 900),
    );
    await _open(tester, fake);

    await _fillAndSubmit(tester, 'old-password', 'new-password', 'new-password');

    expect(find.text('現在のパスワードの入力の回数が上限に達しました。15分後にもう一度試してください'), findsOneWidget);
    expect(find.byType(ChangePasswordPage), findsOneWidget);
  });
}
