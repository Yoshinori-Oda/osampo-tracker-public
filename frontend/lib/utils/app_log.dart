import 'package:flutter/foundation.dart';

/// 端末のログ(開発中にコンソールで見るためのもの)。`[tag] message`の形で出す。
/// リリースビルドでは出さない(端末のログに位置情報の処理の様子やリクエストIDを残さないため。回収の仕組みも無い)。
/// サーバーとの突き合わせには、失敗のログに付けたリクエストID(X-Request-ID)を使う(backend/docs/バックエンド構成.mdの「ログ」)
void appLog(String tag, String message, {Object? error, StackTrace? stackTrace}) {
  if (kReleaseMode) return;
  debugPrint('[$tag] $message${error == null ? '' : ': $error'}');
  if (stackTrace != null) debugPrint(stackTrace.toString());
}
