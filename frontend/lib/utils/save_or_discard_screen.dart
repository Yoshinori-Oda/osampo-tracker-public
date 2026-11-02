import 'package:flutter/material.dart';
import '../models/move_method.dart';
import '../models/recording_session.dart';
import '../views/save_or_discard_page.dart';
import 'delete_conflict_dialog.dart' show navigatorKey;

// 現在表示中の保存/破棄画面(同時に1つだけ)
Route<void>? _activeRoute;
String? _activeSessionId;

bool get isSaveOrDiscardScreenOpen => _activeRoute?.isActive ?? false;

// 収録停止後の保存/破棄画面(SaveOrDiscardPage)を表示する。通常の停止フロー・権限エラーによる
// 強制停止フロー・起動時リカバリのすべてから TrackingService 経由で使う共通の入口。
// infoMessageを渡すと、下部の保存/破棄ボタンの上に説明文(強制停止の理由など)を表示する。
// - 画面が開いていなければpushする
// - 別のセッションの画面が開いていれば(起動時リカバリのキューの次の1件)pushReplacementで差し替える
// - 同じセッションの画面が既に開いていれば何もしない(バナー/SnackBar経由の多重表示防止)
// 差し替えはSaveOrDiscardPage側のpop判定と噛み合わせるため、awaitより前に同期的に行うこと
Future<void> showSaveOrDiscardScreen({
  required RecordingSession session,
  required Future<void> Function() onDiscard,
  required Future<void> Function(String sessionName, MoveMethod moveMethod) onSave,
  String? infoMessage,
}) async {
  final navigator = navigatorKey.currentState;
  if (navigator == null) {
    // 画面を出せない場合は、データを失わないよう既定の名前で保存する
    await onSave(defaultSessionName(session.startedAt, MoveMethod.walk), MoveMethod.walk);
    return;
  }

  if (isSaveOrDiscardScreenOpen && _activeSessionId == session.sessionId) return;

  final route = MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (context) => SaveOrDiscardPage(
      session: session,
      infoMessage: infoMessage,
      onDiscard: onDiscard,
      onSave: onSave,
    ),
  );

  final Future<void> closed;
  if (isSaveOrDiscardScreenOpen && (_activeRoute?.isCurrent ?? false)) {
    closed = navigator.pushReplacement(route);
  } else {
    closed = navigator.push(route);
  }
  _activeRoute = route;
  _activeSessionId = session.sessionId;

  await closed;
  if (_activeRoute == route) {
    _activeRoute = null;
    _activeSessionId = null;
  }
}
