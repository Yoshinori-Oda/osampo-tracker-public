import '../database/app_database.dart';
import '../models/status.dart';
import '../models/move_method.dart';

class RecordingSession {
  final String sessionId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double totalDistance;
  final int elapsedSeconds;
  final double elevationGain;
  final double maxAltitude;
  final double minAltitude;
  
  const RecordingSession({
    required this.sessionId,
    required this.startedAt,
    required this.endedAt,
    required this.totalDistance,
    required this.elapsedSeconds,
    required this.elevationGain,
    required this.maxAltitude,
    required this.minAltitude
  });
  
  double? get avgSpeed {
    if (elapsedSeconds < 5) return null;
    final hours = elapsedSeconds / 3600.0;
    return totalDistance / hours;
  }

  RecordingSession copyWith({
    String? sessionId,
    DateTime? startedAt,
    DateTime? endedAt,
    double? totalDistance,
    int? elapsedSeconds,
    double? elevationGain,
    double? maxAltitude,
    double? minAltitude
  }) {
    return RecordingSession(
      sessionId: sessionId ?? this.sessionId,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      totalDistance: totalDistance ?? this.totalDistance,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      elevationGain: elevationGain ?? this.elevationGain,
      maxAltitude: maxAltitude ?? this.maxAltitude,
      minAltitude: minAltitude ?? this.minAltitude
    );
  }

  Session recoridngSessionToSession({
    required RecordingSession recordingSession,
    required String userId,
    required String name,
    required DateTime endedAt,
    required MoveMethod moveMethod,
  }) {
    return Session(
      id: recordingSession.sessionId,
      userId: userId,
      name: name,
      startedAt: recordingSession.startedAt,
      endedAt: endedAt,
      status: Status.ended,
      isFavorite: false,
      updatedAt: DateTime.now(),
      moveMethod: moveMethod,
      totalDistance: recordingSession.totalDistance,
      durationSeconds: recordingSession.elapsedSeconds,
      elevationGain: recordingSession.elevationGain,
      maxAltitude: recordingSession.maxAltitude,
      minAltitude: recordingSession.minAltitude,
    );
  }
}