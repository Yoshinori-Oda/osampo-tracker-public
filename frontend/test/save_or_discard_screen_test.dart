import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/models/move_method.dart';
import 'package:test_tracking_01/models/recording_session.dart';
import 'package:test_tracking_01/providers/tracking_providers.dart';
import 'package:test_tracking_01/utils/delete_conflict_dialog.dart' show navigatorKey;
import 'package:test_tracking_01/utils/save_or_discard_screen.dart';
import 'package:test_tracking_01/views/save_or_discard_page.dart';

final _sessionA = RecordingSession(
  sessionId: 'session-a',
  startedAt: DateTime(2026, 9, 28, 10, 5, 3),
  endedAt: DateTime(2026, 9, 28, 10, 35, 3),
  totalDistance: 2.5,
  elapsedSeconds: 1800,
  elevationGain: 12,
  maxAltitude: 40,
  minAltitude: 20,
);

final _sessionB = RecordingSession(
  sessionId: 'session-b',
  startedAt: DateTime(2026, 9, 28, 11, 0, 0),
  endedAt: DateTime(2026, 9, 28, 11, 10, 0),
  totalDistance: 1.0,
  elapsedSeconds: 600,
  elevationGain: 3,
  maxAltitude: 30,
  minAltitude: 25,
);

const _defaultNameA = '9/28 10:05:03の徒歩アクティビティ';
const _defaultNameB = '9/28 11:00:00の徒歩アクティビティ';

// トラックポイントは空にしておく(マップ/グラフがプレースホルダ表示になり、タイルのHTTP取得が走らない)
Widget _buildApp() {
  return ProviderScope(
    overrides: [
      trackPointsBySessionIdProvider(_sessionA.sessionId).overrideWith((ref) async => <TrackPoint>[]),
      trackPointsBySessionIdProvider(_sessionB.sessionId).overrideWith((ref) async => <TrackPoint>[]),
    ],
    child: MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Center(child: Text('home'))),
    ),
  );
}

// 画面下部の固定領域のボタン(確認ダイアログは別routeなのでSaveOrDiscardPageの子孫には含まれない)
Finder _pageButton(String label) =>
  find.descendant(of: find.byType(SaveOrDiscardPage), matching: find.text(label));

Finder _inDialog(String text) =>
  find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

class _Calls {
  final discards = <String>[];
  final saves = <(String, String, MoveMethod)>[];
}

void _open(
  RecordingSession session,
  _Calls calls, {
  String? infoMessage,
  void Function()? onCompleteSync,
}) {
  unawaited(showSaveOrDiscardScreen(
    session: session,
    infoMessage: infoMessage,
    onDiscard: () async {
      calls.discards.add(session.sessionId);
      onCompleteSync?.call();
    },
    onSave: (name, method) async {
      calls.saves.add((session.sessionId, name, method));
      onCompleteSync?.call();
    },
  ));
}

