import 'dart:io';
import 'dart:async';
//import 'dart:math';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/recording_session.dart';
import '../models/status.dart';
import '../models/move_method.dart';
import '../utils/app_log.dart';

part 'app_database.g.dart';

// この端末のユーザー。通常のアカウント(サーバーのusersの写し)とローカルアカウント(同期しない。is_local)がある。
// schemaVersion 2で追加、3でis_localを追加
class Users extends Table {
  // サーバーのユーザーID(ローカルアカウントは端末で生成したUUID)
  TextColumn get id => text()();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  // メールアドレスの確認が済んでいるか(ログイン時・GET /users/meの値を写す)。falseなら同期しない
  BoolColumn get emailVerified => boolean().withDefault(const Constant(false))();
  // 差分取得の基準時刻。サーバーが返したsynced_atの文字列をそのまま保存する(nullなら初回の同期)
  TextColumn get lastSyncedAt => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // ローカルアカウント(同期しないアカウント)か
  BoolColumn get isLocal => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Sessions extends Table {
  // basic info
  TextColumn get id => text()();
  // users.idを差し替えたときに追随するよう、ON UPDATE CASCADEにする(サーバーのIDと重なったローカルアカウントのIDを変えるときに使う)
  TextColumn get userId => text().references(
    Users,
    #id,
    onDelete: KeyAction.cascade,
    onUpdate: KeyAction.cascade,
  )();
  TextColumn get name => text().withLength(min:1, max: 100).nullable()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get status => intEnum<Status>().withDefault(Constant(Status.ended.index))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // detailed info
  TextColumn get moveMethod => textEnum<MoveMethod>().withDefault(Constant(MoveMethod.walk.name))();
  RealColumn get totalDistance => real().withDefault(const Constant(0.0))();
  IntColumn get durationSeconds => integer().withDefault(const Constant(0))();
  RealColumn get elevationGain => real().withDefault(const Constant(0.0))();
  RealColumn get maxAltitude => real().nullable()();
  RealColumn get minAltitude => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TrackPoints extends Table {
  // basic info
  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text().references(Sessions, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get recordedAt => dateTime()();

  // position info
  RealColumn get latitude => real()();
  RealColumn get longitude => real()();
  RealColumn get altitude => real().nullable()();
}

@DriftDatabase(tables: [Users, Sessions, TrackPoints])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // テスト用(メモリ上のDBなどを渡す)
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // usersを作り、既存のsessionsのuser_idのユーザーの行を作ってから、sessions.user_idに外部キーを付ける
        // (SQLiteは既存の列に外部キーを足せないので、TableMigrationでsessionsを作り直してデータを移す)
        await m.createTable(users);
        await customStatement('INSERT OR IGNORE INTO users (id) SELECT DISTINCT user_id FROM sessions');
        await m.alterTable(TableMigration(sessions));
        // これまで外部キーが効いておらず、sessionsの削除で残っていたtrack_pointsを片付ける
        await customStatement('DELETE FROM track_points WHERE session_id NOT IN (SELECT id FROM sessions)');
      }
      // 1からの移行では、上のcreateTableが今の定義(is_localを含む)でusersを作るので、2からの場合だけ列を足す
      if (from == 2) {
        await m.addColumn(users, users.isLocal);
      }
    },
    beforeOpen: (details) async {
      // SQLiteは既定で外部キーが無効なので、接続を開くたびに有効にする
      // (これまでtrack_pointsのON DELETE CASCADEも効いていなかった)
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  // ---- users ------------------------------------------------------------------

  // ログイン・新規登録・GET /users/meで受け取ったユーザーの情報を保存する(last_synced_at・created_atは変えない)。
  // ログイン・新規登録ではsaveServerUserを使う(端末のローカルアカウントとIDが重なった場合の扱いがあるため)
  Future<void> upsertUser({
    required String id,
    required String email,
    required String displayName,
    required bool emailVerified,
  }) {
    return into(users).insertOnConflictUpdate(
      UsersCompanion.insert(
        id: id,
        email: Value(email),
        displayName: Value(displayName),
        emailVerified: Value(emailVerified),
        isLocal: const Value(false),
      )
    );
  }

  // ログイン・新規登録で受け取ったサーバーのユーザーを保存する。mergeFromLocalUserIdを渡すと、そのローカルアカウントの記録を
  // このユーザーに移して(未登録のendedにする)、ローカルアカウントを消す(ローカル→通常)。
  // IDはサーバー側を優先する: 端末の別のローカルアカウントとIDが重なった場合は、そのローカルアカウントのIDを変える
  Future<void> saveServerUser({
    required String id,
    required String email,
    required String displayName,
    required bool emailVerified,
    String? mergeFromLocalUserId,
  }) {
    return transaction(() async {
      final existing = await getUser(id);
      if (existing != null && existing.isLocal && id != mergeFromLocalUserId) {
        // sessions.user_idはON UPDATE CASCADEで追随する
        await (update(users)..where((tbl) => tbl.id.equals(id))).write(UsersCompanion(id: Value(const Uuid().v4())));
      }
      // sessions.user_idの外部キーのため、ユーザーの行を先に作ってから記録を移す
      await upsertUser(id: id, email: email, displayName: displayName, emailVerified: emailVerified);
      final from = mergeFromLocalUserId;
      if (from == null) return;
      await _resetSessionsToUnregistered(from);
      if (from != id) {
        await (update(sessions)..where((tbl) => tbl.userId.equals(from))).write(SessionsCompanion(userId: Value(id)));
        await (delete(users)..where((tbl) => tbl.id.equals(from))).go();
      }
    });
  }

  // 記録をサーバーに未登録の状態にする(ローカル→通常・通常→ローカルの変更時)。削除待ちは物理削除し、
  // 収録中以外はendedにする(通常のアカウントになったら、次の同期で全てPOSTされる)
  Future<void> _resetSessionsToUnregistered(String userId) async {
    await (delete(sessions)
      ..where((tbl) => tbl.userId.equals(userId) & tbl.status.equals(Status.deletedUnsynced.index))
    ).go();
    await (update(sessions)
      ..where((tbl) => tbl.userId.equals(userId) & tbl.status.equals(Status.inProgress.index).not())
    ).write(const SessionsCompanion(status: Value(Status.ended)));
  }

  // 通常のアカウントをローカルアカウントにする(サーバーのアカウントを削除した後)。端末の記録は残す
  Future<void> convertToLocalUser(String userId) {
    return transaction(() async {
      await (update(users)..where((tbl) => tbl.id.equals(userId))).write(
        const UsersCompanion(
          isLocal: Value(true),
          email: Value(''),
          emailVerified: Value(false),
          lastSyncedAt: Value(null),
        )
      );
      await _resetSessionsToUnregistered(userId);
    });
  }

  // ---- ローカルアカウント ------------------------------------------------------

  Future<void> createLocalUser({required String id, required String displayName}) {
    return into(users).insert(
      UsersCompanion.insert(id: id, displayName: Value(displayName), isLocal: const Value(true))
    );
  }

  Stream<List<User>> watchLocalUsers() {
    return (select(users)
      ..where((tbl) => tbl.isLocal.equals(true))
      ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)])
    ).watch();
  }

  // 端末にユーザー(通常・ローカルとも)が1人でもいるか。いなければ初回起動として扱う
  Future<bool> hasAnyUser() async {
    final rows = await (selectOnly(users)..addColumns([users.id])..limit(1)).get();
    return rows.isNotEmpty;
  }

  // ローカルアカウントの表示名を変える(通常のアカウントはサーバーで変えてから、レスポンスをupsertUserで書く)
  Future<void> setLocalDisplayName(String userId, String displayName) {
    return (update(users)..where((tbl) => tbl.id.equals(userId) & tbl.isLocal.equals(true))).write(
      UsersCompanion(displayName: Value(displayName))
    );
  }

  Future<User?> getUser(String userId) =>
    (select(users)..where((tbl) => tbl.id.equals(userId))).getSingleOrNull();

  Stream<User?> watchUser(String userId) =>
    (select(users)..where((tbl) => tbl.id.equals(userId))).watchSingleOrNull();

  Future<void> setEmailVerified(String userId, bool verified) =>
    (update(users)..where((tbl) => tbl.id.equals(userId))).write(UsersCompanion(emailVerified: Value(verified)));

  Future<String?> getLastSyncedAt(String userId) async => (await getUser(userId))?.lastSyncedAt;

  Future<void> setLastSyncedAt(String userId, String? value) {
    return (update(users)..where((tbl) => tbl.id.equals(userId))).write(
      UsersCompanion(lastSyncedAt: Value(value))
    );
  }

  // ユーザーとそのデータ(sessions・track_points)を端末から消す(アカウント・ローカルアカウントの削除時)。外部キーのCASCADEで消える
  Future<void> deleteUserData(String userId) =>
    (delete(users)..where((tbl) => tbl.id.equals(userId))).go();

  // ---- sessions ---------------------------------------------------------------

  Stream<List<Session>> watchAllSessions({required String userId}) {
    return (select(sessions)
        ..where((tbl) => tbl.userId.equals(userId) & tbl.status.isNotIn([
              Status.inProgress.index,
              Status.deletedUnsynced.index,
            ]))
        ..orderBy([(tbl) => OrderingTerm.desc(tbl.startedAt)]))
      .watch();
  }

  Future<int> initSession({
    required RecordingSession session,
    required String userId,
    }) {
    return into(sessions).insert(
      SessionsCompanion.insert(
        id: session.sessionId,
        userId: userId,
        startedAt: session.startedAt,
        status: Value(Status.inProgress),
      )
    );
  }

  Future<int> addTrackPoint({
    required String sessionId,
    required double latitude,
    required double longitude,
    double? altitude,
    required DateTime recordedAt
    }) {
    return into(trackPoints).insert(
      TrackPointsCompanion.insert(
        sessionId: sessionId,
        latitude: latitude,
        longitude: longitude,
        altitude: Value(altitude),
        recordedAt: recordedAt
      )
    );
  }

  Future<void> saveCompletedSession({
    required RecordingSession session,
    required String name,
    required MoveMethod moveMethod,
    required DateTime savedAt,
  }) {
    return (update(sessions)..where((tbl) => tbl.id.equals(session.sessionId))).write(
      SessionsCompanion(
        name: Value(name),
        status: Value(Status.ended),
        moveMethod: Value(moveMethod),
        totalDistance: Value(session.totalDistance),
        durationSeconds: Value(session.elapsedSeconds),
        elevationGain: Value(session.elevationGain),
        maxAltitude: Value(session.maxAltitude),
        minAltitude: Value(session.minAltitude),
        endedAt: Value(session.endedAt),
        updatedAt: Value(savedAt)
      )
    );
  }

  Future<void> upsertByFetchedData({
    required Session session,
    required List<TrackPoint> tps
  }) async {
    // skip if the sessionId exists and is waiting to be synced
    final localRecord = await (select(sessions)
      ..where((tbl) => tbl.id.equals(session.id)))
    .getSingleOrNull();
    if (localRecord != null && localRecord.status != Status.synced) return;

    // upsert given session
    await transaction(() async {
      await into(sessions).insertOnConflictUpdate(
        SessionsCompanion.insert(
          id: session.id,
          userId: session.userId,
          name: Value(session.name),
          startedAt: session.startedAt,
          endedAt: Value(session.endedAt),
          status: Value(session.status),
          isFavorite: Value(session.isFavorite),
          moveMethod: Value(session.moveMethod),
          totalDistance: Value(session.totalDistance),
          durationSeconds: Value(session.durationSeconds),
          elevationGain: Value(session.elevationGain),
          maxAltitude: Value(session.maxAltitude),
          minAltitude: Value(session.minAltitude),
          // サーバーが返したupdated_at(サーバー時刻)をそのまま保存する
          updatedAt: Value(session.updatedAt),
        )
      );

      // register tracking points if not exists
      if (localRecord == null) {
        await batch((b) {
          b.insertAll(
            trackPoints,
            tps.map((tp) => TrackPointsCompanion.insert(
              sessionId: tp.sessionId,
              recordedAt: tp.recordedAt,
              latitude: tp.latitude,
              longitude: tp.longitude,
              altitude: Value(tp.altitude),
            )),
          );
        });
      }
    });
  }

  Future<void> deleteRecordingSession({
    required RecordingSession session,
    }) {
    return (delete(sessions)..where((tbl) => tbl.id.equals(session.sessionId))).go();
  }

  // 保存済みセッションの削除。収録中の行はそのまま物理削除し、それ以外はdeletedUnsyncedにして
  // 次回同期でDELETEを送る。ended(登録のPOSTの成功を確認できていない)の行もDELETEを送る:
  // POSTがサーバーでは成功していてレスポンスだけが届かなかった場合に、ローカルだけで消すと
  // サーバーに残ったsessionが次のpullで返ってきて復活してしまうため(未登録ならサーバーが404を返す)。
  // ローカルアカウントの記録は、DELETEを送る先が無いので物理削除する
  Future<void> deleteSession({required Session session}) async {
    final owner = await getUser(session.userId);
    if (session.status == Status.inProgress || owner?.isLocal == true) {
      await (delete(sessions)..where((tbl) => tbl.id.equals(session.id))).go();
      return;
    }

    await (update(sessions)..where((tbl) => tbl.id.equals(session.id))).write(
      SessionsCompanion(
        status: const Value(Status.deletedUnsynced),
        updatedAt: Value(DateTime.now())
      )
    );
  }

  // pushが成功した行を同期済みにする。updatedAtにはサーバーが返したupdated_at(サーバー時刻)を保存する
  Future<void> markAsSynced({required String sessionId, required DateTime updatedAt}) {
    return (update(sessions)..where((tbl) => tbl.id.equals(sessionId))).write(
      SessionsCompanion(
        status: const Value(Status.synced),
        updatedAt: Value(updatedAt)
      )
    );
  }

  // 削除の突き合わせ(existence-check)で送る、同期済みのセッションのid
  Future<List<String>> getSyncedSessionIds({required String userId}) async {
    final query = selectOnly(sessions)
      ..addColumns([sessions.id])
      ..where(sessions.userId.equals(userId) & sessions.status.equals(Status.synced.index));
    final rows = await query.get();
    return rows.map((row) => row.read(sessions.id)!).toList();
  }

  // 登録時にidが別のセッションと衝突した(409 id_conflicted)場合に、セッションのidを振り直す。
  // 新しいidの行を作ってtrack_pointsを付け替え、古い行を消す(主キーを直接書き換えずに済むようにする)
  Future<void> reassignSessionId({required String oldId, required String newId}) {
    return transaction(() async {
      final old = await (select(sessions)..where((tbl) => tbl.id.equals(oldId))).getSingle();
      await into(sessions).insert(old.copyWith(id: newId).toCompanion(true));
      await (update(trackPoints)..where((tbl) => tbl.sessionId.equals(oldId))).write(
        TrackPointsCompanion(sessionId: Value(newId))
      );
      await (delete(sessions)..where((tbl) => tbl.id.equals(oldId))).go();
    });
  }

  // 削除が確定した(自分のpushが通った/他端末からのtombstoneをpullした)行を物理削除する
  // (track_pointsはFKでcascade)。deletedUnsyncedのpushが通った時点でリモートとも状態が一致するので
  // 中間状態を残さずそのまま消してよい
  Future<void> finalizeSessionDeletion({required String sessionId}) {
    return (delete(sessions)..where((tbl) => tbl.id.equals(sessionId))).go();
  }

  Future<void> updateSession({
    required Session session,
    required String sessionName,
    required MoveMethod moveMethod,
    required bool isFavorite
  }) {
    return (update(sessions)..where((tbl) => tbl.id.equals(session.id))).write(
      SessionsCompanion(
        status: session.status != Status.ended ? Value(Status.updated) : Value(Status.ended),
        name: Value(sessionName),
        moveMethod: Value(moveMethod),
        isFavorite: Value(isFavorite)
      )
    );
  }

  Future<void> toggleFavorite(Session session) {
    return (update(sessions)..where((tbl) => tbl.id.equals(session.id))).write(
      SessionsCompanion(
        status: session.status != Status.ended ? Value(Status.updated) : Value(Status.ended),
        isFavorite: Value(!session.isFavorite),
        updatedAt: Value(DateTime.now())
      )
    );
  }

  // クラッシュ・強制終了等で保存/破棄されないまま残ったセッション(起動時リカバリ用)
  Future<List<Session>> getInProgressSessions({required String userId}) {
    return (select(sessions)
        ..where((tbl) => tbl.userId.equals(userId) & tbl.status.equals(Status.inProgress.index))
        ..orderBy([(tbl) => OrderingTerm.asc(tbl.startedAt)]))
      .get();
  }

  Future<List<TrackPoint>> getTrackPointsForSession(String sessionId) {
    return (select(trackPoints)
        ..where((tbl) => tbl.sessionId.equals(sessionId))
        ..orderBy([(tbl) => OrderingTerm.asc(tbl.recordedAt)]))
      .get();
  }

  Stream<Session> getSessionById(String sessionId) {
    return (select(sessions)
        ..where((tbl) => tbl.id.equals(sessionId)))
      .watchSingle();
  }

  Future<List<Session>> getUnsyncedSessions({required String userId}) {
    return (select(sessions)
      ..where((tbl) => tbl.userId.equals(userId) & tbl.status.isIn([
            Status.ended.index,
            Status.updated.index,
            Status.deletedUnsynced.index,
          ]))
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.startedAt)])
    ).get();
  }
}

