import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/auth_limits.dart';
import '../../auth/auth_service.dart';
import '../../providers/auth_providers.dart';
import 'auth_error_messages.dart';

// パスワードの変更画面(設定タブから開く)。仕様はdocs/design/screens.mdの「auth/change_password_page.dart」、
// APIはbackend/docs/API設計ドラフト.mdの「PUT /users/me/password」
class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  ConsumerState<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  // 入力したパスワードを見えるようにするか(3つの欄で共通)
  bool _showPasswords = false;
  bool _submitting = false;
  // 現在のパスワードの欄の下に出すエラー(サーバーが「違う」と返した)
  String? _currentError;
  String? _errorMessage;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _currentError = null;
      _errorMessage = null;
    });
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      await ref.read(authControllerProvider.notifier).changePassword(
        currentPassword: _currentController.text,
        newPassword: _newController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('パスワードを変更しました。他の端末はログインし直しになります')),
      );
      Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'invalid_current_password') {
          _currentError = changePasswordErrorMessage(e);
        } else {
          _errorMessage = changePasswordErrorMessage(e);
        }
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _validateNewPassword(String? value) {
    final length = value?.length ?? 0;
    if (length < minPasswordLength) {
      return 'パスワードは$minPasswordLength文字以上にしてください';
    }
    if (length > maxPasswordLength) {
      return 'パスワードは$maxPasswordLength文字以内にしてください';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('パスワードの変更')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('change_password_current'),
                  controller: _currentController,
                  decoration: InputDecoration(labelText: '現在のパスワード', errorText: _currentError),
                  obscureText: !_showPasswords,
                  autofillHints: const [AutofillHints.password],
                  validator: (value) => (value ?? '').isEmpty ? '現在のパスワードを入力してください' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('change_password_new'),
                  controller: _newController,
                  decoration: InputDecoration(
                    labelText: '新しいパスワード',
                    helperText: '$minPasswordLength〜$maxPasswordLength文字',
                  ),
                  obscureText: !_showPasswords,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: _validateNewPassword,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('change_password_confirm'),
                  controller: _confirmController,
                  decoration: const InputDecoration(labelText: '新しいパスワード(確認)'),
                  obscureText: !_showPasswords,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (value) => value == _newController.text ? null : '新しいパスワードと一致しません',
                ),
                CheckboxListTile(
                  key: const Key('change_password_show'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('パスワードを表示する'),
                  value: _showPasswords,
                  onChanged: (value) => setState(() => _showPasswords = value ?? false),
                ),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('change_password_submit'),
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('変更する'),
                ),
                const SizedBox(height: 8),
                Text(
                  '変更すると、この端末以外ではログインし直しになります',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
