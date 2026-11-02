import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/models/move_method.dart';
import 'package:test_tracking_01/models/status.dart';
import 'package:test_tracking_01/repositories/tracking_repository.dart';

// 同期処理(TrackingRepository)が新しいAPI(backend/docs/API設計ドラフト.md)を
// frontend/docs/ユーザー機能追加に伴う変更予定.md の約束どおりに呼ぶことの確認。
// APIはMockClientで偽装し、ローカルDBはメモリ上のDriftを使う

const _userId = '11111111-1111-1111-1111-111111111111';
const _baseUrl = 'http://test/api';
const _sessionsPath = '/api/users/$_userId/sessions';
const _syncedAt = '2026-10-06T00:00:00.123456Z';

class _MemorySyncStateStore implements SyncStateStore {
  String? value;

  @override
  Future<String?> getLastSyncedAt() async => value;

  @override
  Future<void> setLastSyncedAt(String newValue) async => value = newValue;

  @override
  Future<void> clearLastSyncedAt() async => value = null;
}

typedef _Handler = http.Response Function(http.Request request);

// "メソッド パス"ごとに応答を決め、受け取ったリクエストを記録する偽のAPI
class _FakeApi {
  final List<http.Request> requests = [];
  final Map<String, _Handler> _handlers = {};

  void on(String method, String path, _Handler handler) => _handlers['$method $path'] = handler;

  MockClient get client => MockClient((request) async {
    requests.add(request);
    final handler = _handlers['${request.method} ${request.url.path}'];
    // 定義していないパスは、存在しないパスへのリクエストと同じ404(codeはnot_found)
    return handler == null ? _error(404, 'not_found') : handler(request);
  });

  List<http.Request> requestsTo(String method, String path) =>
    requests.where((r) => r.method == method && r.url.path == path).toList();
}

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(int status, String code) => _json(status, {'code': code, 'message': code});

http.Response _updatedAt(int status, String updatedAt) => _json(status, {'updated_at': updatedAt});

http.Response _syncResponse({
  List<Map<String, dynamic>> sessions = const [],
  bool requestExistenceCheck = false,
}) => _json(200, {
  'synced_at': _syncedAt,
  'request_existence_check': requestExistenceCheck,
  'sessions': sessions,
});

Map<String, dynamic> _remoteSession(String id) => {
  'id': id,
  'name': '夕方ランニング',
  'started_at': '2026-10-02T09:00:00Z',
  'ended_at': '2026-10-02T09:30:00Z',
  'is_favorite': true,
  'move_method': 'run',
  'total_distance': 5.0,
  'duration_seconds': 1800,
  'elevation_gain': 20.0,
  'max_altitude': 40.0,
  'min_altitude': null,
  'updated_at': '2026-10-05T10:00:00Z',
  'track_points': [
    {'recorded_at': '2026-10-02T09:00:00Z', 'latitude': 35.0, 'longitude': 139.0, 'altitude': 12.5},
  ],
};

Map<String, dynamic> _bodyOf(http.Request request) => jsonDecode(request.body) as Map<String, dynamic>;

