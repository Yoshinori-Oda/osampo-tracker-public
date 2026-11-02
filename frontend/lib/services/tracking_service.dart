import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import '../repositories/tracking_repository.dart';
import '../models/recording_session.dart';
import '../models/move_method.dart';
import '../models/location_banner.dart';
import '../models/recording_phase.dart';
import '../utils/save_or_discard_screen.dart';
import '../utils/delete_conflict_dialog.dart' show navigatorKey, scaffoldMessengerKey;
import '../utils/duration_format.dart';
import 'location_stream_settings.dart';

// 端末/アプリ側の設定が原因で位置情報が取れなくなっている状態
enum _LocationPermissionTrouble { none, serviceDisabled, permissionDenied }

// 新鮮な位置情報が取れず、フォールバック候補も古すぎる/存在しないため開始できない
class StartRecordingBlockedException implements Exception {
  const StartRecordingBlockedException();
}

class TrackingService {
  // singleton services
  final TrackingRepository _repo;
  final _uuid = const Uuid();

  // 位置情報が「悪い精度」とみなすaccuracyのしきい値(メートル)
  static const double _poorAccuracyThresholdMeters = 50.0;
  // 更新が何秒途絶えたら「止まっている」とみなすか
  static const Duration _staleThreshold = Duration(seconds: 10);
  static const int _accuracyTroubleIncrement = 3;
  static const int _accuracyTroubleMax = 9;
  // startRecording: 新鮮な位置情報取得のtimeout
  static const Duration _startFreshPositionTimeout = Duration(seconds: 5);
  // startRecording: この時間を超えて古い位置情報はフォールバックとして使わずブロックする
  static const Duration _startFallbackAgeLimit = Duration(seconds: 15);

  StreamSubscription<Position>? _positionStreamSubscription;
  // 現在の購読がバックグラウンド継続用の設定(buildPositionStreamSettings(background: true))かどうか
  bool _subscribedForBackground = false;
  // アプリがバックグラウンド(hidden/paused)にいるか
  bool _isAppInBackground = false;
  // 購読の開始/停止/切り替えを直列化するためのチェーン(フェーズ変化とライフサイクル変化が
  // 前後して呼ばれても、二重購読や停止漏れが起きないようにする)
  Future<void> _streamSyncChain = Future.value();
  // 位置情報の監視を(再)開始した時刻。サスペンドからの復帰直後に、止めていた間の空白を
  // 「更新停止」としてバナー表示しないための起点
  DateTime? _monitoringStartedAt;
  bool _disposed = false;
  Position? _lastPosition;
  Position? _lastReceivedPosition;

  RecordingSession? _session;
  Timer? _timer;
  Timer? _bannerWatchdogTimer;

  // 起動時リカバリで見つかった、まだ保存/破棄していないセッションのキュー(先頭から順に_sessionへ積む)
  final List<RecordingSession> _recoveryQueue = [];
  // stopping中に表示するダイアログの説明文(強制停止/リカバリの理由。通常の停止では null)
  String? _pendingCompletionInfoMessage;

  // 収録タブのボトムナビゲーションindex。タブに関わらず即座に処理できる場合はここで判定する
  static const int _recordingTabIndex = 0;
  final int Function() _getCurrentTabIndex;
  final void Function() _switchToRecordingTab;

  DateTime? _lastGoodPositionAt;
  int _accuracyTroubleCount = 0;
  _LocationPermissionTrouble _permissionTrouble = _LocationPermissionTrouble.none;

  RecordingPhase _phase = RecordingPhase.idle;
  bool _startCancelled = false;

  // controllers to watch states (for Riverpod / UI)
  final _recordingPhaseController = StreamController<RecordingPhase>.broadcast();
  final _currentPositionController = StreamController<Position>.broadcast();
  final _recordingSessionController = StreamController<RecordingSession?>.broadcast();
  final _locationBannerController = StreamController<LocationBannerState>.broadcast();

