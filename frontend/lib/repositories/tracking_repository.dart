import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import '../utils/app_log.dart';
import '../models/recording_session.dart';
import '../models/status.dart';
import '../models/move_method.dart';

enum PushOutcome { succeeded, retryableError, conflict }

// 削除と編集の競合の種類。「保存する」を選んだときに呼ぶAPIが変わる
enum DeleteConflictKind {
  // 他端末で削除済み(パージ前のtombstone)。restoreで復活させる
  tombstoned,
  // 削除後にパージ済み。登録のPOSTで作り直す
  purged,
}

class PushResult {
  final PushOutcome outcome;
  final Session? conflictSession;
  final DeleteConflictKind? conflictKind;
  const PushResult(this.outcome, {this.conflictSession, this.conflictKind});
}

// 他端末で削除されたセッションをローカルで編集していた場合の競合解決の選択肢
enum DeleteConflictChoice { discard, keep }

/// 差分取得の基準時刻(last_synced_at)の保存先。テストではメモリ上の実装に差し替える
abstract class SyncStateStore {
  Future<String?> getLastSyncedAt();
  Future<void> setLastSyncedAt(String value);
  Future<void> clearLastSyncedAt();
}

/// ローカルDBのusers.last_synced_atに、ユーザーごとに保存する実装
class UserSyncStateStore implements SyncStateStore {
  final AppDatabase _db;
  final String _userId;

  UserSyncStateStore(this._db, this._userId);

  @override
  Future<String?> getLastSyncedAt() => _db.getLastSyncedAt(_userId);

  @override
  Future<void> setLastSyncedAt(String value) => _db.setLastSyncedAt(_userId, value);

  @override
  Future<void> clearLastSyncedAt() => _db.setLastSyncedAt(_userId, null);
}

/// ローカルのDB(Drift)とAPIサーバー(backend/docs/API設計ドラフト.md)の同期。
/// 端末側の約束はfrontend/docs/ユーザー機能追加に伴う変更予定.mdを参照
class TrackingRepository {
  final AppDatabase _db;
  final http.Client _client;
  final SyncStateStore _syncState;
  final String _userId;
  final String _baseUrl;
  final Future<DeleteConflictChoice> Function(Session session)? onDeleteConflict;
  // 同期してよいか(ログイン中・メールアドレスが確認済み・再ログイン不要)。falseの間は通信しない
  final bool Function() _canSync;
  // 外から渡されたクライアント(認証付きで共有している)はdisposeで閉じない
  final bool _ownsClient;
  Timer? _retryTimer;

  bool get isSchedulingRetry => _retryTimer != null;
  bool isSyncing = false;

