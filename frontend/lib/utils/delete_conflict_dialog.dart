import 'package:flutter/material.dart';
import '../database/app_database.dart';
import '../repositories/tracking_repository.dart';

// MaterialAppに渡し、ダイアログをUIツリーの外(リポジトリ層)から表示するために使う
final navigatorKey = GlobalKey<NavigatorState>();

// MaterialAppに渡し、SnackBarをUIツリーの外(TrackingService)から表示するために使う
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

// 他端末で削除済みのセッションをローカルで編集していた場合に、
// 削除を受け入れるか編集内容を残すかをユーザーに選ばせる
Future<DeleteConflictChoice> showDeleteConflictDialog(Session session) async {
  final context = navigatorKey.currentContext;
  if (context == null) return DeleteConflictChoice.discard;

  final choice = await showDialog<DeleteConflictChoice>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('セッションが他の端末で削除されています'),
      content: Text('「${session.name ?? session.id}」は他の端末で削除されました。今回の編集内容を保存しますか?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(DeleteConflictChoice.discard),
          child: const Text('削除する'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(DeleteConflictChoice.keep),
          child: const Text('保存する'),
        ),
      ],
    ),
  );

  return choice ?? DeleteConflictChoice.discard;
}