  // exported streams
  Stream<RecordingPhase> get recordingPhaseStream => _recordingPhaseController.stream;
  Stream<Position> get currentPositionStream => _currentPositionController.stream;
  Stream<RecordingSession?> get recordingSessionStream => _recordingSessionController.stream;
  Stream<LocationBannerState> get locationBannerStream => _locationBannerController.stream;

  // startRecordingのフォールバック確認に使う、このセッションで最後に確認できた位置情報の受信時刻
  DateTime? get lastGoodPositionAt => _lastGoodPositionAt;

  // getters
  RecordingPhase get phase => _phase;
  bool get isRecording => _session != null;
  RecordingSession? get recordingSession => _session;
  String? get currentSessionId => _session?.sessionId;
  double? get elevationGain => _session?.elevationGain;
  double? get maxAltitude => _session?.maxAltitude;
  double? get minAltitude => _session?.minAltitude;
  double? get avgSpeed => _session?.avgSpeed;

  void _setPhase(RecordingPhase phase) {
    _phase = phase;
    _recordingPhaseController.add(phase);
    // 収録の有無に合わせて購読設定を切り替える。権限エラー等で購読が止まっている場合に
    // ここで勝手に再購読しないよう、購読していなければ開始しない(再開はrefreshLocationAvailabilityの役割)
    _syncPositionStream(startIfStopped: false);
  }

  // 収録中(開始処理中を含む)は、バックグラウンドに回っても記録を継続する設定で購読する。
  // startingから切り替えるのは、Android 12以降はバックグラウンドからForeground Serviceを
  // 起動できないため、ユーザーがRECを押した直後(確実にフォアグラウンドにいる時点)で起動しておくため
  bool get _needsBackgroundTracking =>
    _phase == RecordingPhase.starting || _phase == RecordingPhase.recording;

  // 起動時の権限要求〜初回購読の完了
  late final Future<void> _initialization;

  @visibleForTesting
  Future<void> get initialization => _initialization;

  @visibleForTesting
  Future<void> get positionStreamSynced => _streamSyncChain;

  TrackingService(
    this._repo, {
    required int Function() getCurrentTabIndex,
    required void Function() switchToRecordingTab
  }) : _getCurrentTabIndex = getCurrentTabIndex,
       _switchToRecordingTab = switchToRecordingTab {
    _initialization = _initTrackingStream();
  }

