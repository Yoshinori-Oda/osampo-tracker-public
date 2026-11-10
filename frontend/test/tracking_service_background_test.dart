import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:test_tracking_01/models/move_method.dart';
import 'package:test_tracking_01/models/recording_phase.dart';
import 'package:test_tracking_01/models/recording_session.dart';
import 'package:test_tracking_01/repositories/tracking_repository.dart';
import 'package:test_tracking_01/services/location_stream_settings.dart';
import 'package:test_tracking_01/services/tracking_service.dart';

Position _position() => Position(
  latitude: 35.0,
  longitude: 139.0,
  timestamp: DateTime.now(),
  accuracy: 5,
  altitude: 10,
  altitudeAccuracy: 1,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

// 権限は常に「使用中のみ許可」、位置情報は即座に返す。購読ごとの設定と購読状態を記録する
class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  final List<LocationSettings?> streamSettings = [];
  final List<StreamController<Position>> _controllers = [];

  int get activeSubscriptionCount => _controllers.where((c) => c.hasListener).length;
  LocationSettings? get lastSettings => streamSettings.last;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async => LocationPermission.whileInUse;

  @override
  Future<LocationPermission> requestPermission() async => LocationPermission.whileInUse;

  // getCurrentPositionが呼ばれた回数
  int currentPositionRequests = 0;
  // 設定すると、次の1回のgetCurrentPositionはこのCompleterの完了まで返らない(timeLimitを過ぎたらTimeoutException)
  Completer<Position>? nextCurrentPosition;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    currentPositionRequests++;
    final pending = nextCurrentPosition;
    if (pending != null) {
      nextCurrentPosition = null;
      final timeLimit = locationSettings?.timeLimit;
      return timeLimit == null ? pending.future : pending.future.timeout(timeLimit);
    }
    return Future.value(_position());
  }

  // 購読中のストリームに位置を流す
  void emit(Position position) {
    for (final controller in _controllers.where((c) => c.hasListener)) {
      controller.add(position);
    }
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    streamSettings.add(locationSettings);
    final controller = StreamController<Position>();
    _controllers.add(controller);
    return controller.stream;
  }
}

// 収録の開始・停止・保存/破棄で使うDB書き込みだけを実装する(それ以外が呼ばれたらテスト失敗にする)
class _FakeTrackingRepository implements TrackingRepository {
  // 呼ばれた書き込みの順序
  final List<String> calls = [];

  @override
  Future<int> initSession({required RecordingSession session}) async => 1;

  @override
  Future<int> addTrackPoint({
    required String sessionId,
    required double latitude,
    required double longitude,
    required double altitude,
    required DateTime recordedAt,
  }) async {
    calls.add('addTrackPoint');
    return 1;
  }

  @override
  Future<void> saveCompletedSession({
    required RecordingSession session,
    required String name,
    required MoveMethod moveMethod,
    required DateTime savedAt,
  }) async {
    calls.add('save');
  }

  @override
  Future<void> deleteRecordingSession({required RecordingSession session}) async {
    calls.add('delete');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
    throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

bool _isBackgroundSettings(LocationSettings? settings) =>
  settings is AndroidSettings && settings.foregroundNotificationConfig != null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GeolocatorPlatform originalPlatform;
  late _FakeGeolocatorPlatform geolocator;

  setUp(() {
    originalPlatform = GeolocatorPlatform.instance;
    geolocator = _FakeGeolocatorPlatform();
    GeolocatorPlatform.instance = geolocator;
  });

  tearDown(() {
    GeolocatorPlatform.instance = originalPlatform;
  });

  TrackingService createService([_FakeTrackingRepository? repo]) {
    final service = TrackingService(
      repo ?? _FakeTrackingRepository(),
      getCurrentTabIndex: () => 0,
      switchToRecordingTab: () {},
    );
    addTearDown(service.dispose);
    return service;
  }

  // 起動時の初期化(権限要求〜初回購読)の完了を待ち、さらにフェーズ/ライフサイクル変化の後ろに
  // 非同期で積まれる購読の同期処理が落ち着くまで待つ
  Future<void> settle(TrackingService service) async {
    await service.initialization;
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      await service.positionStreamSynced;
    }
  }

