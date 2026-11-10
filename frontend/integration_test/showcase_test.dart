// 機能紹介(README等)用のスクリーンショットを撮るシナリオ。テストではなく撮影が目的。
// 実行: scripts/run_checks.sh <run_id> e2e -e integration_test/showcase_test.dart
//
// - DBはメモリ上のもの(AppDatabase.forTesting)に差し替え、ダミーデータもそこに入れる。
//   端末の本物のapp.sqlite・secure storageには触れないので、後始末は不要
// - ローカルアカウント「デモ」で入るので同期は走らず、認証のバナーも出ない
// - 収録中の画面は撮らない(GPSが動いている必要があるため手動で撮る)
// - 実行中はシミュレータの位置情報を動かしておくこと(止まっていると10秒で「位置情報の更新が止まっています」の
//   バナーが全タブに出る)。手順はfrontend/docs/e2e.mdの「機能紹介用のスクリーンショット」
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:test_tracking_01/auth/auth_storage.dart';
import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/main.dart' as app;
import 'package:test_tracking_01/models/move_method.dart';
import 'package:test_tracking_01/models/recording_session.dart';
import 'package:test_tracking_01/models/status.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/providers/tracking_providers.dart';
import 'package:test_tracking_01/utils/delete_conflict_dialog.dart' show navigatorKey;
import 'package:test_tracking_01/views/main_page.dart';
import 'package:test_tracking_01/views/save_or_discard_page.dart';
import 'package:test_tracking_01/views/session_detail_view.dart';

const _demoUserId = '22222222-2222-2222-2222-222222222222';
const _detailSessionName = '皇居外周ラン';
const _justRecordedSessionId = 'showcase-just-recorded';
const _justRecordedSessionName = '日比谷公園の散歩';

// 今のユーザーを端末のsecure storageではなくメモリに持つ
class _MemoryAuthStorage implements AuthStorage {
  String? _currentUserId;

  _MemoryAuthStorage({String? currentUserId}) : _currentUserId = currentUserId;

  @override
  Future<String> deviceId() async => '44444444-4444-4444-4444-444444444444';

  // ローカルアカウントで入るのでトークンは持たない
  @override
  Future<StoredAuth?> read() async => null;

  @override
  Future<String?> readCurrentUserId() async => _currentUserId;

  @override
  Future<void> save(StoredAuth auth) async => _currentUserId = auth.userId;

  @override
  Future<void> saveLocalUser(String userId) async => _currentUserId = userId;

  @override
  Future<void> clear() async => _currentUserId = null;
}

// ---- 経路 ---------------------------------------------------------------------

typedef _Waypoint = ({double lat, double lng, double alt});

// 皇居外周(桜田門から反時計回り、約4.9km)。高度は地形のおおよその値
const List<_Waypoint> _kokyoLoop = [
  (lat: 35.6773, lng: 139.7528, alt: 6.0),  // 桜田門
  (lat: 35.6790, lng: 139.7560, alt: 4.0),  // 祝田橋
  (lat: 35.6838, lng: 139.7611, alt: 4.0),  // 和田倉門
  (lat: 35.6870, lng: 139.7620, alt: 5.0),  // 大手門
  (lat: 35.6905, lng: 139.7585, alt: 8.0),  // 竹橋
  (lat: 35.6910, lng: 139.7530, alt: 22.0), // 代官町通り
  (lat: 35.6890, lng: 139.7470, alt: 26.0), // 千鳥ヶ淵
  (lat: 35.6840, lng: 139.7445, alt: 30.0), // 半蔵門
  (lat: 35.6790, lng: 139.7465, alt: 24.0), // 三宅坂
  (lat: 35.6765, lng: 139.7500, alt: 12.0), // 桜田濠
  (lat: 35.6773, lng: 139.7528, alt: 6.0),  // 桜田門
];

// 日比谷公園の外周(約1.2km)
const List<_Waypoint> _hibiyaLoop = [
  (lat: 35.6755, lng: 139.7545, alt: 6.0),
  (lat: 35.6755, lng: 139.7575, alt: 4.0),
  (lat: 35.6727, lng: 139.7578, alt: 3.0),
  (lat: 35.6722, lng: 139.7555, alt: 5.0),
  (lat: 35.6735, lng: 139.7542, alt: 7.0),
  (lat: 35.6755, lng: 139.7545, alt: 6.0),
];

const double _earthRadius = 6371000;
const Duration _recordInterval = Duration(seconds: 5);

double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  double rad(double deg) => deg * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final h = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLng / 2), 2);
  return 2 * _earthRadius * asin(sqrt(h));
}

typedef _GeneratedPoint = ({DateTime at, double lat, double lng, double alt});

