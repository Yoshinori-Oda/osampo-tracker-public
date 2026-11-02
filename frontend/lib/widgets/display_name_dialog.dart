import 'package:flutter/material.dart';
import '../auth/auth_limits.dart';

// 表示名の入力ダイアログ(表示名の変更・ローカルアカウントの作成)。OKなら前後の空白を除いた表示名を返す
// (1〜50文字。通常のアカウントはサーバーも同じ条件で確かめる)
class DisplayNameDialog extends StatefulWidget {
  final String initial;
  final String title;
  final String submitLabel;

  const DisplayNameDialog({
    super.key,
    required this.initial,
    this.title = '表示名の変更',
    this.submitLabel = '変更する',
  });

  @override
  State<DisplayNameDialog> createState() => _DisplayNameDialogState();
}

class _DisplayNameDialogState extends State<DisplayNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          key: const Key('display_name_field'),
          controller: _controller,
          autofocus: true,
          maxLength: maxDisplayNameLength,
          decoration: const InputDecoration(labelText: '表示名'),
          validator: (value) => (value ?? '').trim().isEmpty ? '表示名を入力してください' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('キャンセル')),
        TextButton(key: const Key('display_name_save'), onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}