// dummy data
// extension AppDatabaseSeedExtension on AppDatabase {
//  Future<void> seedDummyData() async {
//    await delete(trackPoints).go();
//    await delete(sessions).go();
//
//    final uuid = const Uuid();
//    final now = DateTime.now();
//    final random = Random();
//
//    final dummiesSession = [
//      {'name': '夜ラーメン', 'method': 'walk', 'dist': 0.0, 'duration': 3, 'elev': 0.0, 'maxAlt': null, 'minAlt': null, 'daysAgo': 0},
//      {'name': '朝の散歩', 'method': 'walk', 'dist': 3.5, 'duration': 2400, 'elev': 25.0, 'maxAlt': 30.0, 'minAlt': 15.0, 'daysAgo': 2},
//      {'name': '夕方ランニング', 'method': 'run', 'dist': 8.2, 'duration': 3000, 'elev': 60.0, 'maxAlt': 70.0, 'minAlt': 35.0, 'daysAgo': 3},
//      {'name': '休日サイクリング', 'method': 'bicycle', 'dist': 18.0, 'duration': 4500, 'elev': 120.0, 'maxAlt': 65.0, 'minAlt': 20.0, 'daysAgo': 35},
//      {'name': '家族旅行', 'method': 'train', 'dist': 1000.0, 'duration': 8100, 'elev': 800.0, 'maxAlt': 150.0, 'minAlt': 15.0, 'daysAgo': 380}
//    ];
//
//    final userId = '11111111-1111-1111-1111-111111111111';
//
//    await batch((batch) {
//      for (final d in dummiesSession) {
//        final sessionId = uuid.v4();
//        final daysAgo = d['daysAgo'] as int;
//        final startedAt = now.subtract(Duration(days: daysAgo, hours: random.nextInt(3), minutes: random.nextInt(60)));
//        final duration = d['duration'] as int;
//        final endedAt = startedAt.add(Duration(seconds: duration));
//
//        batch.insert(
//          sessions,
//          SessionsCompanion.insert(
//            id: sessionId,
//            userId: userId,
//            name: Value(d['name'] as String),
//            startedAt: startedAt,
//            endedAt: Value(endedAt),
//            isFavorite: Value(false),
//            status: Value(Status.ended),
//            moveMethod: Value(MoveMethod.values.byName(d['method'] as String)),
//            totalDistance: Value(d['dist'] as double),
//            durationSeconds: Value(d['duration'] as int),
//            elevationGain: Value(d['elev'] as double),
//            maxAltitude: Value(d['maxAlt'] as double?),
//            minAltitude: Value(d['minAlt'] as double?)
//          )
//        );
//      }
//    });
//  }
//}


LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'app.sqlite'));
    appLog('db', 'SQLite DB Path: ${file.path}');
    return NativeDatabase.createInBackground(file);
  });
}