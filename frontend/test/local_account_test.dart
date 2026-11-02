import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/views/auth/local_account_list_page.dart';
import 'package:test_tracking_01/views/auth/login_page.dart';

// ローカルアカウントの選択画面と、ログイン画面のローカルアカウントへの導線・記録を移すログインの確認。
// 仕様はfrontend/docs/ユーザー機能追加に伴う変更予定.mdの「ローカルアカウント」。APIは呼ばず、AuthControllerを偽物に差し替える

const _currentId = 'local-1';
const _otherId = 'local-2';

class _FakeAuthController extends AuthController {
  final AuthState initial;
  final switchedTo = <String>[];
  final created = <String>[];
  final logins = <String>[];
  final mergedLogins = <String>[];

  _FakeAuthController([this.initial = const AuthState(userId: _currentId, isLocal: true)]);

  @override
  Future<AuthState> build() async => initial;

  @override
  Future<void> switchToLocalAccount(String userId) async {
    switchedTo.add(userId);
    state = AsyncData(AuthState(userId: userId, isLocal: true));
  }

  @override
  Future<void> createLocalAccount(String displayName) async {
    created.add(displayName);
    state = const AsyncData(AuthState(userId: 'local-new', isLocal: true));
  }

  @override
  Future<void> login({required String email, required String password}) async {
    logins.add(email);
    state = const AsyncData(AuthState(userId: 'user-1', emailVerified: true));
  }

  @override
  Future<void> loginFromLocal({required String email, required String password}) async {
    mergedLogins.add(email);
    state = const AsyncData(AuthState(userId: 'user-1', emailVerified: true));
  }
}

User _localUser(String id, String displayName) => User(
  id: id,
  email: '',
  displayName: displayName,
  emailVerified: false,
  createdAt: DateTime.utc(2026, 10, 1),
  isLocal: true,
);

// pageを上に重ねて開く(閉じたかどうかを確かめるため)
Future<void> _pumpAndOpen(WidgetTester tester, _FakeAuthController fake, Widget page) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => fake),
      localUsersProvider.overrideWith(
        (ref) => Stream.value([_localUser(_currentId, 'ローカル'), _localUser(_otherId, 'さんぽ用')]),
      ),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('LocalAccountListPage', () {
    testWidgets('ローカルアカウントの一覧を出し、今のアカウントに印を付ける', (tester) async {
      await _pumpAndOpen(tester, _FakeAuthController(), const LocalAccountListPage());

      expect(find.text('ローカル'), findsOneWidget);
      expect(find.text('さんぽ用'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const Key('local_account_$_currentId')), matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const Key('local_account_$_otherId')), matching: find.byIcon(Icons.check)),
        findsNothing,
      );
    });

    testWidgets('別のアカウントをタップすると切り替えて閉じる', (tester) async {
      final fake = _FakeAuthController();
      await _pumpAndOpen(tester, fake, const LocalAccountListPage());

      await tester.tap(find.byKey(const Key('local_account_$_otherId')));
      await tester.pumpAndSettle();

      expect(fake.switchedTo, [_otherId]);
      expect(find.byType(LocalAccountListPage), findsNothing);
    });

    testWidgets('新しいローカルアカウントは表示名を入れて作り、閉じる', (tester) async {
      final fake = _FakeAuthController(const AuthState());
      await _pumpAndOpen(tester, fake, const LocalAccountListPage());

      await tester.tap(find.byKey(const Key('local_account_create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('display_name_field')), '  通勤用  ');
      await tester.tap(find.byKey(const Key('display_name_save')));
      await tester.pumpAndSettle();

      expect(fake.created, ['通勤用']);
      expect(find.byType(LocalAccountListPage), findsNothing);
    });

    testWidgets('通常のアカウントでのログインへの導線は、指定しなければ出さない', (tester) async {
      await _pumpAndOpen(tester, _FakeAuthController(), const LocalAccountListPage());
      expect(find.byKey(const Key('local_account_login')), findsNothing);
    });

    testWidgets('通常のアカウントでのログインへの導線を指定すると出す', (tester) async {
      await _pumpAndOpen(tester, _FakeAuthController(), const LocalAccountListPage(showLogin: true));
      expect(find.byKey(const Key('local_account_login')), findsOneWidget);
    });
  });

  group('LoginPage', () {
    Future<void> fillAndSubmit(WidgetTester tester) async {
      await tester.enterText(find.byKey(const Key('login_email')), 'test@example.com');
      await tester.enterText(find.byKey(const Key('login_password')), 'password1');
      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();
    }

    testWidgets('「ローカルアカウントで使う」で選択画面を開く', (tester) async {
      await _pumpAndOpen(tester, _FakeAuthController(const AuthState()), const LoginPage());

      await tester.tap(find.byKey(const Key('login_use_local')));
      await tester.pumpAndSettle();

      expect(find.byType(LocalAccountListPage), findsOneWidget);
    });

    for (final (label, page) in [('再ログイン', const LoginPage(isRelogin: true)), ('記録を移す', const LoginPage(mergeLocal: true))]) {
      testWidgets('$labelのときは、ローカルアカウントへの導線を出さない', (tester) async {
        await _pumpAndOpen(tester, _FakeAuthController(), page);
        expect(find.byKey(const Key('login_use_local')), findsNothing);
      });
    }

    testWidgets('記録を移すログインは、移す先のメールアドレスを確かめてから送る', (tester) async {
      final fake = _FakeAuthController();
      await _pumpAndOpen(tester, fake, const LoginPage(mergeLocal: true));

      await fillAndSubmit(tester);
      expect(find.textContaining('test@example.com のアカウントに'), findsOneWidget);

      // キャンセルしたら送らない
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(fake.mergedLogins, isEmpty);
      expect(find.byType(LoginPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('login_submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('login_merge_confirm')));
      await tester.pumpAndSettle();

      expect(fake.mergedLogins, ['test@example.com']);
      expect(fake.logins, isEmpty);
      expect(find.byType(LoginPage), findsNothing);
    });

    testWidgets('通常のログインでは確かめずに送る', (tester) async {
      final fake = _FakeAuthController(const AuthState());
      await _pumpAndOpen(tester, fake, const LoginPage());

      await fillAndSubmit(tester);

      expect(fake.logins, ['test@example.com']);
      expect(fake.mergedLogins, isEmpty);
    });
  });
}