  // APIの接続先。実機・Androidエミュレータからはlocalhostに届かないので、
  // `flutter run --dart-define=API_BASE_URL=http://<ホストのIP>:8080/api` のように切り替える
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080/api',
  );

  TrackingRepository(
    this._db,
    this._userId, {
    http.Client? client,
    this.onDeleteConflict,
    SyncStateStore? syncStateStore,
    String? baseUrl,
    bool Function()? canSync,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _syncState = syncStateStore ?? UserSyncStateStore(_db, _userId),
       _baseUrl = baseUrl ?? defaultBaseUrl,
       _canSync = canSync ?? (() => true) {
    // for test: delete last_synced_at every re-build
    _clearLastSyncedAtForTest();
  }

  void _clearLastSyncedAtForTest() {
    _syncState.clearLastSyncedAt();
  }

  // short timeout duration
  static const Duration _timeoutDuration = Duration(seconds: 3);

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Uri _sessionsUri([String path = '', Map<String, String>? queryParameters]) {
    final uri = Uri.parse('$_baseUrl/users/$_userId/sessions$path');
    return queryParameters == null ? uri : uri.replace(queryParameters: queryParameters);
  }

  // ローカルの変更直後の同期依頼。中身はrequestSyncと同じ
  Future<void> onUpdateData() => requestSync();

  // make sync action if nothing waiting for sync, or wait for next time of every 5 min-activating timer
  Future<void> requestSync() async {
    if (!_canSync()) return;
    if (isSchedulingRetry) return;
    if (isSyncing) {
      _startRetryTimer();
      return;
    }

    // try once and activate timer if not succeeded
    bool isSucceeded = await syncDiff();
    if (!isSucceeded) {
      _startRetryTimer();
    }
  }

  void _startRetryTimer() {
    if (_retryTimer != null) return;

    _retryTimer = Timer(const Duration(minutes: 5), () async {
      _retryTimer = null;
      // 再ログインが必要になった等で同期できなくなっていたら、再試行をやめる(条件が戻ったらrequestSyncで再開する)
      if (!_canSync()) return;
      final isSucceeded = await syncDiff();
      if (!isSucceeded) {
        _startRetryTimer();
      }
    });
  }

  void _stopReryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  // push → (削除と編集の競合の解決) → pull の順に同期する
  // return bool of succeeded/failed to manage sync timer
  Future<bool> syncDiff() async {
    if (!_canSync()) return false;
    bool isSucceeded = false;
    appLog('sync', 'start syncing');
    try {
      isSyncing = true;

      // push all unsynced sessions
      final pushResult = await pushUnsyncedSessions();
      appLog('sync', 'push result: ${pushResult.outcome}');

      // 他端末で削除済みのセッションを編集していた場合はダイアログ等で解決してからpullへ進む
      if (pushResult.outcome == PushOutcome.conflict) {
        final resolved = await _resolveDeleteConflict(
          pushResult.conflictSession!,
          pushResult.conflictKind!,
        );
        if (!resolved) return false;
      } else if (pushResult.outcome == PushOutcome.retryableError) {
        return false;
      }

      // pull remote data to local
      isSucceeded = await fetchRemoteSessions();
      appLog('sync', isSucceeded ? 'pull succeeded' : 'pull failed');
    } on TimeoutException {
      // do nothing if timeouted
      appLog('sync', 'sync failed by timeout');
    } on SocketException {
      // do nothing if no connection
      appLog('sync', 'sync failed by socket');
    } catch (e, stackTrace) {
      // do nothing if error occured
      appLog('sync', 'sync failed', error: e, stackTrace: stackTrace);
    } finally {
      isSyncing = false;
      appLog('sync', 'sync ended');
    }
    return isSucceeded;
  }

  // ---- push --------------------------------------------------------------------

  // push all unsynced sessions
  // 想定外のエラー・削除競合はどちらも「これ以上このサイクルで通信を続けない」シグナルとして扱う
  Future<PushResult> pushUnsyncedSessions() async {
    final unsyncedSessions = await _db.getUnsyncedSessions(userId: _userId);

    for (final session in unsyncedSessions) {
      if (session.status == Status.ended) {
        final response = await registerSession(session);
        if (_isSuccess(response)) {
          await _db.markAsSynced(sessionId: session.id, updatedAt: _updatedAtOf(response));
          continue;
        }
        if (response.statusCode == 409 && _errorCode(response) == 'id_conflicted') {
          // 別のセッションとidが衝突した。idを振り直し、次回の同期で新しいidで登録する
          await _db.reassignSessionId(oldId: session.id, newId: const Uuid().v4());
          continue;
        }
        if (response.statusCode == 409 && _errorCode(response) == 'deleted') {
          // 登録済み(レスポンスが届かなかった)で、その後に他端末で削除され、ローカルでは編集されていた
          return PushResult(
            PushOutcome.conflict,
            conflictSession: session,
            conflictKind: DeleteConflictKind.tombstoned,
          );
        }
        return _failure('register', session, response);
      }

      if (session.status == Status.updated) {
        final response = await updateSession(session);
        if (_isSuccess(response)) {
          await _db.markAsSynced(sessionId: session.id, updatedAt: _updatedAtOf(response));
          continue;
        }
        if (response.statusCode == 409 && _errorCode(response) == 'deleted') {
          return PushResult(
            PushOutcome.conflict,
            conflictSession: session,
            conflictKind: DeleteConflictKind.tombstoned,
          );
        }
        if (_isSessionNotFound(response)) {
          return PushResult(
            PushOutcome.conflict,
            conflictSession: session,
            conflictKind: DeleteConflictKind.purged,
          );
        }
        return _failure('update', session, response);
      }

      if (session.status == Status.deletedUnsynced) {
        final response = await pushSessionDeletion(session);
        // 404(session_not_found)はパージ済み・未登録で、サーバーにそのsessionが無い状態なので削除完了として扱う
        if (_isSuccess(response) || _isSessionNotFound(response)) {
          await _db.finalizeSessionDeletion(sessionId: session.id);
          continue;
        }
        return _failure('delete', session, response);
      }
    }

    return const PushResult(PushOutcome.succeeded);
  }

  // 他端末での削除とローカルの未同期な変更が競合した際の解決。解決できたらtrueを返す
  Future<bool> _resolveDeleteConflict(Session session, DeleteConflictKind kind) async {
    final choice = onDeleteConflict != null
      ? await onDeleteConflict!(session)
      : DeleteConflictChoice.discard;

    if (choice == DeleteConflictChoice.discard) {
      await _db.finalizeSessionDeletion(sessionId: session.id);
      return true;
    }

    if (kind == DeleteConflictKind.tombstoned) {
      final response = await reviveSession(session);
      if (_isSuccess(response)) {
        await _db.markAsSynced(sessionId: session.id, updatedAt: _updatedAtOf(response));
        return true;
      }
      if (!_isSessionNotFound(response)) {
        _logFailure('restore', session, response);
        return false;
      }
      // 復活させる前にパージされていたので、登録として作り直す
    }

    final response = await registerSession(session);
    if (_isSuccess(response)) {
      await _db.markAsSynced(sessionId: session.id, updatedAt: _updatedAtOf(response));
      return true;
    }
    _logFailure('register', session, response);
    return false;
  }

  // 登録(POST)。新規なら201、同じidの再送なら200
  Future<http.Response> registerSession(Session session) async {
    final trackPoints = await _db.getTrackPointsForSession(session.id);
    final payload = {
      'id': session.id,
      'name': session.name,
      'started_at': session.startedAt.toUtc().toIso8601String(),
      'ended_at': session.endedAt?.toUtc().toIso8601String(),
      'is_favorite': session.isFavorite,
      'move_method': session.moveMethod.name,
      'total_distance': session.totalDistance,
      'duration_seconds': session.durationSeconds,
      'elevation_gain': session.elevationGain,
      'max_altitude': session.maxAltitude,
      'min_altitude': session.minAltitude,
      'track_points': trackPoints.map((tp) => {
        'recorded_at': tp.recordedAt.toUtc().toIso8601String(),
        'latitude': tp.latitude,
        'longitude': tp.longitude,
        'altitude': tp.altitude,
      }).toList(),
    };

    return _client
      .post(_sessionsUri(), headers: _jsonHeaders, body: jsonEncode(payload))
      .timeout(_timeoutDuration);
  }

  // 修正(PATCH)。可変の3項目を毎回全て送る
  Future<http.Response> updateSession(Session session) {
    return _client
      .patch(_sessionsUri('/${session.id}'), headers: _jsonHeaders, body: jsonEncode(_editPayload(session)))
      .timeout(_timeoutDuration);
  }

  // 削除(DELETE)。サーバーがtombstoneにする(deleted_atはサーバーが削除した日時を入れる)
  Future<http.Response> pushSessionDeletion(Session session) {
    return _client
      .delete(_sessionsUri('/${session.id}'), headers: {'Accept': 'application/json'})
      .timeout(_timeoutDuration);
  }

  // 削除の取り消し(restore)。編集内容(可変の3項目)も同時に反映する
  Future<http.Response> reviveSession(Session session) {
    return _client
      .post(_sessionsUri('/${session.id}/restore'), headers: _jsonHeaders, body: jsonEncode(_editPayload(session)))
      .timeout(_timeoutDuration);
  }

  Map<String, dynamic> _editPayload(Session session) => {
    'name': session.name,
    'move_method': session.moveMethod.name,
    'is_favorite': session.isFavorite,
  };

  // ---- pull --------------------------------------------------------------------

  // 差分取得。成功したらサーバーのsynced_atを次回のlast_synced_atとして保存する
  Future<bool> fetchRemoteSessions() async {
    final lastSyncedAt = await _syncState.getLastSyncedAt();
    final response = await _client
      .get(
        _sessionsUri('', lastSyncedAt == null ? null : {'last_synced_at': lastSyncedAt}),
        headers: {'Accept': 'application/json'},
      )
      .timeout(_timeoutDuration);

    if (!_isSuccess(response)) {
      _logFailure('fetch', null, response);
      return false;
    }

    final body = json.decode(response.body) as Map<String, dynamic>;
    final receivedIds = <String>{};
    for (final item in (body['sessions'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final String sessionId = item['id'];
      receivedIds.add(sessionId);

      // 他端末での削除tombstone(idとdeleted_atのみ)ならローカルの行を物理削除して終わり
      if (item.containsKey('deleted_at')) {
        await _db.finalizeSessionDeletion(sessionId: sessionId);
        continue;
      }

      final session = Session(
        id: sessionId,
        userId: _userId,
        name: item['name'],
        startedAt: DateTime.parse(item['started_at']).toLocal(),
        endedAt: DateTime.parse(item['ended_at']).toLocal(),
        status: Status.synced,
        isFavorite: item['is_favorite'] as bool,
        moveMethod: MoveMethod.values.byName(item['move_method'] as String),
        totalDistance: (item['total_distance'] as num).toDouble(),
        durationSeconds: (item['duration_seconds'] as num).toInt(),
        elevationGain: (item['elevation_gain'] as num).toDouble(),
        maxAltitude: (item['max_altitude'] as num?)?.toDouble(),
        minAltitude: (item['min_altitude'] as num?)?.toDouble(),
        updatedAt: DateTime.parse(item['updated_at']).toLocal(),
      );
      final trackPoints = (item['track_points'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map((tpJson) => TrackPoint(
          id: 0,
          sessionId: sessionId,
          recordedAt: DateTime.parse(tpJson['recorded_at']).toLocal(),
          latitude: (tpJson['latitude'] as num).toDouble(),
          longitude: (tpJson['longitude'] as num).toDouble(),
          altitude: (tpJson['altitude'] as num).toDouble(),
        ))
        .toList();

      await _db.upsertByFetchedData(session: session, tps: trackPoints);
    }

    // パージ期間より前に同期したきりだった場合は、パージ済みの削除を突き合わせで補う。
    // 突き合わせが成功するまでlast_synced_atは更新しない(途中で失敗しても次回もう一度突き合わせるため)
    if (body['request_existence_check'] == true) {
      final checked = await _checkExistence(receivedIds);
      if (!checked) return false;
    }

    await _syncState.setLastSyncedAt(body['synced_at'] as String);
    return true;
  }

  // 削除の突き合わせ。同期済みのセッションのうち、今回のpullで受け取らなかったもののidを送り、
  // サーバーに(生きているsessionとして)存在しないものをローカルから削除する
  Future<bool> _checkExistence(Set<String> receivedIds) async {
    final sessionIds = (await _db.getSyncedSessionIds(userId: _userId))
      .where((id) => !receivedIds.contains(id))
      .toList();
    final response = await _client
      .post(_sessionsUri('/existence-check'), headers: _jsonHeaders, body: jsonEncode({'session_ids': sessionIds}))
      .timeout(_timeoutDuration);
    if (!_isSuccess(response)) {
      _logFailure('existence-check', null, response);
      return false;
    }

    final body = json.decode(response.body) as Map<String, dynamic>;
    for (final sessionId in (body['missing_session_ids'] as List<dynamic>).cast<String>()) {
      await _db.finalizeSessionDeletion(sessionId: sessionId);
    }
    return true;
  }

  // ---- レスポンスの判定 -----------------------------------------------------------

  bool _isSuccess(http.Response response) => response.statusCode ~/ 100 == 2;

  // エラーの種類(レスポンスbodyのcode)。分岐はステータスコードだけでなくcodeで行う
  String? _errorCode(http.Response response) {
    try {
      final body = json.decode(response.body);
      return body is Map<String, dynamic> ? body['code'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  // 「当該ユーザーのsessionとして存在しない」404かどうか。user_not_foundやcodeの無い404
  // (接続先の設定ミス等)は含めない(誤ってローカルのデータを消したり再登録したりしないため)
  bool _isSessionNotFound(http.Response response) =>
    response.statusCode == 404 && _errorCode(response) == 'session_not_found';

  DateTime _updatedAtOf(http.Response response) {
    final body = json.decode(response.body) as Map<String, dynamic>;
    return DateTime.parse(body['updated_at'] as String).toLocal();
  }

  PushResult _failure(String action, Session session, http.Response response) {
    _logFailure(action, session, response);
    return const PushResult(PushOutcome.retryableError);
  }

  void _logFailure(String action, Session? session, http.Response response) {
    // サーバーのログと突き合わせられるよう、リクエストIDも出す
    appLog('sync', '$action failed: ${response.statusCode} ${_errorCode(response) ?? ''} '
      '${session == null ? '' : '(session ${session.id}) '}'
      'request_id=${response.headers['x-request-id']}');
  }

  // for tracking service
  Future<int> initSession({
    required RecordingSession session,
  }) {
    return _db.initSession(session: session, userId: _userId);
  }

  Future<int> addTrackPoint({
    required String sessionId,
    required double latitude,
    required double longitude,
    required double altitude,
    required DateTime recordedAt,
  }) {
    return _db.addTrackPoint(
      sessionId: sessionId,
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      recordedAt: recordedAt,
    );
  }

  Future<void> saveCompletedSession({
    required RecordingSession session,
    required String name,
    required MoveMethod moveMethod,
    required DateTime savedAt,
  }) async {
    await _db.saveCompletedSession(
      session: session,
      name: name,
      moveMethod: moveMethod,
      savedAt: savedAt,
    );
    return await onUpdateData();
  }

  Future<void> deleteRecordingSession({
    required RecordingSession session,
  }) async {
    await _db.deleteRecordingSession(session: session);
    return await onUpdateData();
  }

  // 起動時リカバリ用: 孤立したinProgressセッションとそのtrackpoints
  Future<List<Session>> getInProgressSessions() => _db.getInProgressSessions(userId: _userId);

  Future<List<TrackPoint>> getTrackPointsForSession(String sessionId) {
    return _db.getTrackPointsForSession(sessionId);
  }

  Future<void> deleteSession(Session session) async {
    await _db.deleteSession(session: session);
    return await onUpdateData();
  }

  Future<void> toggleFavorite(Session session) async {
    await _db.toggleFavorite(session);
    return await onUpdateData();
  }

  Future<void> updateSessionInfo({
    required Session session,
    required String sessionName,
    required MoveMethod moveMethod,
  }) async {
    await _db.updateSession(
      session: session,
      sessionName: sessionName,
      moveMethod: moveMethod,
      isFavorite: session.isFavorite,
    );
    return await onUpdateData();
  }

  void dispose() {
    _stopReryTimer();
    if (_ownsClient) _client.close();
  }
}