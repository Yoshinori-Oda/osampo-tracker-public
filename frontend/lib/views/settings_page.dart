import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/auth_service.dart';
import '../models/recording_phase.dart';
import '../providers/auth_providers.dart';
import '../providers/tracking_providers.dart';
import 'auth/auth_error_messages.dart';
import 'auth/change_password_page.dart';
import 'auth/email_verification_page.dart';
import 'auth/local_account_list_page.dart';
import 'auth/login_page.dart';
import '../widgets/display_name_dialog.dart';

// 設定タブ。今はアカウント(表示名の編集・メールアドレスの確認・パスワードの変更・ログアウト)と、一番下のアカウントの削除のみ。
// ローカルアカウントでは、メールアドレス・パスワード・ログアウトの代わりにアカウントの切り替えと通常のアカウントへの変更を出す。
// 仕様はdocs/design/screens.mdの「settings_page.dart」
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;

  bool get _isRecording =>
    (ref.read(recordingPhaseProvider).value ?? RecordingPhase.idle) != RecordingPhase.idle;

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // 表示名の編集(収録中でもできる。収録に影響しないため)
  Future<void> _editDisplayName(String current) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => DisplayNameDialog(initial: current),
    );
    if (name == null || name == current || !mounted) return;
    setState(() => _busy = true);
    try {
      final controller = ref.read(authControllerProvider.notifier);
      if (ref.read(authControllerProvider).value?.isLocal == true) {
        await controller.renameLocalAccount(name);
      } else {
        await controller.updateDisplayName(name);
      }
    } on AuthException catch (e) {
      if (mounted) _showSnackBar(displayNameErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ログアウトの前に未同期の変更を送っておく。失敗してもログアウトは進める
  // (未同期の記録はこの端末にそのユーザーのものとして残り、次にそのユーザーでログインした時に同期される)
  Future<void> _logout() async {
    if (_isRecording) {
      _showSnackBar('収録中はログアウトできません。収録を終了してから操作してください');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ログアウトしますか?'),
        content: const Text('この端末の記録は残り、もう一度ログインすると表示されます。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('ログアウト')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final synced = await ref.read(repositoryProvider).syncDiff();
    if (!mounted) return;
    if (!synced) {
      // ログアウトするとこの画面は消えるので、アプリ全体のSnackBarに出す
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('同期できなかった記録はこの端末に残り、次にログインした時に同期されます'),
      ));
    }
    // 次にログインしたユーザーの画面が収録タブから始まるようにする
    ref.read(bottomNavIndexProvider.notifier).setIndex(0);
    await ref.read(authControllerProvider.notifier).logout();
  }

  Future<void> _deleteAccount() async {
    if (_isRecording) {
      _showSnackBar('収録中はアカウントを削除できません。収録を終了してから操作してください');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('アカウントを削除しますか?'),
        content: const Text('サーバーとこの端末から、このアカウントの記録が全て削除されます。元に戻せません。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    // 削除に成功するとこの画面は消える(refが使えなくなる)ので、先に取っておく
    final bottomNav = ref.read(bottomNavIndexProvider.notifier);
    try {
      await ref.read(authControllerProvider.notifier).deleteAccount();
      bottomNav.setIndex(0);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showSnackBar(switch (e.code) {
        AuthException.network => 'サーバーに接続できなかったため、削除できませんでした',
        _ => 'アカウントを削除できませんでした(${e.code})',
      });
    }
  }

  // ローカルアカウントの切り替え(ユーザーIDが変わりメイン画面が作り直されるので、収録中はできない)
  void _switchAccount() {
    if (_isRecording) {
      _showSnackBar('収録中はアカウントを切り替えられません。収録を終了してから操作してください');
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const LocalAccountListPage(showLogin: true)),
    );
  }

  // ローカル→通常(ユーザーIDが変わりメイン画面が作り直されるので、収録中はできない)
  void _convertToNormal() {
    if (_isRecording) {
      _showSnackBar('収録中は通常のアカウントにできません。収録を終了してから操作してください');
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const LoginPage(mergeLocal: true)),
    );
  }

  Future<void> _deleteLocalAccount(String userId) async {
    if (_isRecording) {
      _showSnackBar('収録中はアカウントを削除できません。収録を終了してから操作してください');
      return;
    }
    final confirmed = await _confirmDestructive(
      title: 'ローカルアカウントを削除しますか?',
      content: 'この端末から、このアカウントの記録が全て削除されます。元に戻せません。',
      action: '削除する',
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    // 削除するとこの画面は消える(refが使えなくなる)ので、先に取っておく
    final bottomNav = ref.read(bottomNavIndexProvider.notifier);
    await ref.read(authControllerProvider.notifier).deleteLocalAccount(userId);
    bottomNav.setIndex(0);
  }

  // 通常→ローカル。ユーザーIDが変わらずメイン画面は作り直されないので、収録中もできる
  Future<void> _convertToLocal() async {
    final confirmed = await _confirmDestructive(
      title: 'ローカルアカウントにしますか?',
      content: 'サーバーのアカウントと記録を削除し、以降は同期しません。この端末の記録は残ります。'
        'このアカウントを使っている他の端末では使えなくなります。元に戻せません。',
      action: 'ローカルアカウントにする',
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    // 他の端末で記録してまだ取り込んでいないものはサーバーと一緒に消えるので、先に同期しておく
    final synced = await ref.read(repositoryProvider).syncDiff();
    if (!mounted) return;
    if (!synced) {
      final proceed = await _confirmDestructive(
        title: '同期できませんでした',
        content: 'この端末に取り込めていない記録(他の端末で記録したもの等)は失われます。続けますか?',
        action: '続ける',
      );
      if (proceed != true || !mounted) {
        if (mounted) setState(() => _busy = false);
        return;
      }
    }
    try {
      await ref.read(authControllerProvider.notifier).convertToLocal();
      if (mounted) _showSnackBar('ローカルアカウントにしました');
    } on AuthException catch (e) {
      if (mounted) {
        _showSnackBar(switch (e.code) {
          AuthException.network => 'サーバーに接続できなかったため、ローカルアカウントにできませんでした',
          _ => 'ローカルアカウントにできませんでした(${e.code})',
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmDestructive({required String title, required String content, required String action}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).value;
    final auth = ref.watch(authControllerProvider).value;
    final isLocal = auth?.isLocal == true;

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          const _SectionHeader('アカウント'),
          ListTile(
            key: const Key('settings_display_name'),
            leading: const Icon(Icons.person),
            title: Text(user?.displayName.isNotEmpty == true ? user!.displayName : '(表示名なし)'),
            subtitle: const Text('表示名(タップして変更)'),
            trailing: const Icon(Icons.edit),
            enabled: !_busy && user != null,
            onTap: user == null ? null : () => _editDisplayName(user.displayName),
          ),
          if (isLocal) ...[
            const ListTile(
              key: Key('settings_local_account'),
              leading: Icon(Icons.phone_android),
              title: Text('ローカルアカウント'),
              subtitle: Text('記録はこの端末にだけ保存され、サーバーと同期しません'),
            ),
            ListTile(
              key: const Key('settings_switch_account'),
              leading: const Icon(Icons.switch_account),
              title: const Text('アカウントの切り替え'),
              enabled: !_busy,
              onTap: _switchAccount,
            ),
            ListTile(
              key: const Key('settings_convert_to_normal'),
              leading: const Icon(Icons.cloud_upload),
              title: const Text('通常のアカウントにする'),
              subtitle: const Text('ログイン・新規登録して記録を移し、同期できるようにします'),
              enabled: !_busy,
              onTap: _convertToNormal,
            ),
          ] else ...[
            ListTile(
              key: const Key('settings_email'),
              leading: Icon(auth?.emailVerified == true ? Icons.verified : Icons.mark_email_unread),
              title: Text(user?.email ?? ''),
              subtitle: Text(
                auth?.emailVerified == true
                  ? '確認済み'
                  : '未確認(タップして確認コードを入力してください。確認が済むまで、記録はサーバーと同期されません)',
              ),
              // 未確認なら確認コードの入力画面を開く(収録中でも開ける。確認しても同期が始まるだけで収録の邪魔にならないため)
              onTap: auth?.emailVerified == true
                ? null
                : () => Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(builder: (_) => const EmailVerificationPage()),
                  ),
            ),
            ListTile(
              key: const Key('settings_change_password'),
              leading: const Icon(Icons.password),
              title: const Text('パスワードの変更'),
              enabled: !_busy,
              // 収録中でも開ける(収録に影響しないため)
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
              ),
            ),
            ListTile(
              key: const Key('settings_logout'),
              leading: const Icon(Icons.logout),
              title: const Text('ログアウト'),
              enabled: !_busy,
              onTap: _logout,
            ),
          ],
          // 取り返しのつかない操作なので、他の項目から離して一番下に置く
          const Divider(height: 32),
          if (!isLocal)
            ListTile(
              key: const Key('settings_convert_to_local'),
              leading: const Icon(Icons.cloud_off),
              title: const Text('ローカルアカウントにする'),
              subtitle: const Text('サーバーのアカウントを削除し、この端末の記録を残して同期をやめます'),
              enabled: !_busy,
              onTap: _convertToLocal,
            ),
          ListTile(
            key: const Key('settings_delete_account'),
            leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
            title: Text('アカウントを削除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            enabled: !_busy && user != null,
            onTap: isLocal ? () => _deleteLocalAccount(user!.id) : _deleteAccount,
          ),
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
  }
}
