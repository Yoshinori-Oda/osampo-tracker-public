import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../database/app_database.dart';
import '../repositories/tracking_repository.dart';
import '../services/tracking_service.dart';
import '../models/recording_session.dart';
import '../models/location_banner.dart';
import '../models/recording_phase.dart';
import '../utils/delete_conflict_dialog.dart';
import 'auth_providers.dart';

// DB provider
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

// repository provider。ログイン中のユーザーごとに作る(ログイン画面の間は読まれない)
final repositoryProvider = Provider<TrackingRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) throw StateError('ログインしていない間はTrackingRepositoryを使えません');
  final repo = TrackingRepository(
    db,
    userId,
    client: ref.watch(authorizedClientProvider),
    onDeleteConflict: showDeleteConflictDialog,
    canSync: () => ref.read(authControllerProvider).value?.canSync ?? false,
  );
  ref.onDispose(() => repo.dispose());
  return repo;
});

// 現在表示中のボトムナビゲーションタブ(収録タブ=0)
class BottomNavIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setIndex(int index) => state = index;
}

final bottomNavIndexProvider = NotifierProvider<BottomNavIndexNotifier, int>(BottomNavIndexNotifier.new);

// service provider
final trackingServiceProvider = Provider<TrackingService>((ref) {
  final repo = ref.watch(repositoryProvider);
  final service = TrackingService(
    repo,
    getCurrentTabIndex: () => ref.read(bottomNavIndexProvider),
    switchToRecordingTab: () => ref.read(bottomNavIndexProvider.notifier).setIndex(0),
  );
  ref.onDispose(() => service.dispose());
  return service;
});

// stream providers
final currentPositionProvider = StreamProvider<Position>((ref) {
  final service = ref.watch(trackingServiceProvider);
  return service.currentPositionStream;
});

final recordingPhaseProvider = StreamProvider<RecordingPhase>((ref) {
  final service = ref.watch(trackingServiceProvider);
  return service.recordingPhaseStream;
});

final recordingSessionProvider = StreamProvider<RecordingSession?>((ref) {
  final service = ref.watch(trackingServiceProvider);
  return service.recordingSessionStream;
});

// 全タブ共通で表示する位置情報の不具合バナー
final locationBannerProvider = StreamProvider<LocationBannerState>((ref) {
  final service = ref.watch(trackingServiceProvider);
  return service.locationBannerStream;
});

// for sessions list view
final sessionsStreamProvider = StreamProvider<List<Session>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const []);
  return db.watchAllSessions(userId: userId);
});

// for ended session detail view
final sessionByIdProvider = StreamProvider.family<Session, String>((ref, sessionId) {
  final db = ref.watch(databaseProvider);
  return db.getSessionById(sessionId);
});

final trackPointsBySessionIdProvider = FutureProvider.family<List<TrackPoint>, String>((ref, sessionId) {
  final db = ref.watch(databaseProvider);
  return db.getTrackPointsForSession(sessionId);
});

// for recording view
enum RecordingPageMode { statistics, map }
enum MapTopMode { direction, heading }

class MapModeState {
  final RecordingPageMode pageMode;
  final MapTopMode topMode;
  final Position? position;

  MapModeState({
    required this.pageMode,
    required this.topMode,
    this.position
  });

  MapModeState copyWith({
    RecordingPageMode? pageMode,
    MapTopMode? topMode,
    Position? position
  }) {
    return MapModeState(
      pageMode: pageMode ?? this.pageMode,
      topMode: topMode ?? this.topMode,
      position: position ?? this.position
    );
  }
}

class MapModeNotifier extends Notifier<MapModeState> {
  @override
  MapModeState build() {
    ref.listen<AsyncValue<Position>>(currentPositionProvider, (previous, next) {
      final newPosition = next.value;
      if (newPosition != null) {
        state = state.copyWith(position: newPosition);
      }
    });

    return MapModeState(
      pageMode: RecordingPageMode.statistics,
      topMode: MapTopMode.direction,
      position: null
    );
  }

  void toggleTopMode() {
    final nextTopMode = (state.topMode == MapTopMode.heading)
      ? MapTopMode.direction
      : MapTopMode.heading;
    state = state.copyWith(topMode: nextTopMode);
  }

  void setRecordingPageMode(RecordingPageMode mode) => state = state.copyWith(pageMode: mode);
}
final mapModeProvider = NotifierProvider<MapModeNotifier, MapModeState>(MapModeNotifier.new);

final totalDistanceProvider = Provider<String>((ref) {
  double? totalDistance = ref.watch(recordingSessionProvider).value?.totalDistance;
  return '${totalDistance?.toStringAsFixed(1) ?? "---"} km';
});

final elapsedTimeProvider = Provider<String>((ref) {
  int? elapsedSeconds = ref.watch(recordingSessionProvider).value?.elapsedSeconds;
  if (elapsedSeconds == null) return '--時間--分--秒';

  final hours = elapsedSeconds ~/ 3600;
  final minutes = (elapsedSeconds % 3600) ~/ 60;
  final seconds = elapsedSeconds % 60;

  return '$hours時間$minutes分$seconds秒';
});

final currentSpeedProvider = Provider<String>((ref) {
  double? currentSpeedMS = ref.watch(currentPositionProvider).value?.speed;
  if (currentSpeedMS == null || currentSpeedMS < 0) return '--- km/h';
  final currentSpeedKmH = currentSpeedMS * 3.6;
  return '${currentSpeedKmH.toStringAsFixed(1)} km/h';
});

final averageSpeedProvider = Provider<String>((ref) {
  double? avgSpeed = ref.watch(recordingSessionProvider).value?.avgSpeed;
  return '${avgSpeed?.toStringAsFixed(1) ?? "---"} km/h';
});

final altitudeProvider = Provider<String>((ref) {
  double? altitude = ref.watch(currentPositionProvider).value?.altitude;
  return '${altitude?.toStringAsFixed(1) ?? "---"} m';
});

final elevationGainProvider = Provider<String>((ref) {
  double? elevationGain = ref.watch(recordingSessionProvider).value?.elevationGain;
  return '${elevationGain?.toStringAsFixed(1) ?? "---"} m';
});

final maxAltitudeProvider = Provider<String>((ref) {
  double? maxAltitude = ref.watch(recordingSessionProvider).value?.maxAltitude;
  return '${maxAltitude?.toStringAsFixed(1) ?? "---"} m';
});

final minAltitudeProvider = Provider<String>((ref) {
  double? minAltitude = ref.watch(recordingSessionProvider).value?.minAltitude;
  return '${minAltitude?.toStringAsFixed(1) ?? "---"} m';
});
