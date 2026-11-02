import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
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

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async => _position();

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    streamSettings.add(locationSettings);
    final controller = StreamController<Position>();
    _controllers.add(controller);
    return controller.stream;
  }
}

// 収録開始時に使うDB書き込みだけを実装する(それ以外が呼ばれたらテスト失敗にする)
class _FakeTrackingRepository implements TrackingRepository {
  @override
  Future<int> initSession({required RecordingSession session}) async => 1;

  @override
  Future<int> addTrackPoint({
    required String sessionId,
    required double latitude,
    required double longitude,
    required double altitude,
    required DateTime recordedAt,
  }) async => 1;

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

  TrackingService createService() {
    final service = TrackingService(
      _FakeTrackingRepository(),
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
}
