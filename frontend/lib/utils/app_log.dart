import 'package:flutter/foundation.dart';

/// 端末のログ(開発中にコンソールで見るためのもの)。`[tag] message`の形で出す。
/// リリースビルドでは出さない(端末のログに位置情報の処理の様子やリクエストIDを残さないため。回収の仕組みも無い)。
/// サーバーとの突き合わせには、`[http]`の行の応答のリクエストID(X-Request-ID)と送った時刻を使う
/// (backend/docs/HTTPSとリバースプロキシ.mdの「リクエストID」)
void appLog(String tag, String message, {Object? error, StackTrace? stackTrace}) {
  if (kReleaseMode) return;
  debugPrint('[$tag] $message${error == null ? '' : ': $error'}');
  if (stackTrace != null) debugPrint(stackTrace.toString());
}