void main() {
  late AppDatabase db;
  late _FakeApi api;
  late _MemorySyncStateStore store;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // sessions.user_idはusersへの外部キーなので、ログイン中のユーザーの行を先に作っておく
    await db.upsertUser(id: _userId, email: 'test@example.com', displayName: 'test', emailVerified: true);
    api = _FakeApi();
    store = _MemorySyncStateStore();
    // pushの後のpullは、特に指定しなければ空の差分を返す
    api.on('GET', _sessionsPath, (_) => _syncResponse());
  });

  tearDown(() => db.close());

  TrackingRepository createRepository({
    DeleteConflictChoice conflictChoice = DeleteConflictChoice.discard,
    bool Function()? canSync,
  }) {
    final repository = TrackingRepository(
      db,
      _userId,
      client: api.client,
      syncStateStore: store,
      baseUrl: _baseUrl,
      onDeleteConflict: (_) async => conflictChoice,
      canSync: canSync,
    );
    addTearDown(repository.dispose);
    return repository;
  }

  Future<void> insertSession(String id, Status status, {String userId = _userId}) async {
    await db.into(db.sessions).insert(SessionsCompanion.insert(
      id: id,
      userId: userId,
      name: const Value('朝の散歩'),
      startedAt: DateTime.utc(2026, 10, 1, 8),
      endedAt: Value(DateTime.utc(2026, 10, 1, 8, 30)),
      status: Value(status),
      moveMethod: const Value(MoveMethod.walk),
      totalDistance: const Value(2.0),
      durationSeconds: const Value(1800),
      elevationGain: const Value(12.5),
      maxAltitude: const Value(30.0),
      minAltitude: const Value(7.5),
    ));
    await db.addTrackPoint(
      sessionId: id,
      latitude: 35.68,
      longitude: 139.76,
      altitude: 10.5,
      recordedAt: DateTime.utc(2026, 10, 1, 8),
    );
  }

  Future<Session?> findSession(String id) =>
    (db.select(db.sessions)..where((tbl) => tbl.id.equals(id))).getSingleOrNull();

  group('push', () {
    test('endedのセッションを新しい形式でPOSTし、サーバーのupdated_atを保存する', () async {
      api.on('POST', _sessionsPath, (_) => _updatedAt(201, '2026-10-06T01:00:00Z'));
      await insertSession('s1', Status.ended);

      expect(await createRepository().syncDiff(), isTrue);

      final body = _bodyOf(api.requestsTo('POST', _sessionsPath).single);
      // user_id・updated_atは送らない(user_idはパス、updated_atはサーバーが決める)
      expect(body.keys.toSet(), {
        'id', 'name', 'started_at', 'ended_at', 'is_favorite', 'move_method', 'total_distance',
        'duration_seconds', 'elevation_gain', 'max_altitude', 'min_altitude', 'track_points',
      });
      expect(body['track_points'], [
        {'recorded_at': '2026-10-01T08:00:00.000Z', 'latitude': 35.68, 'longitude': 139.76, 'altitude': 10.5},
      ]);
      final session = (await findSession('s1'))!;
      expect(session.status, Status.synced);
      expect(session.updatedAt.isAtSameMomentAs(DateTime.utc(2026, 10, 6, 1)), isTrue);
    });

    test('idが衝突したら(409 id_conflicted)、idを振り直してtrack_pointsも付け替える', () async {
      api.on('POST', _sessionsPath, (_) => _error(409, 'id_conflicted'));
      await insertSession('s1', Status.ended);

      expect(await createRepository().syncDiff(), isTrue);

      expect(await findSession('s1'), isNull);
      final sessions = await db.select(db.sessions).get();
      expect(sessions, hasLength(1));
      expect(sessions.single.status, Status.ended);
      expect(await db.getTrackPointsForSession(sessions.single.id), hasLength(1));
    });

    test('updatedのセッションは可変の3項目をPATCHする', () async {
      api.on('PATCH', '$_sessionsPath/s1', (_) => _updatedAt(200, '2026-10-06T02:00:00Z'));
      await insertSession('s1', Status.updated);

      expect(await createRepository().syncDiff(), isTrue);

      final body = _bodyOf(api.requestsTo('PATCH', '$_sessionsPath/s1').single);
      expect(body, {'name': '朝の散歩', 'move_method': 'walk', 'is_favorite': false});
      expect((await findSession('s1'))!.status, Status.synced);
    });

    test('削除済み(409 deleted)のセッションの編集を残す場合はrestoreを呼ぶ', () async {
      api.on('PATCH', '$_sessionsPath/s1', (_) => _error(409, 'deleted'));
      api.on('POST', '$_sessionsPath/s1/restore', (_) => _updatedAt(200, '2026-10-06T03:00:00Z'));
      await insertSession('s1', Status.updated);

      expect(await createRepository(conflictChoice: DeleteConflictChoice.keep).syncDiff(), isTrue);

      expect(_bodyOf(api.requestsTo('POST', '$_sessionsPath/s1/restore').single), {
        'name': '朝の散歩', 'move_method': 'walk', 'is_favorite': false,
      });
      expect(api.requestsTo('POST', _sessionsPath), isEmpty);
      expect((await findSession('s1'))!.status, Status.synced);
    });

    test('パージ済み(404 session_not_found)のセッションの編集を残す場合は登録し直す', () async {
      api.on('PATCH', '$_sessionsPath/s1', (_) => _error(404, 'session_not_found'));
      api.on('POST', _sessionsPath, (_) => _updatedAt(201, '2026-10-06T04:00:00Z'));
      await insertSession('s1', Status.updated);

      expect(await createRepository(conflictChoice: DeleteConflictChoice.keep).syncDiff(), isTrue);

      expect(api.requestsTo('POST', '$_sessionsPath/s1/restore'), isEmpty);
      expect(api.requestsTo('POST', _sessionsPath), hasLength(1));
      expect((await findSession('s1'))!.status, Status.synced);
    });

    test('削除を受け入れる場合はローカルの行を削除する', () async {
      api.on('PATCH', '$_sessionsPath/s1', (_) => _error(409, 'deleted'));
      await insertSession('s1', Status.updated);

      expect(await createRepository(conflictChoice: DeleteConflictChoice.discard).syncDiff(), isTrue);

      expect(await findSession('s1'), isNull);
    });

    test('DELETEが204でも404(session_not_found)でも削除完了としてローカルの行を消す', () async {
      api.on('DELETE', '$_sessionsPath/s1', (_) => http.Response('', 204));
      api.on('DELETE', '$_sessionsPath/s2', (_) => _error(404, 'session_not_found'));
      await insertSession('s1', Status.deletedUnsynced);
      await insertSession('s2', Status.deletedUnsynced);

      expect(await createRepository().syncDiff(), isTrue);

      expect(await findSession('s1'), isNull);
      expect(await findSession('s2'), isNull);
    });

    test('user_not_foundの404では同期を止め、ローカルのデータに触れない', () async {
      api.on('DELETE', '$_sessionsPath/s1', (_) => _error(404, 'user_not_found'));
      await insertSession('s1', Status.deletedUnsynced);

      expect(await createRepository().syncDiff(), isFalse);

      expect((await findSession('s1'))!.status, Status.deletedUnsynced);
      expect(api.requestsTo('GET', _sessionsPath), isEmpty);
    });
  });

  group('pull', () {
    test('差分を取り込み、tombstoneはローカルから消し、synced_atを保存する', () async {
      api.on('GET', _sessionsPath, (_) => _syncResponse(sessions: [
        _remoteSession('remote'),
        {'id': 'gone', 'deleted_at': '2026-10-05T11:00:00Z'},
      ]));
      await insertSession('gone', Status.synced);
      final repository = createRepository();

      expect(await repository.syncDiff(), isTrue);

      final remote = (await findSession('remote'))!;
      expect(remote.status, Status.synced);
      expect(remote.moveMethod, MoveMethod.run);
      expect(remote.updatedAt.isAtSameMomentAs(DateTime.utc(2026, 10, 5, 10)), isTrue);
      expect((await db.getTrackPointsForSession('remote')).single.altitude, 12.5);
      expect(await findSession('gone'), isNull);
      expect(store.value, _syncedAt);

      // 次回の差分取得では、保存したsynced_atをそのままlast_synced_atとして送る
      await repository.syncDiff();
      expect(api.requestsTo('GET', _sessionsPath).last.url.queryParameters['last_synced_at'], _syncedAt);
    });

    test('request_existence_checkがtrueなら突き合わせ、存在しないセッションを消してからsynced_atを保存する', () async {
      api.on('GET', _sessionsPath, (_) => _syncResponse(
        sessions: [_remoteSession('received')],
        requestExistenceCheck: true,
      ));
      api.on('POST', '$_sessionsPath/existence-check', (_) => _json(200, {'missing_session_ids': ['b']}));
      await insertSession('a', Status.synced);
      await insertSession('b', Status.synced);
      await insertSession('local-only', Status.ended);
      final repository = createRepository();
      store.value = '2026-06-01T00:00:00Z';
      api.on('POST', _sessionsPath, (_) => _updatedAt(201, '2026-10-06T05:00:00Z'));

      expect(await repository.syncDiff(), isTrue);

      final sent = _bodyOf(api.requestsTo('POST', '$_sessionsPath/existence-check').single);
      // 送るのは同期済みのセッションから、今回のpullで受け取ったものを除いたもの
      // (local-onlyはこの同期のpushで登録されて同期済みになっている)
      expect((sent['session_ids'] as List).toSet(), {'a', 'b', 'local-only'});
      expect(await findSession('a'), isNotNull);
      expect(await findSession('b'), isNull);
      expect(store.value, _syncedAt);
    });

    test('突き合わせに失敗したらlast_synced_atを更新しない', () async {
      api.on('GET', _sessionsPath, (_) => _syncResponse(requestExistenceCheck: true));
      api.on('POST', '$_sessionsPath/existence-check', (_) => _error(500, 'internal_error'));
      await insertSession('a', Status.synced);
      final repository = createRepository();
      store.value = '2026-06-01T00:00:00Z';

      expect(await repository.syncDiff(), isFalse);

      expect(store.value, '2026-06-01T00:00:00Z');
      expect(await findSession('a'), isNotNull);
    });
  });

  group('local', () {
    test('endedのセッションを削除してもローカルだけで消さず、DELETEを送る対象にする', () async {
      await insertSession('s1', Status.ended);

      await db.deleteSession(session: (await findSession('s1'))!);

      expect((await findSession('s1'))!.status, Status.deletedUnsynced);
    });

    test('ローカルアカウントのセッションは、DELETEを送る先が無いので物理削除する', () async {
      const localUserId = '44444444-4444-4444-4444-444444444444';
      await db.createLocalUser(id: localUserId, displayName: 'ローカル');
      await insertSession('s1', Status.ended, userId: localUserId);

      await db.deleteSession(session: (await findSession('s1'))!);

      expect(await findSession('s1'), isNull);
    });
  });

  group('auth', () {
    test('同期できない状態(未ログイン・メール未確認・再ログイン待ち)では通信しない', () async {
      await insertSession('s1', Status.ended);
      final repository = createRepository(canSync: () => false);

      expect(await repository.syncDiff(), isFalse);
      await repository.requestSync();

      expect(api.requests, isEmpty);
      expect((await findSession('s1'))!.status, Status.ended);
    });

    test('他のユーザーのセッションは送らない', () async {
      const otherUserId = '22222222-2222-2222-2222-222222222222';
      await db.upsertUser(id: otherUserId, email: 'other@example.com', displayName: 'other', emailVerified: true);
      await insertSession('mine', Status.ended);
      await insertSession('others', Status.ended, userId: otherUserId);
      api.on('POST', _sessionsPath, (_) => _updatedAt(201, '2026-10-06T01:00:00Z'));

      expect(await createRepository().syncDiff(), isTrue);

      expect(api.requestsTo('POST', _sessionsPath).map((r) => _bodyOf(r)['id']), ['mine']);
      expect((await findSession('others'))!.status, Status.ended);
    });

    test('last_synced_atは指定しなければusersの行に保存する', () async {
      final repository = TrackingRepository(db, _userId, client: api.client, baseUrl: _baseUrl);
      addTearDown(repository.dispose);

      expect(await repository.syncDiff(), isTrue);

      expect(await db.getLastSyncedAt(_userId), _syncedAt);
    });
  });
}