// 経路を一定の速さで進み、5秒ごとの位置を返す。GPSらしく位置に数mの揺らぎを加える。
// 高度は点ごとに揺らすと獲得標高が積み上がってしまうので、緩やかな起伏だけを加える
List<_GeneratedPoint> _generateTrack(
  List<_Waypoint> route, {
  required double speedMps,
  required DateTime startedAt,
  required Random rng,
}) {
  final points = <_GeneratedPoint>[];
  final step = speedMps * _recordInterval.inSeconds;
  var at = startedAt;
  // 今の区間の始点からの距離
  var offset = 0.0;

  for (var i = 0; i < route.length - 1; i++) {
    final from = route[i];
    final to = route[i + 1];
    final length = _distanceMeters(from.lat, from.lng, to.lat, to.lng);
    while (offset <= length) {
      final t = offset / length;
      final lat = from.lat + (to.lat - from.lat) * t;
      const jitterMeters = 2.5;
      final jitterLat = (rng.nextDouble() * 2 - 1) * jitterMeters / 111320;
      final jitterLng = (rng.nextDouble() * 2 - 1) * jitterMeters / (111320 * cos(lat * pi / 180));
      points.add((
        at: at,
        lat: lat + jitterLat,
        lng: from.lng + (to.lng - from.lng) * t + jitterLng,
        alt: from.alt + (to.alt - from.alt) * t + 0.6 * sin(points.length / 12),
      ));
      at = at.add(_recordInterval);
      offset += step;
    }
    offset -= length;
  }
  return points;
}

// トラックポイントから、収録時と同じ項目(距離km・時間・獲得標高・最高/最低高度)を集計する
({double distanceKm, int durationSeconds, double elevationGain, double maxAlt, double minAlt}) _summarize(
  List<_GeneratedPoint> points,
) {
  var distance = 0.0;
  var gain = 0.0;
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    distance += _distanceMeters(a.lat, a.lng, b.lat, b.lng);
    if (b.alt > a.alt) gain += b.alt - a.alt;
  }
  final alts = points.map((p) => p.alt);
  return (
    distanceKm: distance / 1000,
    durationSeconds: points.last.at.difference(points.first.at).inSeconds,
    elevationGain: gain,
    maxAlt: alts.reduce(max),
    minAlt: alts.reduce(min),
  );
}

// ---- ダミーデータ -------------------------------------------------------------

AppDatabase _openMemoryDatabase() => AppDatabase.forTesting(NativeDatabase.memory());

Future<void> _insertTrack(AppDatabase db, String sessionId, List<_GeneratedPoint> points) {
  return db.batch((b) {
    b.insertAll(
      db.trackPoints,
      points.map((p) => TrackPointsCompanion.insert(
        sessionId: sessionId,
        recordedAt: p.at,
        latitude: p.lat,
        longitude: p.lng,
        altitude: Value(p.alt),
      )),
    );
  });
}

// 詳細画面で見せる記録(トラックポイント付き)。直近の土曜の朝に皇居外周を走ったことにする
Future<void> _seedDetailSession(AppDatabase db, DateTime startedAt, Random rng) async {
  const sessionId = 'showcase-detail';
  final points = _generateTrack(_kokyoLoop, speedMps: 2.8, startedAt: startedAt, rng: rng);
  final summary = _summarize(points);
  await db.into(db.sessions).insert(SessionsCompanion.insert(
    id: sessionId,
    userId: _demoUserId,
    name: const Value(_detailSessionName),
    startedAt: startedAt,
    endedAt: Value(points.last.at),
    status: const Value(Status.ended),
    isFavorite: const Value(true),
    moveMethod: const Value(MoveMethod.run),
    totalDistance: Value(summary.distanceKm),
    durationSeconds: Value(summary.durationSeconds),
    elevationGain: Value(summary.elevationGain),
    maxAltitude: Value(summary.maxAlt),
    minAltitude: Value(summary.minAlt),
    updatedAt: Value(points.last.at),
  ));
  await _insertTrack(db, sessionId, points);
}

typedef _Template = ({MoveMethod method, List<String> names, double minKm, double maxKm, double kmh, int hour});

const _morningWalk = (method: MoveMethod.walk, names: ['朝の散歩'], minKm: 1.5, maxKm: 3.5, kmh: 4.6, hour: 7);
const _lunchWalk = (method: MoveMethod.walk, names: ['昼休みの散歩'], minKm: 1.0, maxKm: 2.0, kmh: 4.8, hour: 12);
const _eveningRun = (method: MoveMethod.run, names: ['夜ラン', '駒沢公園ラン'], minKm: 4.0, maxKm: 7.0, kmh: 9.5, hour: 19);
const _weekendRun = (method: MoveMethod.run, names: ['朝ラン', '代々木公園ラン'], minKm: 6.0, maxKm: 12.0, kmh: 10.0, hour: 8);
const _weekendRide = (method: MoveMethod.bicycle, names: ['多摩川サイクリング', '荒川サイクリング'], minKm: 15.0, maxKm: 38.0, kmh: 18.0, hour: 9);
const _weekendWalk = (method: MoveMethod.walk, names: ['週末ウォーキング', '公園めぐり'], minKm: 4.0, maxKm: 9.0, kmh: 4.4, hour: 10);

