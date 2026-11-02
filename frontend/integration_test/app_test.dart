import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:test_tracking_01/auth/auth_storage.dart';
import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/main.dart' as app;
import 'package:test_tracking_01/models/move_method.dart';
import 'package:test_tracking_01/models/recording_session.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/providers/tracking_providers.dart';
import 'package:test_tracking_01/views/save_or_discard_page.dart';

const _testUserId = '11111111-1111-1111-1111-111111111111';

// テストユーザーでログインした状態にする(端末のsecure storageには触れない)。
// トークンは偽物なので、同期は401になって再ログインのバナーが出るが、画面の操作には影響しない
class _SignedInAuthStorage implements AuthStorage {
  StoredAuth? _stored = const StoredAuth(userId: _testUserId, accessToken: 'e2e', refreshToken: 'e2e');

  @override
  Future<String> deviceId() async => '33333333-3333-3333-3333-333333333333';

  @override
  Future<StoredAuth?> read() async => _stored;

  @override
  Future<String?> readCurrentUserId() async => _stored?.userId;

  @override
  Future<void> save(StoredAuth auth) async => _stored = auth;

  // E2Eではローカルアカウントに切り替えない
  @override
  Future<void> saveLocalUser(String userId) async => throw UnsupportedError('not used in e2e');

  @override
  Future<void> clear() async => _stored = null;
}

// sessions.user_idはusersへの外部キーなので、テストユーザーの行が無ければ作る
// (実機でテストユーザーとしてログインしていた場合の行は書き換えない)
Future<void> _ensureTestUser(AppDatabase db) async {
  if (await db.getUser(_testUserId) != null) return;
  await db.upsertUser(id: _testUserId, email: 'testuser@example.com', displayName: 'testuser', emailVerified: true);
}

// 保存/破棄画面の下部固定領域のボタン(確認ダイアログは別routeなのでSaveOrDiscardPageの子孫には含まれない)
Finder _pageButton(String label) =>
  find.descendant(of: find.byType(SaveOrDiscardPage), matching: find.text(label));

Finder _inDialog(String text) =>
  find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