  Future<bool> checkAndRequestPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    return true;
  }

  // track position
  Future<void> _initTrackingStream() async {
    final hasPermission = await checkAndRequestPermission();
    if (!hasPermission) {
      // サービスOFF/権限拒否のままストリームを一度も購読できないと、
      // onErrorが発火する機会が無くバナーがneverAcquired/stalledにフォールバックし続けてしまうため、
      // ここで明示的にtrouble種別を判定してバナーへ反映する
      _permissionTrouble = await _detectLocationTrouble();
      _recomputeBanner();
      return;
    }

    await _requestNotificationPermission();
    await _syncPositionStream(startIfStopped: true);
  }

  // Android 13以降は、収録中のForeground Serviceの常駐通知を表示するのに通知権限が必要
  // (拒否されてもServiceは動くが、通知ドロワーに表示されなくなる)。geolocatorは要求しないため自前で要求する
  Future<void> _requestNotificationPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await ph.Permission.notification.request();
    } catch (_) {}
  }

  // 許可ダイアログを出さずに、現在のサービス/権限の状態のみを判定する
  // (checkAndRequestPermissionと違い、フォアグラウンド復帰時などに繰り返し呼んでも安全)
  Future<_LocationPermissionTrouble> _detectLocationTrouble() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return _LocationPermissionTrouble.serviceDisabled;

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return _LocationPermissionTrouble.permissionDenied;
    }

    return _LocationPermissionTrouble.none;
  }

  // アプリのライフサイクル変化時に呼ぶ(main_page.dartのWidgetsBindingObserverから)。
  // 収録中でなければバックグラウンドでは購読を止めてサスペンドし、復帰時に再開する
  Future<void> handleAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _isAppInBackground = true;
        await _syncPositionStream(startIfStopped: false);
      case AppLifecycleState.resumed:
        _isAppInBackground = false;
        await refreshLocationAvailability();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // inactiveは権限ダイアログ/コントロールセンター表示中などにも来るため、購読は維持する
        break;
    }
  }

  // 現在のフェーズとライフサイクルに合わせて、位置情報ストリームの購読を開始/停止/切り替えする。
  // startIfStopped=falseの場合、購読していない状態からは開始しない(権限エラーでストリームが
  // 止まっている時などに、フェーズ変化をきっかけに勝手に再購読しないため)
  Future<void> _syncPositionStream({required bool startIfStopped}) {
    final op = _streamSyncChain.then((_) => _doSyncPositionStream(startIfStopped: startIfStopped));
    _streamSyncChain = op.catchError((_) {});
    return _streamSyncChain;
  }

  Future<void> _doSyncPositionStream({required bool startIfStopped}) async {
    // dispose後に、それ以前に積まれていた同期処理が購読し直してしまわないようにする
    if (_disposed) return;
    final background = _needsBackgroundTracking;

    if (_isAppInBackground && !background) {
      await _stopPositionStream();
      return;
    }

    if (_positionStreamSubscription != null) {
      if (_subscribedForBackground == background) return;
      await _stopPositionStream();
    } else if (!startIfStopped) {
      return;
    }

    await _startPositionStream(background: background);
  }

  Future<void> _stopPositionStream() async {
    final subscription = _positionStreamSubscription;
    _positionStreamSubscription = null;
    await subscription?.cancel();

    // 購読していない間は監視タイマーも止める(復帰時の_startPositionStreamで再開する)
    _bannerWatchdogTimer?.cancel();
    _bannerWatchdogTimer = null;
  }

  Future<void> _startPositionStream({required bool background}) async {
    if (_positionStreamSubscription != null) return;
    _monitoringStartedAt = DateTime.now();

    // get initial position (取れなくても以後はストリームからの更新を待つだけで良い)。
    // 収録開始時の切り替えではstartRecording側が自前で取得するため省略する
    if (!background) {
      try {
        final initialPosition = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 1)
          )
        );
        _onPositionReceived(initialPosition);
      } catch (_) {}
    }

    // 待機中にフェーズが変わっていた場合は、_setPhaseが後ろに積んだ同期処理で設定が合わせ直される
    _subscribedForBackground = background;
    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: buildPositionStreamSettings(background: background)
    ).listen(
      (Position position) async {
        _onPositionReceived(position);

        // 精度が悪い点はUI表示(現在地表示など)には使うが、
        // 距離・高度の積算(_onRecordingPositionUpdated)には使わない
        final isAccuracyOk = position.accuracy <= _poorAccuracyThresholdMeters;
        if (isRecording && _timer != null && isAccuracyOk) {
          await _onRecordingPositionUpdated(position);
        }
      },
      onError: _handleLocationStreamError
    );

    // 更新が来ていない間もバナーの表示/経過時間表示を追従させるための監視タイマー
    _bannerWatchdogTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => _recomputeBanner());
  }

  // アプリのフォアグラウンド復帰時に呼ぶ。設定アプリでサービス/権限をON/OFFされても
  // ストリームのonErrorやgetCurrentPositionの再試行が自動では起きないため、都度明示的に
  // 再チェックし、trouble状態の更新とストリームの再購読(復旧時)を行う
  Future<void> refreshLocationAvailability() async {
    final trouble = await _detectLocationTrouble();
    _permissionTrouble = trouble;
    _recomputeBanner();

    if (trouble == _LocationPermissionTrouble.none) {
      await _syncPositionStream(startIfStopped: true);
      return;
    }

    // 設定アプリでの操作はストリームのonErrorを発火させないため、収録中の強制停止も
    // ここで明示的にトリガーする(onError経由の_handleLocationStreamErrorと同じ扱い)。
    // stopping中(保存/破棄待ち)にフォアグラウンド復帰を繰り返しても再度停止処理が
    // 走らないよう、実際に収録中(recording)の場合のみ発火させる
    if (_phase == RecordingPhase.recording) {
      await _forceStopForPermissionTrouble();
    }
  }

  // 位置情報を(精度に関わらず)受信した際の共通処理
  void _onPositionReceived(Position position) {
    _currentPositionController.add(position);
    _lastReceivedPosition = position;

    final wasStale = _lastGoodPositionAt == null ||
      DateTime.now().difference(_lastGoodPositionAt!) >= _staleThreshold;

    _lastGoodPositionAt = DateTime.now();
    _permissionTrouble = _LocationPermissionTrouble.none;

    // 長時間の停止から復帰した場合は、停止前の精度状態を引きずらずクリーンに再スタートする
    if (wasStale) {
      _accuracyTroubleCount = 0;
    }

    if (position.accuracy > _poorAccuracyThresholdMeters) {
      _accuracyTroubleCount = min(_accuracyTroubleCount + _accuracyTroubleIncrement, _accuracyTroubleMax);
    } else {
      _accuracyTroubleCount = max(_accuracyTroubleCount - 1, 0);
    }

    _recomputeBanner();
  }

  // 位置情報サービスOFF・権限剥奪などストリーム側のエラー
  void _handleLocationStreamError(Object error) {
    if (error is LocationServiceDisabledException) {
      _permissionTrouble = _LocationPermissionTrouble.serviceDisabled;
    } else if (error is PermissionDeniedException) {
      _permissionTrouble = _LocationPermissionTrouble.permissionDenied;
    } else {
      // 未知のエラーはバナー化せず、次の正常な更新を待つ
      return;
    }

    // geolocator側でストリームは終了しているため、復旧後にrefreshLocationAvailability()
    // から再購読できるようクリアしておく
    _positionStreamSubscription = null;

    _recomputeBanner();

    if (isRecording) {
      _forceStopForPermissionTrouble();
    }
  }

  void _recomputeBanner() {
    _locationBannerController.add(_computeBannerState());
  }

  LocationBannerState _computeBannerState() {
    if (_permissionTrouble == _LocationPermissionTrouble.serviceDisabled) {
      return const LocationBannerState(kind: LocationBannerKind.serviceDisabled);
    }
    if (_permissionTrouble == _LocationPermissionTrouble.permissionDenied) {
      return const LocationBannerState(kind: LocationBannerKind.permissionDenied);
    }

    if (_lastGoodPositionAt == null) {
      return const LocationBannerState(kind: LocationBannerKind.neverAcquired);
    }

    // サスペンドからの復帰直後は、止めていた間の空白を「更新停止」扱いしないよう、
    // 監視を再開した時刻の方が新しければそちらを起点にする(経過時間の表示は実際の最終受信から)
    final elapsed = DateTime.now().difference(_lastGoodPositionAt!);
    final monitoringStartedAt = _monitoringStartedAt;
    final staleBase = monitoringStartedAt != null && monitoringStartedAt.isAfter(_lastGoodPositionAt!)
      ? monitoringStartedAt
      : _lastGoodPositionAt!;
    if (DateTime.now().difference(staleBase) >= _staleThreshold) {
      return LocationBannerState(kind: LocationBannerKind.stalled, elapsedSinceLastGood: elapsed);
    }

    if (_accuracyTroubleCount > 0) {
      return const LocationBannerState(kind: LocationBannerKind.accuracyLow);
    }

    return LocationBannerState.none;
  }

  // 収録中に位置情報の権限/サービスが失われた場合、収録を強制的に終了し保存/破棄を確認する
  Future<void> _forceStopForPermissionTrouble() async {
    if (!isRecording) return;

    final session = _session;
    if (session == null) return;

    // 位置情報が失われている最中なので、最終ポイント取得は試みずそのまま終了する
    await stopRecording(skipFinalPositionFetch: true);

    _pendingCompletionInfoMessage = '位置情報の利用が失われたため、収録を停止しました。';
    await _presentPendingCompletion();
  }

  // stoppingに入った(=保存/破棄が必要になった)瞬間に呼ぶ。収録タブを見ていれば直接保存/破棄画面、
  // そうでなければSnackBarで気づかせてから収録タブへ誘導する(タップで resumePendingCompletion)。
  // 保存/破棄画面が既に開いている場合(起動時リカバリのキューの次の1件)は、タブに関わらず
  // その画面を次のセッションの画面へ差し替える
  Future<void> _presentPendingCompletion() async {
    if (isSaveOrDiscardScreenOpen || _getCurrentTabIndex() == _recordingTabIndex) {
      await _showPendingCompletionScreen();
      return;
    }

    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: const Text('保存/破棄が必要なセッションがあります'),
        action: SnackBarAction(
          label: '収録画面へ',
          onPressed: () => resumePendingCompletion()
        )
      )
    );
  }

  Future<void> _showPendingCompletionScreen() async {
    final session = _session;
    if (session == null) return;

    await showSaveOrDiscardScreen(
      session: session,
      infoMessage: _pendingCompletionInfoMessage,
      onDiscard: () => completeSession(doSave: false),
      onSave: (sessionName, moveMethod) => completeSession(
        doSave: true,
        sessionName: sessionName,
        moveMethod: moveMethod
      )
    );
  }

  // 通常の停止直後、およびバナー/収録タブのボタンから、保留中セッションの保存/破棄画面を呼び出す
  Future<void> resumePendingCompletion() async {
    if (_phase != RecordingPhase.stopping || _session == null) return;

    if (_getCurrentTabIndex() != _recordingTabIndex) {
      _switchToRecordingTab();
    }
    await _showPendingCompletionScreen();
  }

  // 起動時に一度呼び、クラッシュ・強制終了等で保存/破棄されないまま残ったセッションを検出する。
  // 複数件見つかった場合は全件をキューに積み、1件ずつ保存/破棄させる(「複数端末同時操作なし」
  // の前提上、通常は起きないはずだが、内部DBを直接書き換えない限り復旧できないため備えておく)
  Future<void> recoverOrphanedSessions() async {
    if (isRecording) return;

    final orphanedSessions = await _repo.getInProgressSessions();
    if (orphanedSessions.isEmpty) return;

    for (final session in orphanedSessions) {
      final trackPoints = await _repo.getTrackPointsForSession(session.id);
      if (trackPoints.isEmpty) {
        // 最初のtrackpoint書き込み前に失われたセッションは保存しようがないため破棄する
        await _repo.deleteRecordingSession(
          session: RecordingSession(
            sessionId: session.id,
            startedAt: session.startedAt,
            endedAt: session.startedAt,
            totalDistance: 0.0,
            elapsedSeconds: 0,
            elevationGain: 0.0,
            maxAltitude: 0.0,
            minAltitude: 0.0
          )
        );
        continue;
      }

      _recoveryQueue.add(_rebuildRecordingSessionFromTrackPoints(
        session: session,
        trackPoints: trackPoints
      ));
    }

    if (_recoveryQueue.isNotEmpty) {
      _dequeueNextRecovery();
    }
  }

  // 生き残ったtrackpointsから集計値を再計算してRecordingSessionを復元する。
  // ライブ計算にあった精度フィルタ等は再現できないため、多少の誤差は許容する
  RecordingSession _rebuildRecordingSessionFromTrackPoints({
    required Session session,
    required List<TrackPoint> trackPoints
  }) {
    double totalDistance = 0.0;
    double elevationGain = 0.0;
    double maxAltitude = trackPoints.first.altitude ?? 0.0;
    double minAltitude = trackPoints.first.altitude ?? 0.0;

    for (var i = 1; i < trackPoints.length; i++) {
      final prev = trackPoints[i - 1];
      final curr = trackPoints[i];
      final prevAltitude = prev.altitude ?? 0.0;
      final currAltitude = curr.altitude ?? 0.0;

      totalDistance += Geolocator.distanceBetween(
        prev.latitude, prev.longitude, curr.latitude, curr.longitude
      ) / 1000.0;
      elevationGain += max(0.0, currAltitude - prevAltitude);
      maxAltitude = max(maxAltitude, currAltitude);
      minAltitude = min(minAltitude, currAltitude);
    }

    final lastRecordedAt = trackPoints.last.recordedAt;
    // recordedAtはstartedAtより前になり得る(フォールバック開始時のPosition.timestamp)ためクランプする
    final elapsedSeconds = max(0, lastRecordedAt.difference(session.startedAt).inSeconds);

    return RecordingSession(
      sessionId: session.id,
      startedAt: session.startedAt,
      endedAt: lastRecordedAt,
      totalDistance: totalDistance,
      elapsedSeconds: elapsedSeconds,
      elevationGain: elevationGain,
      maxAltitude: maxAltitude,
      minAltitude: minAltitude
    );
  }

  void _dequeueNextRecovery() {
    _session = _recoveryQueue.removeAt(0);
    _pendingCompletionInfoMessage = '前回のセッションが意図せず中断されました。保存/破棄を選択してください。';
    _setPhase(RecordingPhase.stopping);
    _recordingSessionController.add(recordingSession);
    _presentPendingCompletion();
  }

  // start recording
  Future<void> startRecording() async {
    if (_phase != RecordingPhase.idle) return;

    _startCancelled = false;
    _setPhase(RecordingPhase.starting);

    final hasPermission = await checkAndRequestPermission();
    if (_startCancelled) {
      _setPhase(RecordingPhase.idle);
      return;
    }
    if (!hasPermission) {
      _setPhase(RecordingPhase.idle);
      throw Exception('位置情報の利用権限が許可されていません。');
    }

    Position? startPosition;
    try {
      startPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: _startFreshPositionTimeout
        )
      );
      _onPositionReceived(startPosition);
    } catch (_) {
      startPosition = null;
    }

    if (_startCancelled) {
      _setPhase(RecordingPhase.idle);
      return;
    }

    if (startPosition == null) {
      startPosition = await _resolveFallbackStartPosition();
      if (startPosition == null) {
        _setPhase(RecordingPhase.idle);
        return;
      }
    }

    await _beginSession(startPosition);
    _setPhase(RecordingPhase.recording);
  }

  // ユーザーによる開始処理のキャンセル(ローディング中のみ有効)
  void cancelStarting() {
    if (_phase == RecordingPhase.starting) {
      _startCancelled = true;
    }
  }

  // 新鮮な位置情報が取れなかった場合のフォールバック判定。
  // 15秒以内ならこのセッション内で最後に確認できた位置から開始するか確認ダイアログを出し、
  // それより古い/一度も取得できていない場合は開始をブロックする(例外を投げる)。
  Future<Position?> _resolveFallbackStartPosition() async {
    final lastGoodAt = _lastGoodPositionAt;
    final lastPosition = _lastReceivedPosition;

    if (lastGoodAt == null || lastPosition == null) {
      _setPhase(RecordingPhase.idle);
      throw const StartRecordingBlockedException();
    }

    final age = DateTime.now().difference(lastGoodAt);
    if (age >= _startFallbackAgeLimit) {
      _setPhase(RecordingPhase.idle);
      throw const StartRecordingBlockedException();
    }

    final confirmed = await _confirmStartFromLastPosition(lastGoodAt, age);
    if (_startCancelled || confirmed != true) {
      return null;
    }
    return lastPosition;
  }

  Future<bool?> _confirmStartFromLastPosition(DateTime lastGoodAt, Duration age) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('現在地を取得できませんでした'),
        content: Text(
          '最後に確認できた位置情報を使って収録を開始しますか?\n\n'
          '${formatTimeOfDayJa(lastGoodAt)}(${formatElapsedJa(age)})の位置情報です。'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル')
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('この地点から開始')
          )
        ]
      )
    );
  }

  Future<void> _beginSession(Position startPosition) async {
    _lastPosition = startPosition;

    final now = DateTime.now();

    // create session
    _session = RecordingSession(
      sessionId: _uuid.v4(),
      startedAt: now,
      endedAt: null,
      totalDistance: 0.0,
      elapsedSeconds: 0,
      elevationGain: 0.0,
      maxAltitude: startPosition.altitude,
      minAltitude: startPosition.altitude
    );

    // writing into DB
    await _repo.initSession(
      session: _session!,
    );
    // save current position as initial point of session
    // (recordedAtは押下時刻ではなく、その位置情報が実際に取得された時刻を使う)
    await _repo.addTrackPoint(
      sessionId: _session!.sessionId,
      latitude: startPosition.latitude,
      longitude: startPosition.longitude,
      altitude: startPosition.altitude,
      recordedAt: startPosition.timestamp
    );

    // initialize tracking-state for UI
    _recordingSessionController.add(recordingSession!);

    // start the timer
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _session = _session!.copyWith(elapsedSeconds: _session!.elapsedSeconds + 1);
      _recordingSessionController.add(recordingSession!);

      if (_session!.elapsedSeconds % 5 == 0) {
        _repo.addTrackPoint(
          sessionId: _session!.sessionId,
          latitude: _lastPosition!.latitude,
          longitude: _lastPosition!.longitude,
          altitude: _lastPosition!.altitude,
          recordedAt: DateTime.now()
        );
      }
    });
  }

  // update position
  Future<void> _onRecordingPositionUpdated(Position currentPosition) async {
    if (!isRecording) return;

    // total distance
    if (_lastPosition != null) {
      final horizontalDistance = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        currentPosition.latitude,
        currentPosition.longitude
      );
      
      // check if the currentPosition altitude is valid
      // if not, replace it with _lastPosition's
      final altitudeDiff = (currentPosition.altitude - _lastPosition!.altitude).abs();
      if (altitudeDiff < 0.5 || altitudeDiff > 75.0) {
        currentPosition = Position(
          timestamp: currentPosition.timestamp,
          latitude: currentPosition.latitude,
          longitude: currentPosition.longitude,
          accuracy: currentPosition.accuracy,
          altitude: _lastPosition!.altitude,
          altitudeAccuracy: _lastPosition!.accuracy,
          heading: currentPosition.heading,
          headingAccuracy: currentPosition.headingAccuracy,
          speed: currentPosition.speed,
          speedAccuracy: currentPosition.speedAccuracy
        );
      }

      // calculate distance and add to _totalDistance
      late double distanceMeter;
      if (currentPosition.altitude == _lastPosition!.altitude) {
        distanceMeter = horizontalDistance;
      } else {
        distanceMeter = sqrt(
          pow(horizontalDistance,2) + pow(currentPosition.altitude - _lastPosition!.altitude, 2)
        );
      }

      // update session and screen
      _session = _session!.copyWith(
        totalDistance: _session!.totalDistance + (distanceMeter / 1000.0),
        elevationGain: _session!.elevationGain + max(0.0, currentPosition.altitude - _lastPosition!.altitude),
        maxAltitude: max(_session!.maxAltitude, currentPosition.altitude),
        minAltitude: min(_session!.minAltitude, currentPosition.altitude)
      );
      _recordingSessionController.add(recordingSession!);
    }

    // update _lastPosition
    _lastPosition = currentPosition;
  }

  // stop recording
  // 戻り値: null=最終ポイントの取得を試みなかった、true=取得できた、false=取得を試みたが失敗した
  Future<bool?> stopRecording({bool skipFinalPositionFetch = false}) async {
    if (!isRecording) return null;
    _setPhase(RecordingPhase.stopping);

    // end session
    final now = DateTime.now();
    _session = _session!.copyWith(endedAt: now);

    // record final point (位置情報が失われた状態からの強制停止時は取得を試みない)
    bool? finalPointFetched;
    if (!skipFinalPositionFetch && _session!.elapsedSeconds % 5 != 0) {
      try {
        final currentPosition = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 1)
          )
        );
        _currentPositionController.add(currentPosition);
        _lastPosition = currentPosition;

        await _repo.addTrackPoint(
          sessionId: _session!.sessionId,
          latitude: currentPosition.latitude,
          longitude: currentPosition.longitude,
          altitude: currentPosition.altitude,
          recordedAt: now
        );
        finalPointFetched = true;
      } catch (_) {
        // 終了地点の位置情報が取得できなくても、それまでの記録を失わないよう
        // 最終ポイントの追加だけをスキップしてそのまま停止処理を続ける
        finalPointFetched = false;
      }
    }

    // stop the timer
    _timer?.cancel();
    _timer = null;

    // stop recording
    return finalPointFetched;
  }

  // complete session by save/discard
  Future<void> completeSession({
    required bool doSave,
    String? sessionName,
    MoveMethod? moveMethod
  }) async {
    final session = _session;
    if (session == null) return;

    // 保存/破棄の反映(repository側でリモート同期の完了まで待つため、通信状況次第で時間がかかる)を
    // 待たずに、先に次の状態へ遷移する。反映待ちの間もstoppingのままだと、収録タブのボタン/バナーから
    // 確定済みのセッションの保存/破棄画面を再度開けてしまうため。
    // (反映前にアプリが落ちてもinProgressのまま残るだけなので、次回起動時のリカバリで拾える)
    if (_recoveryQueue.isNotEmpty) {
      // 起動時リカバリのキューに続きがあれば、idleへ戻さずそのまま次の1件をstoppingとして提示する
      // (保存/破棄画面が開いていれば、ここで同期的に次のセッションの画面へ差し替わる)
      _dequeueNextRecovery();
    } else {
      // reset recording states
      _session = null;
      _pendingCompletionInfoMessage = null;
      _setPhase(RecordingPhase.idle);
      _recordingSessionController.add(recordingSession);
    }

    if (doSave) {
      // save
      await _repo.saveCompletedSession(
        session: session,
        name: sessionName!,
        moveMethod: moveMethod!,
        savedAt: DateTime.now(),
      );
    } else {
      await _repo.deleteRecordingSession(session: session);
    }
  }

  // for later update of session info
  Future<void> toggleFavorite(Session session) async {
    await _repo.toggleFavorite(session);
  }

  // 保存済みセッション一覧からの削除
  Future<void> deleteSession(Session session) async {
    await _repo.deleteSession(session);
  }

  // 保存済みセッション一覧からの名前・移動手段の編集
  Future<void> updateSessionInfo({
    required Session session,
    required String sessionName,
    required MoveMethod moveMethod,
  }) async {
    await _repo.updateSessionInfo(
      session: session,
      sessionName: sessionName,
      moveMethod: moveMethod,
    );
  }

  void dispose() {
    _disposed = true;
    _positionStreamSubscription?.cancel();
    _timer?.cancel();
    _bannerWatchdogTimer?.cancel();
    _recordingPhaseController.close();
    _currentPositionController.close();
    _recordingSessionController.close();
    _locationBannerController.close();
  }
}
