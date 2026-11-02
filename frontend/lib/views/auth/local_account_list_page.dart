import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/auth_service.dart';
import '../../providers/auth_providers.dart';
import '../../widgets/display_name_dialog.dart';
import 'login_page.dart';

// ローカルアカウントの選択画面。端末のローカルアカウントの一覧(タップで切り替え)と、新しいローカルアカウントの作成を出す。
// ログイン画面の「ローカルアカウントで使う」と、ローカルアカウントの設定タブの「アカウントの切り替え」から開く
// (通常のアカウントでログイン中は開かない。切り替えるにはログアウトする)。
// 切り替えはユーザーIDが変わりメイン画面が作り直されるので、収録中は開く側(設定タブ)で止める
class LocalAccountListPage extends ConsumerStatefulWidget {
  // 通常のアカウントでのログインへの導線を出すか(ログイン画面から開いた場合は出さない)
  final bool showLogin;

  const LocalAccountListPage({super.key, this.showLogin = false});

  @override
  ConsumerState<LocalAccountListPage> createState() => _LocalAccountListPageState();
}

class _LocalAccountListPageState extends ConsumerState<LocalAccountListPage> {
  bool _busy = false;

  // ユーザーが変わると起動時の画面(AuthGate)がメイン画面を作り直すので、上に重ねた画面は閉じる
  void _closeAll() => Navigator.of(context).popUntil((route) => route.isFirst);

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) _closeAll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('切り替えられませんでした($e)')));
    }
  }

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const DisplayNameDialog(
        initial: AuthService.defaultLocalDisplayName,
        title: '新しいローカルアカウント',
        submitLabel: '作成する',
      ),
    );
    if (name == null || !mounted) return;
    await _run(() => ref.read(authControllerProvider.notifier).createLocalAccount(name));
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(localUsersProvider).value ?? const [];
    final currentUserId = ref.watch(currentUserIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('ローカルアカウント')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('ローカルアカウントの記録はこの端末にだけ保存され、サーバーと同期しません。'),
          ),
          for (final user in users)
            ListTile(
              key: Key('local_account_${user.id}'),
              leading: const Icon(Icons.phone_android),
              title: Text(user.displayName.isNotEmpty ? user.displayName : '(表示名なし)'),
              trailing: user.id == currentUserId ? const Icon(Icons.check) : null,
              enabled: !_busy,
              onTap: user.id == currentUserId
                ? _closeAll
                : () => _run(() => ref.read(authControllerProvider.notifier).switchToLocalAccount(user.id)),
            ),
          ListTile(
            key: const Key('local_account_create'),
            leading: const Icon(Icons.add),
            title: const Text('新しいローカルアカウント'),
            enabled: !_busy,
            onTap: _create,
          ),
          if (widget.showLogin) ...[
            const Divider(height: 32),
            ListTile(
              key: const Key('local_account_login'),
              leading: const Icon(Icons.login),
              title: const Text('通常のアカウントでログイン'),
              subtitle: const Text('このローカルアカウントの記録は移さずに残ります'),
              enabled: !_busy,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginPage())),
            ),
          ],
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}
