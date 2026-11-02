import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_tracking_01/auth/auth_service.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/views/auth/email_verification_page.dart';

// 確認コードの入力画面が、docs/design/screens.mdの「auth/email_verification_page.dart」の仕様どおりに動くことの確認。
// APIは呼ばず、AuthControllerを偽物に差し替えて、再発行・確認の結果を順番に返す

class _FakeAuthController extends AuthController {
  // 再発行の結果(int: 次に再発行できるまでの秒数、AuthException: エラー)を前から順に返す
  final List<Object> sendResults;
  // 確認の結果(null: 成功、AuthException: エラー)を前から順に返す
  final List<AuthException?> confirmResults;
  final confirmedCodes = <String>[];
  int sendCount = 0;
  int refreshCount = 0;

  _FakeAuthController({this.sendResults = const [], this.confirmResults = const []});

  @override
  Future<AuthState> build() async => const AuthState(userId: 'user-1');

  @override
  Future<int> sendVerificationCode() async {
    final result = sendResults[sendCount++];
    if (result is AuthException) throw result;
    return result as int;
  }

  @override
  Future<void> confirmEmail(String code) async {
    final result = confirmResults[confirmedCodes.length];
    confirmedCodes.add(code);
    if (result != null) throw result;
    state = const AsyncData(AuthState(userId: 'user-1', emailVerified: true));
  }

  @override
  Future<void> refreshProfile() async => refreshCount++;
}

final _codeField = find.byKey(const Key('verification_code_field'));
final _confirmButton = find.byKey(const Key('verification_confirm'));
final _resendButton = find.byKey(const Key('verification_resend'));

bool _enabled(WidgetTester tester, Finder button) =>
  tester.widget<ButtonStyleButton>(button).onPressed != null;

String _resendLabel(WidgetTester tester) =>
  (tester.widget<ButtonStyleButton>(_resendButton).child as Text).data!;

