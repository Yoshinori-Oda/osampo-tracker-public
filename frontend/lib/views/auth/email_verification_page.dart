import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/auth_service.dart';
import '../../providers/auth_providers.dart';
import 'auth_error_messages.dart';

// メールアドレスの確認コード(6桁)の入力画面。仕様はdocs/design/screens.mdの「auth/email_verification_page.dart」、
// APIとのやり取りはfrontend/docs/ユーザー機能追加に伴う変更予定.mdの「メールアドレスの確認」
class EmailVerificationPage extends ConsumerStatefulWidget {
  // サインアップの直後に開いたか(「あとで」ボタンを出し、再発行のカウントダウンを始める)
  final bool afterSignup;

  const EmailVerificationPage({super.key, this.afterSignup = false});

  // サインアップ時にサーバーがコードを送った直後なので、再発行できるまでの秒数(サーバーの既定の再送の間隔と同じ)
  static const initialResendWaitSeconds = 60;

  static const codeLength = 6;

  @override
  ConsumerState<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends ConsumerState<EmailVerificationPage> {
  final _codeController = TextEditingController();
  Timer? _timer;
  // 再発行のボタンを押せるようになるまでの秒数(画面の中だけで持つ。閉じて開き直すと0に戻る)
  int _resendWait = 0;
  // 間隔・回数の上限(429)で止められた(カウントダウン中に「時間をあけてください」を出す。残りの秒数は再発行のボタンに出す)
  bool _rateLimited = false;
  bool _busy = false;
  // 入力欄の下に出すエラー(コードが違う)
  String? _codeError;
  // 画面に出すお知らせ・エラー(期限切れ・通信できない等)
  String? _message;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() => setState(() {}));
    if (widget.afterSignup) _startCountdown(EmailVerificationPage.initialResendWaitSeconds);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _resendWait = seconds);
    if (seconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _resendWait -= 1;
        if (_resendWait <= 0) {
          _resendWait = 0;
          _rateLimited = false;
          timer.cancel();
        }
      });
    });
  }

  bool get _codeComplete => _codeController.text.length == EmailVerificationPage.codeLength;

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _codeError = null;
      _message = null;
      _rateLimited = false;
    });
    try {
      final wait = await ref.read(authControllerProvider.notifier).sendVerificationCode();
      if (!mounted) return;
      _codeController.clear();
      _message = 'コードを送りました。メールを確認してください';
      _startCountdown(wait);
    } on AuthException catch (e) {
      if (!mounted) return;
      if (e.code == 'email_already_verified') {
        // 別の端末で確認済みになっていた等。確認状態を取り込み直して閉じる
        await ref.read(authControllerProvider.notifier).refreshProfile();
        if (mounted) _close('メールアドレスは確認済みです');
        return;
      }
      if (e.code == 'too_many_requests' && e.retryAfterSeconds != null) {
        _rateLimited = true;
        _startCountdown(e.retryAfterSeconds!);
      } else {
        setState(() => _message = verificationErrorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _codeError = null;
      _message = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).confirmEmail(_codeController.text);
      if (mounted) _close('メールアドレスを確認しました');
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'invalid_verification_code') {
          _codeError = verificationErrorMessage(e);
        } else {
          _message = verificationErrorMessage(e);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _close(String snackBarMessage) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(snackBarMessage)));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final email = ref.watch(currentUserProvider).value?.email;
    final message = _rateLimited && _resendWait > 0
      ? verificationErrorMessage(const AuthException('too_many_requests'))
      : _message;

    return Scaffold(
      appBar: AppBar(title: const Text('メールアドレスの確認')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              email == null
                ? 'メールで届いた6桁のコードを入力してください'
                : '$email に届いた6桁のコードを入力してください',
            ),
            const SizedBox(height: 4),
            Text(
              '確認が済むまで、記録はサーバーと同期されません',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('verification_code_field'),
              controller: _codeController,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(EmailVerificationPage.codeLength),
              ],
              decoration: InputDecoration(
                labelText: '確認コード',
                border: const OutlineInputBorder(),
                errorText: _codeError,
              ),
            ),
            const SizedBox(height: 16),
            // 6桁そろうまで押せない。そろっても自動では送らない(打ち間違いで入力の失敗の枠を減らさないため)
            FilledButton(
              key: const Key('verification_confirm'),
              onPressed: _busy || !_codeComplete ? null : _confirm,
              child: const Text('確認'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('verification_resend'),
              onPressed: _busy || _resendWait > 0 ? null : _resend,
              child: Text(_resendWait > 0 ? 'コードを再発行(あと$_resendWait秒)' : 'コードを再発行'),
            ),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(message, key: const Key('verification_message')),
            ],
            if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (widget.afterSignup) ...[
              const SizedBox(height: 24),
              TextButton(
                key: const Key('verification_later'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('あとで(設定タブからも確認できます)'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