_Template? _pickTemplate(DateTime day, Random rng) {
  final r = rng.nextDouble();
  final isWeekend = day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
  if (isWeekend) {
    if (r < 0.35) return _weekendRun;
    if (r < 0.6) return _weekendRide;
    if (r < 0.8) return _weekendWalk;
    return null;
  }
  if (r < 0.25) return _morningWalk;
  if (r < 0.4) return _lunchWalk;
  if (r < 0.55) return _eveningRun;
  return null;
}

// 約100日分の記録(トラックポイントなし)。統計のグラフ・サマリー・自己ベストに使う。
// 乱数の種を固定しているので、何度実行しても同じ内容になる
Future<void> _seedHistory(AppDatabase db, DateTime today, {required DateTime skipDay, required Random rng}) async {
  final rows = <SessionsCompanion>[];
  for (var daysAgo = 100; daysAgo >= 1; daysAgo--) {
    final day = DateTime(today.year, today.month, today.day - daysAgo);
    if (day == skipDay) continue;
    final template = _pickTemplate(day, rng);
    if (template == null) continue;

    final distanceKm = template.minKm + rng.nextDouble() * (template.maxKm - template.minKm);
    final speed = template.kmh * (0.9 + rng.nextDouble() * 0.2);
    final durationSeconds = (distanceKm / speed * 3600).round();
    final startedAt = day.add(Duration(hours: template.hour, minutes: rng.nextInt(50)));
    final minAlt = 3 + rng.nextDouble() * 12;
    final maxAlt = minAlt + 5 + rng.nextDouble() * (template.method == MoveMethod.bicycle ? 45 : 25);
    rows.add(SessionsCompanion.insert(
      id: 'showcase-history-$daysAgo',
      userId: _demoUserId,
      name: Value(template.names[rng.nextInt(template.names.length)]),
      startedAt: startedAt,
      endedAt: Value(startedAt.add(Duration(seconds: durationSeconds))),
      status: const Value(Status.ended),
      isFavorite: Value(rng.nextDouble() < 0.12),
      moveMethod: Value(template.method),
      totalDistance: Value(distanceKm),
      durationSeconds: Value(durationSeconds),
      elevationGain: Value((maxAlt - minAlt) * (1 + rng.nextDouble() * distanceKm / 5)),
      maxAltitude: Value(maxAlt),
      minAltitude: Value(minAlt),
      updatedAt: Value(startedAt.add(Duration(seconds: durationSeconds))),
    ));
  }
  await db.batch((b) => b.insertAll(db.sessions, rows));
}

// 直前の土曜(今日が土曜なら1週間前)
DateTime _lastSaturday(DateTime today) {
  final back = (today.weekday - DateTime.saturday) % 7;
  return DateTime(today.year, today.month, today.day - (back == 0 ? 7 : back));
}

// 収録を止めた直後の記録(保存/破棄画面用)。保存/破棄が未確定の状態(inProgress)で入れる
Future<RecordingSession> _seedJustRecordedSession(AppDatabase db, Random rng) async {
  final startedAt = DateTime.now().subtract(const Duration(minutes: 25));
  final points = _generateTrack(_hibiyaLoop, speedMps: 1.25, startedAt: startedAt, rng: rng);
  final summary = _summarize(points);
  final session = RecordingSession(
    sessionId: _justRecordedSessionId,
    startedAt: startedAt,
    endedAt: points.last.at,
    totalDistance: summary.distanceKm,
    elapsedSeconds: summary.durationSeconds,
    elevationGain: summary.elevationGain,
    maxAltitude: summary.maxAlt,
    minAltitude: summary.minAlt,
  );
  await db.initSession(session: session, userId: _demoUserId);
  await _insertTrack(db, _justRecordedSessionId, points);
  return session;
}

// ---- 撮影 ---------------------------------------------------------------------