// 前の画面からpushして確認画面を開く(閉じたことを確かめられるように)
Future<void> _open(WidgetTester tester, _FakeAuthController fake, {bool afterSignup = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => fake),
        currentUserProvider.overrideWith((ref) => Stream.value(null)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => EmailVerificationPage(afterSignup: afterSignup)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  // 画面の切り替えのアニメーション(1秒未満なので、カウントダウンは進まない)
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('入力', () {
    testWidgets('数字だけを6桁まで受け付け、6桁そろうまで確認ボタンを押せない', (tester) async {
      await _open(tester, _FakeAuthController());

      await tester.enterText(_codeField, '12ab34');
      await tester.pump();
      expect(tester.widget<TextField>(_codeField).controller!.text, '1234');
      expect(_enabled(tester, _confirmButton), isFalse);

      await tester.enterText(_codeField, '1234567');
      await tester.pump();
      expect(tester.widget<TextField>(_codeField).controller!.text, '123456');
      expect(_enabled(tester, _confirmButton), isTrue);
    });

    testWidgets('6桁そろっても自動では送らない', (tester) async {
      final fake = _FakeAuthController(confirmResults: [null]);
      await _open(tester, fake);

      await tester.enterText(_codeField, '123456');
      await tester.pump();

      expect(fake.confirmedCodes, isEmpty);
    });
  });

  group('確認', () {
    testWidgets('成功したら画面を閉じてスナックバーを出す', (tester) async {
      final fake = _FakeAuthController(confirmResults: [null]);
      await _open(tester, fake);

      await tester.enterText(_codeField, '012345');
      await tester.pump();
      await _tapAndSettle(tester, _confirmButton);

      expect(fake.confirmedCodes, ['012345']);
      expect(find.byType(EmailVerificationPage), findsNothing);
      expect(find.text('メールアドレスを確認しました'), findsOneWidget);
    });

    testWidgets('コードが違えば入力欄の下に出し、画面は閉じない', (tester) async {
      final fake = _FakeAuthController(confirmResults: [const AuthException('invalid_verification_code')]);
      await _open(tester, fake);

      await tester.enterText(_codeField, '999999');
      await tester.pump();
      await _tapAndSettle(tester, _confirmButton);

      expect(find.text('コードが違います'), findsOneWidget);
      expect(find.byType(EmailVerificationPage), findsOneWidget);
    });

    testWidgets('期限切れなら再発行を促す', (tester) async {
      final fake = _FakeAuthController(confirmResults: [const AuthException('verification_code_expired')]);
      await _open(tester, fake);

      await tester.enterText(_codeField, '123456');
      await tester.pump();
      await _tapAndSettle(tester, _confirmButton);

      expect(
        find.text('有効期限が切れたか、入力の回数の上限に達しました。コードを再発行してください'),
        findsOneWidget,
      );
    });
  });

  group('再発行', () {
    testWidgets('画面を開いただけでは送らない。サインアップの直後以外は「あとで」を出さない', (tester) async {
      final fake = _FakeAuthController();
      await _open(tester, fake);

      expect(fake.sendCount, 0);
      expect(_enabled(tester, _resendButton), isTrue);
      expect(find.byKey(const Key('verification_later')), findsNothing);
    });

    testWidgets('サインアップの直後は60秒のカウントダウンから始まり、「あとで」で閉じられる', (tester) async {
      await _open(tester, _FakeAuthController(), afterSignup: true);

      expect(_enabled(tester, _resendButton), isFalse);
      expect(_resendLabel(tester), 'コードを再発行(あと60秒)');

      await tester.pump(const Duration(seconds: 1));
      expect(_resendLabel(tester), 'コードを再発行(あと59秒)');

      await tester.pump(const Duration(seconds: 59));
      expect(_enabled(tester, _resendButton), isTrue);
      expect(_resendLabel(tester), 'コードを再発行');

      await _tapAndSettle(tester, find.byKey(const Key('verification_later')));
      expect(find.byType(EmailVerificationPage), findsNothing);
    });

    testWidgets('再発行したら、レスポンスの秒数からカウントダウンする', (tester) async {
      final fake = _FakeAuthController(sendResults: [60]);
      await _open(tester, fake);

      await _tapAndSettle(tester, _resendButton);

      expect(fake.sendCount, 1);
      expect(find.text('コードを送りました。メールを確認してください'), findsOneWidget);
      expect(_enabled(tester, _resendButton), isFalse);
      expect(_resendLabel(tester), 'コードを再発行(あと60秒)');
    });

    testWidgets('429なら時間をあけるよう表示し、Retry-Afterの秒数が過ぎたら押せるようになる', (tester) async {
      final fake = _FakeAuthController(
        sendResults: [const AuthException('too_many_requests', statusCode: 429, retryAfterSeconds: 30)],
      );
      await _open(tester, fake);

      await _tapAndSettle(tester, _resendButton);

      // 残りの秒数は再発行のボタンにだけ出す(お知らせの文言には入れない)
      expect(find.text('再発行には時間をあけてください'), findsOneWidget);
      expect(_enabled(tester, _resendButton), isFalse);
      expect(_resendLabel(tester), 'コードを再発行(あと30秒)');

      await tester.pump(const Duration(seconds: 10));
      expect(find.text('再発行には時間をあけてください'), findsOneWidget);
      expect(_resendLabel(tester), 'コードを再発行(あと20秒)');

      await tester.pump(const Duration(seconds: 20));
      expect(find.byKey(const Key('verification_message')), findsNothing);
      expect(_enabled(tester, _resendButton), isTrue);
    });

    testWidgets('確認済み(409)なら確認状態を取り込み直して閉じる', (tester) async {
      final fake = _FakeAuthController(sendResults: [const AuthException('email_already_verified')]);
      await _open(tester, fake);

      await _tapAndSettle(tester, _resendButton);

      expect(fake.refreshCount, 1);
      expect(find.byType(EmailVerificationPage), findsNothing);
      expect(find.text('メールアドレスは確認済みです'), findsOneWidget);
    });
  });
}
