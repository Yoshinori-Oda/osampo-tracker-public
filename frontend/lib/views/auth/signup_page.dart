import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/auth_limits.dart';
import '../../auth/auth_service.dart';
import '../../providers/auth_providers.dart';
import '../../utils/delete_conflict_dialog.dart';
import '../../utils/app_log.dart';
import 'auth_error_messages.dart';
import 'email_verification_page.dart';

// 新規登録画面。登録するとそのままログインした状態になる。メールアドレスが未確認の間は、記録・閲覧はできるが同期はできない。
// mergeLocalなら、今のローカルアカウントの記録を新しいアカウントに移す(ローカル→通常)
class SignupPage extends ConsumerStatefulWidget {
  final bool mergeLocal;

  const SignupPage({super.key, this.mergeLocal = false});

  @override
  ConsumerState<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends ConsumerState<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final controller = ref.read(authControllerProvider.notifier);
      if (widget.mergeLocal) {
        await controller.signupFromLocal(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          displayName: _displayNameController.text,
        );
      } else {
        await controller.signup(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          displayName: _displayNameController.text,
        );
      }
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      // メイン画面(AuthGateが切り替える)の上に、確認コードの入力画面を開く。コードはサインアップ時にサーバーが送り済み。
      // この画面は閉じたので、アプリ全体のNavigatorで開く
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const EmailVerificationPage(afterSignup: true)),
      );
    } on AuthException catch (e) {
      // 記録を移す途中でアプリが落ちた後のやり直しでは、サーバーにアカウントができていて登録済みになるので、ログインで移すよう案内する
      setState(() => _errorMessage = widget.mergeLocal && e.code == 'email_already_registered'
        ? 'このメールアドレスは登録済みです。前の画面の「ログインして記録を移す」から移してください'
        : signupErrorMessage(e));
    } catch (e) {
      // 通信以外の失敗(端末の保存領域に書けない・レスポンスの形式が違う等)も、画面に出して止まらないようにする
      appLog('auth', 'unexpected error', error: e);
      if (mounted) setState(() => _errorMessage = '予期しないエラーが発生しました($e)');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _validatePassword(String? value) {
    final length = value?.length ?? 0;
    if (length < minPasswordLength) return 'パスワードは$minPasswordLength文字以上にしてください';
    if (length > maxPasswordLength) return 'パスワードは$maxPasswordLength文字以内にしてください';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.mergeLocal ? '新規登録して記録を移す' : '新規登録')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('signup_email'),
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'メールアドレス'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (text.isEmpty) return 'メールアドレスを入力してください';
                    if (!text.contains('@')) return 'メールアドレスの形式が正しくありません';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('signup_password'),
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'パスワード',
                    helperText: '$minPasswordLength〜$maxPasswordLength文字',
                  ),
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: _validatePassword,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('signup_display_name'),
                  controller: _displayNameController,
                  decoration: const InputDecoration(
                    labelText: '表示名(省略可)',
                    helperText: '省略するとメールアドレスの@より前になります',
                  ),
                  maxLength: maxDisplayNameLength,
                ),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('signup_submit'),
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('登録する'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