// flutter_mapのタイルはpumpAndSettle()では待てないので、実時間で待つ(frontend/docs/e2e.md)
Future<void> _waitForMapTiles(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

Future<void> _capture(IntegrationTestWidgetsFlutterBinding binding, WidgetTester tester, String name) async {
  // 位置情報のバナーが出ていたら知らせる(撮影は続ける)
  final mainPage = find.byType(MainPage);
  if (mainPage.evaluate().isNotEmpty) {
    final container = ProviderScope.containerOf(tester.element(mainPage));
    final banner = container.read(locationBannerProvider).value;
    if (banner != null && banner.isActive) {
      debugPrint('[showcase] 警告: $name の撮影時に位置情報のバナーが出ています: ${banner.message}');
    }
  }
  await binding.convertFlutterSurfaceToImage();
  await tester.pumpAndSettle();
  await binding.takeScreenshot(name);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ログイン画面', (tester) async {
    final db = _openMemoryDatabase();
    addTearDown(db.close);
    // 端末にユーザーが1人もいないとローカルアカウントを作って入ってしまうので、ログアウト済みのユーザーを置く
    await db.upsertUser(id: _demoUserId, email: 'demo@example.com', displayName: 'デモ', emailVerified: true);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authStorageProvider.overrideWithValue(_MemoryAuthStorage()),
      ],
      child: const app.MyApp(),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('login_email')), 'demo@example.com');
    await tester.enterText(find.byKey(const Key('login_password')), 'password1234');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _capture(binding, tester, '01_login');
  });

  testWidgets('保存/破棄・履歴・詳細・統計', (tester) async {
    final rng = Random(20261029);
    final today = DateTime.now();
    final detailDay = _lastSaturday(today);

    final db = _openMemoryDatabase();
    addTearDown(db.close);
    await db.createLocalUser(id: _demoUserId, displayName: 'デモ');
    await _seedDetailSession(db, detailDay.add(const Duration(hours: 7, minutes: 12)), rng);
    await _seedHistory(db, today, skipDay: detailDay, rng: rng);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authStorageProvider.overrideWithValue(_MemoryAuthStorage(currentUserId: _demoUserId)),
      ],
      child: const app.MyApp(),
    ));
    await tester.pumpAndSettle();
    // 起動時の未完了の収録の回収(addPostFrameCallback)が済んでから、保存/破棄画面用の記録を入れる
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byType(MainPage), findsOneWidget);

    // 03 保存/破棄画面: 収録を止めた直後の画面を、TrackingServiceを通さずに直接開く(保存/破棄しても何もしない)
    final justRecorded = await _seedJustRecordedSession(db, rng);
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => SaveOrDiscardPage(
        session: justRecorded,
        onDiscard: () async {},
        onSave: (_, _) async {},
      ),
    ));
    await tester.pumpAndSettle();
    await _waitForMapTiles(tester);
    await _capture(binding, tester, '03a_save_or_discard');

    // 保存の確認ダイアログで名前を付けたところ
    await tester.tap(find.descendant(of: find.byType(SaveOrDiscardPage), matching: find.text('保存')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
      _justRecordedSessionName,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _capture(binding, tester, '03b_save_dialog');

    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('キャンセル')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('後で決める'));
    await tester.pumpAndSettle();
    await db.deleteRecordingSession(session: justRecorded);

    // 04 履歴
    await tester.tap(find.text('履歴'));
    await tester.pumpAndSettle();
    await _capture(binding, tester, '04_history');

    // 05 詳細: ルート表示と、5秒ごとの点を全て出した表示
    await tester.ensureVisible(find.text(_detailSessionName));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_detailSessionName));
    await tester.pumpAndSettle();
    await _waitForMapTiles(tester);
    await _capture(binding, tester, '05a_detail_route');

    await tester.tap(find.text('全ピン'));
    await tester.pumpAndSettle();
    await _waitForMapTiles(tester);
    await _capture(binding, tester, '05b_detail_points');

    // 高度プロファイルのグラフが見えるところまでスクロールする
    await tester.drag(
      find.descendant(of: find.byType(SessionDetailView), matching: find.byType(SingleChildScrollView)).first,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    await _capture(binding, tester, '05c_detail_elevation');

    await tester.pageBack();
    await tester.pumpAndSettle();

    // 06 統計: 月の前半は今月のデータが少ないので、先月を表示する
    await tester.tap(find.text('統計'));
    await tester.pumpAndSettle();
    if (today.day < 15) {
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
    }
    await _capture(binding, tester, '06a_analytics_month');

    await tester.tap(find.text('年'));
    await tester.pumpAndSettle();
    // 棒グラフは横にスクロールし、初めは1〜8月しか見えないので、データのある直近の月が見えるよう右端まで送る
    await tester.drag(find.byKey(const PageStorageKey<String>('analytics_bar_chart_scroll')), const Offset(-1000, 0));
    await tester.pumpAndSettle();
    await _capture(binding, tester, '06b_analytics_year');

    await tester.tap(find.text('全期間'));
    await tester.pumpAndSettle();
    await _capture(binding, tester, '06c_analytics_all');
  });
}