  group('非収録中', () {
    test('起動時はフォアグラウンド専用の設定で購読する', () async {
      final service = createService();
      await settle(service);

      expect(geolocator.activeSubscriptionCount, 1);
      expect(_isBackgroundSettings(geolocator.lastSettings), isFalse);
    });

    test('バックグラウンドに回ると購読を止め、復帰すると再開する', () async {
      final service = createService();
      await settle(service);

      await service.handleAppLifecycleState(AppLifecycleState.hidden);
      await service.handleAppLifecycleState(AppLifecycleState.paused);
      await settle(service);
      expect(geolocator.activeSubscriptionCount, 0);

      await service.handleAppLifecycleState(AppLifecycleState.resumed);
      await settle(service);
      expect(geolocator.activeSubscriptionCount, 1);
      expect(geolocator.streamSettings, hasLength(2));
      expect(_isBackgroundSettings(geolocator.lastSettings), isFalse);
    });

    test('inactive(権限ダイアログ表示中など)では購読を止めない', () async {
      final service = createService();
      await settle(service);

      await service.handleAppLifecycleState(AppLifecycleState.inactive);
      await settle(service);

      expect(geolocator.activeSubscriptionCount, 1);
      expect(geolocator.streamSettings, hasLength(1));
    });
  });

  group('収録中', () {
    test('収録開始でバックグラウンド継続用の設定に切り替わる', () async {
      final service = createService();
      await settle(service);

      await service.startRecording();
      await settle(service);

      expect(service.phase, RecordingPhase.recording);
      expect(geolocator.activeSubscriptionCount, 1);
      expect(_isBackgroundSettings(geolocator.lastSettings), isTrue);
    });

    test('バックグラウンドに回っても購読を維持し、停止するとフォアグラウンド専用に戻る', () async {
      final service = createService();
      await settle(service);
      await service.startRecording();
      await settle(service);
      final subscribeCountWhileRecording = geolocator.streamSettings.length;

      await service.handleAppLifecycleState(AppLifecycleState.paused);
      await settle(service);
      expect(geolocator.activeSubscriptionCount, 1);

      await service.handleAppLifecycleState(AppLifecycleState.resumed);
      await settle(service);
      expect(geolocator.streamSettings, hasLength(subscribeCountWhileRecording));

      await service.stopRecording();
      await settle(service);
      expect(service.phase, RecordingPhase.stopping);
      expect(geolocator.activeSubscriptionCount, 1);
      expect(_isBackgroundSettings(geolocator.lastSettings), isFalse);
    });

    test('バックグラウンド中に停止した場合は購読を止め、復帰時にフォアグラウンド専用で再開する', () async {
      final service = createService();
      await settle(service);
      await service.startRecording();
      await settle(service);

      await service.handleAppLifecycleState(AppLifecycleState.paused);
      await service.stopRecording(skipFinalPositionFetch: true);
      await settle(service);
      expect(geolocator.activeSubscriptionCount, 0);

      await service.handleAppLifecycleState(AppLifecycleState.resumed);
      await settle(service);
      expect(geolocator.activeSubscriptionCount, 1);
      expect(_isBackgroundSettings(geolocator.lastSettings), isFalse);
    });
  });

  group('buildPositionStreamSettings', () {
    test('Android: 収録中のみForeground Serviceの通知設定を付ける', () {
      final background = buildPositionStreamSettings(background: true, platform: TargetPlatform.android);
      final foreground = buildPositionStreamSettings(background: false, platform: TargetPlatform.android);

      expect(background, isA<AndroidSettings>());
      expect((background as AndroidSettings).foregroundNotificationConfig, isNotNull);
      expect((foreground as AndroidSettings).foregroundNotificationConfig, isNull);
    });

    test('iOS: 収録中のみバックグラウンド更新を許可し、自動一時停止は常に無効', () {
      final background = buildPositionStreamSettings(background: true, platform: TargetPlatform.iOS);
      final foreground = buildPositionStreamSettings(background: false, platform: TargetPlatform.iOS);

      expect(background, isA<AppleSettings>());
      expect((background as AppleSettings).allowBackgroundLocationUpdates, isTrue);
      expect(background.pauseLocationUpdatesAutomatically, isFalse);
      expect((foreground as AppleSettings).allowBackgroundLocationUpdates, isFalse);
      expect(foreground.pauseLocationUpdatesAutomatically, isFalse);
    });
  });