void main() {
  testWidgets('セッション詳細画面を模した表示(既定名・移動手段空欄・説明文は下部に表示)', (tester) async {
    await tester.pumpWidget(_buildApp());
    _open(_sessionA, _Calls(), infoMessage: '前回のセッションが意図せず中断されました。');
    await tester.pumpAndSettle();

    expect(find.byType(SaveOrDiscardPage), findsOneWidget);
    expect(find.text(_defaultNameA), findsOneWidget);
    // 移動手段は未選択なので「<移動手段> ・ 」を付けず開始日時だけを出す
    expect(find.text('2026-09-28 10:05'), findsOneWidget);
    expect(find.textContaining(' ・ '), findsNothing);
    expect(find.text('アクティビティ統計'), findsOneWidget);
    expect(find.text('2.50 km'), findsOneWidget);
    expect(find.text('00:30:00'), findsOneWidget);
    expect(find.text('前回のセッションが意図せず中断されました。'), findsOneWidget);
    expect(_pageButton('保存'), findsOneWidget);
    expect(_pageButton('破棄'), findsOneWidget);
  });

  testWidgets('破棄は確認ダイアログを挟み、キャンセルでは何もしない', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_buildApp());
    _open(_sessionA, calls);
    await tester.pumpAndSettle();

    await tester.tap(_pageButton('破棄'));
    await tester.pumpAndSettle();
    expect(find.text('セッション破棄'), findsOneWidget);

    await tester.tap(_inDialog('キャンセル'));
    await tester.pumpAndSettle();
    expect(calls.discards, isEmpty);
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);

    await tester.tap(_pageButton('破棄'));
    await tester.pumpAndSettle();
    await tester.tap(_inDialog('破棄'));
    await tester.pumpAndSettle();

    expect(calls.discards, ['session-a']);
    expect(calls.saves, isEmpty);
    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('保存は名前・移動手段を入力するダイアログを挟み、空欄なら選択中の移動手段の既定名で保存する', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_buildApp());
    _open(_sessionA, calls);
    await tester.pumpAndSettle();

    await tester.tap(_pageButton('保存'));
    await tester.pumpAndSettle();
    expect(find.text('セッション保存'), findsOneWidget);
    // 既定名はヒント文字として表示し、入力欄自体は空のまま
    expect(_inDialog(_defaultNameA), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);

    await tester.tap(_inDialog('キャンセル'));
    await tester.pumpAndSettle();
    expect(calls.saves, isEmpty);
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);

    await tester.tap(_pageButton('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<MoveMethod>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ランニング').last);
    await tester.pumpAndSettle();
    // ヒント文字の既定名も移動手段に追従する
    expect(_inDialog('9/28 10:05:03のランニングアクティビティ'), findsOneWidget);

    await tester.tap(_inDialog('保存'));
    await tester.pumpAndSettle();

    expect(calls.saves, [('session-a', '9/28 10:05:03のランニングアクティビティ', MoveMethod.run)]);
    expect(calls.discards, isEmpty);
    expect(find.byType(SaveOrDiscardPage), findsNothing);
  });

  testWidgets('入力した名前は前後の空白を除いて保存する', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_buildApp());
    _open(_sessionA, calls);
    await tester.pumpAndSettle();

    await tester.tap(_pageButton('保存'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  朝の散歩  ');
    await tester.tap(_inDialog('保存'));
    await tester.pumpAndSettle();

    expect(calls.saves, [('session-a', '朝の散歩', MoveMethod.walk)]);
  });

  testWidgets('閉じる(後で決める)と保存/破棄せずに閉じ、再度開ける', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_buildApp());
    _open(_sessionA, calls);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('後で決める'));
    await tester.pumpAndSettle();
    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(calls.saves, isEmpty);
    expect(calls.discards, isEmpty);

    _open(_sessionA, calls);
    await tester.pumpAndSettle();
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);
  });

  testWidgets('同じセッションの画面が開いている間は重ねて開かない', (tester) async {
    await tester.pumpWidget(_buildApp());
    _open(_sessionA, _Calls());
    await tester.pumpAndSettle();
    _open(_sessionA, _Calls());
    await tester.pumpAndSettle();

    expect(find.byType(SaveOrDiscardPage), findsOneWidget);

    // 1回閉じればホームへ戻る(下に同じ画面が積まれていない)
    await tester.tap(find.byTooltip('後で決める'));
    await tester.pumpAndSettle();
    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('確定時に次のセッションが提示されたらpushReplacementで差し替える(起動時リカバリのキュー)', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_buildApp());
    // completeSession()と同じく、確定の呼び出しの中で(awaitより前に)次の1件を提示する
    _open(_sessionA, calls, onCompleteSync: () => _open(_sessionB, calls));
    await tester.pumpAndSettle();

    await tester.tap(_pageButton('破棄'));
    await tester.pumpAndSettle();
    await tester.tap(_inDialog('破棄'));
    await tester.pumpAndSettle();

    expect(calls.discards, ['session-a']);
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);
    expect(find.text(_defaultNameB), findsOneWidget);
    expect(find.text(_defaultNameA), findsNothing);

    await tester.tap(_pageButton('保存'));
    await tester.pumpAndSettle();
    await tester.tap(_inDialog('保存'));
    await tester.pumpAndSettle();

    // 1件目の画面は差し替えで消えているので、2件目を確定するとホームへ戻る
    expect(calls.saves, [('session-b', _defaultNameB, MoveMethod.walk)]);
    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