// 保存/破棄画面は詳細画面と同じくflutter_mapのタイルを読み込むため、撮影前は実時間で待つ
Future<void> _waitForMapTiles(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

// 破棄ボタン→確認ダイアログで破棄を確定する
Future<void> _discardOnScreen(WidgetTester tester) async {
  await tester.tap(_pageButton('破棄'));
  await tester.pumpAndSettle();
  await tester.tap(_inDialog('破棄'));
  await tester.pumpAndSettle();
}

// クラッシュ・強制終了で保存/破棄されないまま残った(status=inProgressの)セッションを
// 実DBへ直接再現する。同じsessionIdの残骸があれば先に消してから作るので再実行しても安全
Future<void> _seedOrphanedSession(
  AppDatabase db, {
  required String sessionId,
  required DateTime startedAt,
  int trackPointCount = 2,
}) async {
  final placeholder = RecordingSession(
    sessionId: sessionId,
    startedAt: startedAt,
    endedAt: null,
    totalDistance: 0,
    elapsedSeconds: 0,
    elevationGain: 0,
    maxAltitude: 0,
    minAltitude: 0,
  );
  await db.deleteRecordingSession(session: placeholder);
  await _ensureTestUser(db);
  await db.initSession(session: placeholder, userId: _testUserId);

  for (var i = 0; i < trackPointCount; i++) {
    await db.addTrackPoint(
      sessionId: sessionId,
      latitude: 35.681236 + i * 0.001,
      longitude: 139.767125 + i * 0.001,
      altitude: 10 + i.toDouble(),
      recordedAt: startedAt.add(Duration(seconds: i * 30))
    );
  }
}

// テストが保存/破棄どちらに転んでも(アサーション失敗で走らなかった場合も含めて)、
// 実機の本物のDBにテスト用セッションを残さないための後始末
Future<void> _purgeSeededSession(AppDatabase db, String sessionId, DateTime startedAt) {
  return db.deleteRecordingSession(
    session: RecordingSession(
      sessionId: sessionId,
      startedAt: startedAt,
      endedAt: null,
      totalDistance: 0,
      elapsedSeconds: 0,
      elevationGain: 0,
      maxAltitude: 0,
      minAltitude: 0
    )
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('起動して初期画面のスクリーンショットを撮る', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    // flutter_mapのタイルはネットワーク経由で非同期に届くため、pumpAndSettle()では
    // 読み込み完了を待てない(Future/HTTPの完了はアニメーションフレームではないため)。
    // タイルが揃うまで実時間で待ってから撮る。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('01_launch');
  });

  testWidgets('起動時に孤立したinProgressセッションを検出し保存/破棄画面へ誘導する', (tester) async {
    const sessionId = 'e2e-orphan-recovery-session';
    final startedAt = DateTime.now().subtract(const Duration(minutes: 10));

    final db = AppDatabase();
    addTearDown(() => _purgeSeededSession(db, sessionId, startedAt));
    await _seedOrphanedSession(db, sessionId: sessionId, startedAt: startedAt);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authStorageProvider.overrideWithValue(_SignedInAuthStorage()),
        ],
        child: const app.MyApp()
      )
    );
    await tester.pumpAndSettle();
    // recoverOrphanedSessions()はaddPostFrameCallback経由で呼ばれるため、確定するまで少し待つ
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // 起動直後は収録タブを見ている状態なので、警告なしでそのまま保存/破棄画面が出る
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);
    expect(find.text('前回のセッションが意図せず中断されました。保存/破棄を選択してください。'), findsOneWidget);

    await _waitForMapTiles(tester);
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('02_orphan_recovery_screen');

    // 閉じる(後で決める)と保存/破棄は未確定のまま残り、収録タブのボタンから再度開ける
    await tester.tap(find.byTooltip('後で決める'));
    await tester.pumpAndSettle();
    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(find.text('前回のセッションを処理'), findsOneWidget);

    await tester.tap(find.text('前回のセッションを処理'));
    await tester.pumpAndSettle();
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);

    // 保存確認ダイアログで、名前欄は空欄のまま保存し、既定名になることを確認する
    await tester.tap(_pageButton('保存'));
    await tester.pumpAndSettle();
    expect(find.text('セッション保存'), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('02b_orphan_recovery_save_dialog');

    await tester.tap(_inDialog('保存'));
    await tester.pumpAndSettle();

    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(find.text('収録開始 (REC)'), findsOneWidget);

    // 履歴タブに保存されたことを確認する
    await tester.tap(find.text('履歴'));
    await tester.pumpAndSettle();
    // 実機/シミュレータの履歴には既存のセッションも並ぶため、部分一致ではなく既定名で特定する
    expect(find.text(defaultSessionName(startedAt, MoveMethod.walk)), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('03_orphan_recovery_saved_to_history');
  });

  testWidgets('複数の孤立セッションを1件ずつ保存/破棄させる(キュー処理)', (tester) async {
    const sessionId1 = 'e2e-orphan-queue-session-1';
    const sessionId2 = 'e2e-orphan-queue-session-2';
    final startedAt1 = DateTime.now().subtract(const Duration(minutes: 30));
    final startedAt2 = DateTime.now().subtract(const Duration(minutes: 20));

    final db = AppDatabase();
    addTearDown(() => _purgeSeededSession(db, sessionId1, startedAt1));
    addTearDown(() => _purgeSeededSession(db, sessionId2, startedAt2));
    await _seedOrphanedSession(db, sessionId: sessionId1, startedAt: startedAt1);
    await _seedOrphanedSession(db, sessionId: sessionId2, startedAt: startedAt2);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authStorageProvider.overrideWithValue(_SignedInAuthStorage()),
        ],
        child: const app.MyApp()
      )
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // 1件目
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);
    await _discardOnScreen(tester);

    // idleへ戻らず、キューの2件目がそのままstoppingとして続けて提示される
    // (1件目の画面はpushReplacementで差し替わり、積み重ならない)
    expect(find.byType(SaveOrDiscardPage), findsOneWidget);
    await _waitForMapTiles(tester);
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('04_orphan_queue_second_screen');

    await _discardOnScreen(tester);

    // 全件解決後、通常の収録開始ボタンに戻る
    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(find.text('収録開始 (REC)'), findsOneWidget);
  });

  testWidgets('trackpointが1件も無い孤立セッションはダイアログを出さず自動破棄する', (tester) async {
    const sessionId = 'e2e-orphan-empty-session';
    final startedAt = DateTime.now().subtract(const Duration(minutes: 5));

    final db = AppDatabase();
    addTearDown(() => _purgeSeededSession(db, sessionId, startedAt));
    await _seedOrphanedSession(db, sessionId: sessionId, startedAt: startedAt, trackPointCount: 0);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authStorageProvider.overrideWithValue(_SignedInAuthStorage()),
        ],
        child: const app.MyApp()
      )
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.byType(SaveOrDiscardPage), findsNothing);
    expect(find.text('収録開始 (REC)'), findsOneWidget);
  });
}