  group('収録停止時の終了地点', () {
    late _FakeTrackingRepository repo;
    late TrackingService service;
    // 停止で購読を切り替えたときの初期位置の取得(getCurrentPosition)。手元で完了させる
    late Completer<Position> initialPosition;

    // 収録を開始し、終了地点の取得の対象になるよう経過秒数を5の倍数からずらしてから、
    // 停止後の初期位置の取得を手元で完了させるように準備する
    Future<void> startAndRecordBriefly() async {
      repo = _FakeTrackingRepository();
      service = createService(repo);
      await settle(service);
      await service.startRecording();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      repo.calls.clear();
      initialPosition = Completer<Position>();
      geolocator.nextCurrentPosition = initialPosition;
    }

    Future<void> flush() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('終了地点のためにgetCurrentPositionを別に呼ばず、停止後に受信した位置を追加する', () async {
      await startAndRecordBriefly();
      final requestsBeforeStop = geolocator.currentPositionRequests;

      await service.stopRecording();
      await flush();
      expect(service.phase, RecordingPhase.stopping);
      expect(repo.calls, isEmpty);

      initialPosition.complete(_position());
      await flush();
      expect(repo.calls, ['addTrackPoint']);
      // 呼んだのは購読の切り替えの初期位置の1回だけ(重なると先の呼び出しが完了しなくなるため)
      expect(geolocator.currentPositionRequests, requestsBeforeStop + 1);
    });

    test('初期位置が取れなくても、ストリームから受信した位置を追加する', () async {
      await startAndRecordBriefly();

      await service.stopRecording();
      initialPosition.completeError(TimeoutException('initial position'));
      await settle(service);
      expect(repo.calls, isEmpty);

      geolocator.emit(_position());
      await flush();
      expect(repo.calls, ['addTrackPoint']);
    });

    test('終了地点の取得中は、経過時間もトラックポイントも増えない', () async {
      await startAndRecordBriefly();

      await service.stopRecording();
      final elapsedSeconds = service.recordingSession!.elapsedSeconds;
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(service.recordingSession!.elapsedSeconds, elapsedSeconds);
      expect(repo.calls, isEmpty);
    });

    test('保存は、画面の状態はすぐに戻し、DBへは終了地点の追加を待ってから反映する', () async {
      await startAndRecordBriefly();
      await service.stopRecording();

      final completion = service.completeSession(doSave: true, sessionName: 'test', moveMethod: MoveMethod.walk);
      await flush();
      expect(service.phase, RecordingPhase.idle);
      expect(repo.calls, isEmpty);

      initialPosition.complete(_position());
      await completion;
      expect(repo.calls, ['addTrackPoint', 'save']);
    });

    test('破棄は、終了地点の追加を待ってから削除する', () async {
      await startAndRecordBriefly();
      await service.stopRecording();

      final completion = service.completeSession(doSave: false);
      await flush();
      expect(repo.calls, isEmpty);

      initialPosition.complete(_position());
      await completion;
      expect(repo.calls, ['addTrackPoint', 'delete']);
    });

    test('時間内に位置を受信できなかった場合は、追加せずに保存する', () async {
      await startAndRecordBriefly();
      await service.stopRecording();

      final completion = service.completeSession(doSave: true, sessionName: 'test', moveMethod: MoveMethod.walk);
      initialPosition.completeError(TimeoutException('initial position'));
      // 終了地点を待つ時間(5秒)を過ぎるまで待つ
      await completion;
      expect(repo.calls, ['save']);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
