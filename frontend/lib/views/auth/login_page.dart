import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/auth_service.dart';
import '../../providers/auth_providers.dart';
import '../../utils/app_log.dart';
import 'auth_error_messages.dart';
import 'local_account_list_page.dart';
import 'signup_page.dart';

// ログイン画面。起動時に未ログインなら表示する(ログイン・新規登録のほか、ローカルアカウントで使うこともできる)。
// 再ログインのバナーから開いた場合(isRelogin)は、ログインしたら閉じて元の画面に戻る。
// ローカルアカウントの設定タブの「通常のアカウントにする」から開いた場合(mergeLocal)は、ログインしたアカウントに
// 今のローカルアカウントの記録を移す
class LoginPage extends ConsumerStatefulWidget {
  final bool isRelogin;
  final bool mergeLocal;

  const LoginPage({super.key, this.isRelogin = false, this.mergeLocal = false});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // 記録を移すと元に戻せず、共用の端末で他人のアカウントに入ると記録が混ざるので、移す先を確かめてもらう
  Future<bool> _confirmMerge(String email) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('記録を移しますか?'),
        content: Text('$email のアカウントに、このローカルアカウントの記録を移します。元に戻せません。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('キャンセル')),
          TextButton(
            key: const Key('login_merge_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移す'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailController.text.trim();
    if (widget.mergeLocal && !await _confirmMerge(email)) return;
    if (!mounted) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final controller = ref.read(authControllerProvider.notifier);
      if (widget.mergeLocal) {
        await controller.loginFromLocal(email: email, password: _passwordController.text);
      } else {
        await controller.login(email: email, password: _passwordController.text);
      }
      if (!mounted) return;
      // ログイン状態が変わると起動時の画面(AuthGate)がメイン画面に切り替わるので、上に重ねた画面は閉じる
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on AuthException catch (e) {
      setState(() => _errorMessage = loginErrorMessage(e));
    } catch (e) {
      // 通信以外の失敗(端末の保存領域に書けない・レスポンスの形式が違う等)も、画面に出して止まらないようにする
      appLog('auth', 'unexpected error', error: e);
      if (mounted) setState(() => _errorMessage = '予期しないエラーが発生しました($e)');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isRelogin ? '再ログイン' : widget.mergeLocal ? '通常のアカウントにする' : 'ログイン')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.isRelogin)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text('ログイン状態が無効になったため、同期を止めています。ログインし直すと同期を再開します。'),
                  ),
                if (widget.mergeLocal)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text('既存のアカウントにログインして、このローカルアカウントの記録を移します。'
                      'アカウントが無ければ新規登録してください。移した後はローカルアカウントは無くなります。'),
                  ),
                TextFormField(
                  key: const Key('login_email'),
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'メールアドレス'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  validator: (value) =>
                    (value == null || value.trim().isEmpty) ? 'メールアドレスを入力してください' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('login_password'),
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: 'パスワード'),
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  validator: (value) => (value == null || value.isEmpty) ? 'パスワードを入力してください' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('login_submit'),
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.mergeLocal ? 'ログインして記録を移す' : 'ログイン'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => SignupPage(mergeLocal: widget.mergeLocal)),
                      ),
                  child: const Text('アカウントを新規登録する'),
                ),
                if (!widget.isRelogin && !widget.mergeLocal)
                  TextButton(
                    key: const Key('login_use_local'),
                    onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LocalAccountListPage())),
                    child: const Text('ローカルアカウントで使う(同期しない)'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
