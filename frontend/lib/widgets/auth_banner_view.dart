import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_providers.dart';
import '../views/auth/email_verification_page.dart';
import '../views/auth/login_page.dart';

// 同期が止まっている理由(再ログインが必要・メールアドレスが未確認)を、全タブ共通で上部に表示するバナー。
// 同期できる状態なら何も表示しない
class AuthBannerView extends ConsumerWidget {
  const AuthBannerView({super.key});

  // バナーを表示するか(MainPageの上部の余白の計算にも使う)。ローカルアカウントは同期しないので出さない
  static bool isActive(AuthState? auth) =>
    auth != null && auth.signedIn && !auth.isLocal && (auth.needsRelogin || !auth.emailVerified);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).value;
    if (!isActive(auth)) return const SizedBox.shrink();

    final needsRelogin = auth!.needsRelogin;
    final message = needsRelogin
      ? 'ログインの有効期限が切れたため同期を止めています。タップしてログインし直してください'
      : 'メールアドレスが未確認のため、記録はサーバーと同期されません。タップして確認コードを入力してください';

    return Material(
      color: needsRelogin ? Colors.orange.shade800 : Colors.blueGrey,
      child: InkWell(
        // 再ログインが必要ならログイン画面、メールアドレスが未確認なら確認コードの入力画面を開く
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => needsRelogin ? const LoginPage(isRelogin: true) : const EmailVerificationPage(),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(needsRelogin ? Icons.lock_clock : Icons.mark_email_unread, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13))
              )
            ]
          )
        )
      )
    );
  }
}
