import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/models/status.dart';

// schemaVersion 1(usersが無く、外部キーが効いていない)・2(usersにis_localが無い)のDBから今のバージョンへの移行の確認

const _userA = '11111111-1111-1111-1111-111111111111';
const _userB = '22222222-2222-2222-2222-222222222222';

// schemaVersion 1のテーブル(当時のapp_database.g.dartが作っていたものと同じ列)
const _v1Schema = [
  '''CREATE TABLE sessions (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    name TEXT NULL,
    started_at INTEGER NOT NULL,
    ended_at INTEGER NULL,
    status INTEGER NOT NULL DEFAULT 1,
    is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    move_method TEXT NOT NULL DEFAULT 'walk',
    total_distance REAL NOT NULL DEFAULT 0.0,
    duration_seconds INTEGER NOT NULL DEFAULT 0,
    elevation_gain REAL NOT NULL DEFAULT 0.0,
    max_altitude REAL NULL,
    min_altitude REAL NULL,
    PRIMARY KEY (id)
  )''',
  '''CREATE TABLE track_points (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    recorded_at INTEGER NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    altitude REAL NULL
  )''',
];

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
      for (final statement in _v1Schema) {
        raw.execute(statement);
      }
      raw.execute("INSERT INTO sessions (id, user_id, started_at, status) VALUES ('a1', '$_userA', 1759300000, 2)");
      raw.execute("INSERT INTO sessions (id, user_id, started_at, status) VALUES ('a2', '$_userA', 1759300000, 2)");
      raw.execute("INSERT INTO sessions (id, user_id, started_at, status) VALUES ('b1', '$_userB', 1759300000, 2)");
      for (final sessionId in ['a1', 'a2', 'b1', 'deleted-before']) {
        raw.execute(
          "INSERT INTO track_points (session_id, recorded_at, latitude, longitude) VALUES ('$sessionId', 1759300000, 35.0, 139.0)",
        );
      }
      raw.execute('PRAGMA user_version = 1');
    }));
  });

  tearDown(() => db.close());

  Future<List<String>> trackPointSessionIds() async =>
    (await db.select(db.trackPoints).get()).map((point) => point.sessionId).toList()..sort();

  test('既存のsessionsのuser_idからusersの行を作り、セッションを残す', () async {
    final users = await db.select(db.users).get();
    expect(users.map((user) => user.id).toSet(), {_userA, _userB});
    // メールアドレスの確認状態は分からないので、次にGET /users/meで取り込むまでは同期しない
    expect(users.every((user) => !user.emailVerified && user.lastSyncedAt == null), isTrue);
    expect(users.every((user) => !user.isLocal), isTrue);

    final sessions = await db.select(db.sessions).get();
    expect(sessions.map((session) => session.id).toSet(), {'a1', 'a2', 'b1'});
    expect(sessions.firstWhere((session) => session.id == 'a1').status, Status.values[2]);
  });

  test('外部キーが効いていなかった間に残ったtrack_pointsを片付ける', () async {
    expect(await trackPointSessionIds(), ['a1', 'a2', 'b1']);
  });

  test('移行後は外部キーが効き、ユーザーの削除でセッション・track_pointsも消える', () async {
    await db.deleteUserData(_userA);

    expect((await db.select(db.sessions).get()).map((session) => session.id), ['b1']);
    expect(await trackPointSessionIds(), ['b1']);
  });

  test('移行後は存在しないユーザーのセッションを作れない', () async {
    await expectLater(
      db.into(db.sessions).insert(SessionsCompanion.insert(
        id: 'x1',
        userId: '99999999-9999-9999-9999-999999999999',
        startedAt: DateTime.utc(2026, 10, 1),
      )),
      throwsA(isA<SqliteException>()),
    );
  });

  test('新規作成(schemaVersion 2から)でも外部キーが効く', () async {
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    await fresh.upsertUser(id: _userA, email: 'a@example.com', displayName: 'a', emailVerified: true);
    await fresh.into(fresh.sessions).insert(SessionsCompanion.insert(
      id: 'a1',
      userId: _userA,
      startedAt: DateTime.utc(2026, 10, 1),
      status: const Value(Status.ended),
    ));

    await fresh.deleteUserData(_userA);

    expect(await fresh.select(fresh.sessions).get(), isEmpty);
  });

  group('schemaVersion 2から', () {
    late AppDatabase v2;

    setUp(() {
      v2 = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
        for (final statement in _v2Schema) {
          raw.execute(statement);
        }
        raw.execute("INSERT INTO users (id, email, email_verified, last_synced_at) VALUES ('$_userA', 'a@example.com', 1, '2026-10-01T00:00:00Z')");
        raw.execute("INSERT INTO sessions (id, user_id, started_at, status) VALUES ('a1', '$_userA', 1759300000, 3)");
        raw.execute('PRAGMA user_version = 2');
      }));
    });

    tearDown(() => v2.close());

    test('既存のユーザーは通常のアカウント(is_localがfalse)になり、ユーザーとセッションはそのまま残る', () async {
      final user = (await v2.getUser(_userA))!;
      expect(user.isLocal, isFalse);
      expect(user.emailVerified, isTrue);
      expect(user.lastSyncedAt, '2026-10-01T00:00:00Z');
      final sessions = await v2.select(v2.sessions).get();
      expect(sessions.single.id, 'a1');
      expect(sessions.single.status, Status.synced);
    });
  });
}

// schemaVersion 2のテーブル(当時のapp_database.g.dartが作っていたものと同じ列)
const _v2Schema = [
  '''CREATE TABLE users (
    id TEXT NOT NULL,
    email TEXT NOT NULL DEFAULT '',
    display_name TEXT NOT NULL DEFAULT '',
    email_verified INTEGER NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1)),
    last_synced_at TEXT NULL,
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    PRIMARY KEY (id)
  )''',
  '''CREATE TABLE sessions (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE CASCADE,
    name TEXT NULL,
    started_at INTEGER NOT NULL,
    ended_at INTEGER NULL,
    status INTEGER NOT NULL DEFAULT 1,
    is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    move_method TEXT NOT NULL DEFAULT 'walk',
    total_distance REAL NOT NULL DEFAULT 0.0,
    duration_seconds INTEGER NOT NULL DEFAULT 0,
    elevation_gain REAL NOT NULL DEFAULT 0.0,
    max_altitude REAL NULL,
    min_altitude REAL NULL,
    PRIMARY KEY (id)
  )''',
  '''CREATE TABLE track_points (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    recorded_at INTEGER NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    altitude REAL NULL
  )''',
];
