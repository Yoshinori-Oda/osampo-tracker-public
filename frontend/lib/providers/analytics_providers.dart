// ignore_for_file: empty_constructor_bodies

import 'dart:math';
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../models/move_method.dart';
import 'tracking_providers.dart';
import 'auth_providers.dart';

// enums for analytics page state
enum AnalyticsPeriod { month, year, all }
enum MetricType { distance, duration }

// util for datetime manipulation
extension DateTimeAnalyticsExtension on DateTime {
  bool isSameDay(DateTime other) => year == other.year && month == other.month && day == other.day;
}

// selection state
class AnalyticsSelectionState {
  final AnalyticsPeriod period;
  final DateTime targetDate;
  final MetricType metricType;

  AnalyticsSelectionState({
    required this.period,
    required this.targetDate,
    required this.metricType
  });

  AnalyticsSelectionState copyWith({
    AnalyticsPeriod? period,
    DateTime? targetDate,
    MetricType? metricType,
  }) {
    return AnalyticsSelectionState(
      period: period ?? this.period,
      targetDate: targetDate ?? this.targetDate,
      metricType: metricType ?? this.metricType,
    );
  }
}

// selection notifier
class AnalyticsSelectionNotifier extends Notifier<AnalyticsSelectionState> {
  @override
  AnalyticsSelectionState build() {
    return AnalyticsSelectionState(
      period: AnalyticsPeriod.month,
      targetDate: DateTime.now(),
      metricType: MetricType.distance
    );
  }
  
  void setPeriod(AnalyticsPeriod period) => state = state.copyWith(period: period);
  void setMetricType(MetricType metricType) => state = state.copyWith(metricType: metricType);

  void previousPeriod() {
    final current = state.targetDate;
    final newDate = (state.period == AnalyticsPeriod.month)
      ? DateTime(current.year, current.month - 1, 1)
      : DateTime(current.year - 1, current.month , 1);
    state = state.copyWith(targetDate: newDate);
  }

  void nextPeriod() {
    final current = state.targetDate;
    final newDate = (state.period == AnalyticsPeriod.month)
      ? DateTime(current.year, current.month + 1, 1)
      : DateTime(current.year + 1, current.month, 1);
    state = state.copyWith(targetDate: newDate);
  }
}

// selection provider
final analyticsSelectionProvider = 
    NotifierProvider<AnalyticsSelectionNotifier, AnalyticsSelectionState>(
  AnalyticsSelectionNotifier.new
);

// data models for UI
class ChartBarDataPoint {
  final DateTime date;
  final double value;
  final String label;
  final int count;

  ChartBarDataPoint({
    required this.date,
    required this.value,
    required this.label,
    required this.count
  });
}

class AnalyticsSummaryData {
  final List<ChartBarDataPoint> chartPoints;
  // summary items
  final double totalDistance;
  final int totalDurationSeconds;
  final int totalSessionCounts;
  final double totalActiveDistance;
  
  // personal records
  final double maxDistance;
  final int maxDurationSeconds;
  final double maxElevationGain;
  final double? maxAltitude;
  final double? minAltitude;

  AnalyticsSummaryData({
    required this.chartPoints,
    required this.totalDistance,
    required this.totalDurationSeconds,
    required this.totalSessionCounts,
    required this.totalActiveDistance,
    required this.maxDistance,
    required this.maxDurationSeconds,
    required this.maxElevationGain,
    this.maxAltitude,
    this.minAltitude
  });
}

// aggregate data and calculate
final analyticsDataProvider = StreamProvider<AnalyticsSummaryData>((ref) async* {
  final db = ref.watch(databaseProvider);
  final selection = ref.watch(analyticsSelectionProvider);
  final userId = ref.watch(currentUserIdProvider) ?? '';

  // ログイン中のユーザーのデータだけを集計する
  final completedSessionsQuery = db.select(db.sessions)
    ..where((tbl) => tbl.userId.equals(userId) & tbl.endedAt.isNotNull());
  
  await for (final completedSessions in completedSessionsQuery.watch()) {
    if (completedSessions.isEmpty) {
      yield AnalyticsSummaryData(
        chartPoints: [],
        totalDistance: 0.0,
        totalDurationSeconds: 0,
        totalSessionCounts: 0,
        totalActiveDistance: 0.0,
        maxDistance: 0.0,
        maxDurationSeconds: 0,
        maxElevationGain: 0.0,
        maxAltitude: null,
        minAltitude: null
      );
      continue;
    }

    // filtering by period
    List<Session> filteredSessions = [];

    if (selection.period == AnalyticsPeriod.month) {
      final startOfMonth = DateTime(selection.targetDate.year, selection.targetDate.month, 1);
      final endOfMonth = DateTime(selection.targetDate.year, selection.targetDate.month + 1, 0, 23, 59, 59);

      filteredSessions = completedSessions.where((s) {
        return s.startedAt.isAfter(startOfMonth.subtract(const Duration(seconds: 1))) &&
               s.startedAt.isBefore(endOfMonth.add(const Duration(seconds: 1)));
      }).toList();
    } else if (selection.period == AnalyticsPeriod.year) {
      final startOfYear = DateTime(selection.targetDate.year, 1, 1);
      final endOfYear = DateTime(selection.targetDate.year, 12, 31, 23, 59, 59);

      filteredSessions = completedSessions.where((s) {
        return s.startedAt.isAfter(startOfYear.subtract(const Duration(seconds: 1))) &&
               s.startedAt.isBefore(endOfYear.add(const Duration(seconds:1)));
      }).toList();
    } else {
      filteredSessions = List.from(completedSessions);
    }
    
    // period summary items and personal best records
    double totalDistance = 0.0;
    int totalDurationSeconds = 0;
    final totalSessionCounts = filteredSessions.length;
    double totalActiveDistance = 0.0;
    double maxDistance = 0.0;
    int maxDurationSeconds = 0;
    double maxElevationGain = 0.0;
    double? maxAltitude;
    double? minAltitude;

    for (final s in filteredSessions) {
      totalDistance += s.totalDistance;
      totalDurationSeconds += s.durationSeconds;
      if (s.moveMethod == MoveMethod.walk ||
          s.moveMethod == MoveMethod.run ||
          s.moveMethod == MoveMethod.bicycle
      ) {
        totalActiveDistance += s.totalDistance;
      }
      maxDistance = max(maxDistance, s.totalDistance);
      maxDurationSeconds = max(maxDurationSeconds, s.durationSeconds);
      maxElevationGain = max(maxElevationGain, s.elevationGain);
      maxAltitude = max(maxAltitude ?? s.maxAltitude!, s.maxAltitude!);
      minAltitude = min(minAltitude ?? s.minAltitude!, s.minAltitude!);
    }

    // generate data points for graph
    final List<ChartBarDataPoint> chartPoints = [];
    // period: month
    if (selection.period == AnalyticsPeriod.month) {
      final daysInMonth = DateTime(selection.targetDate.year, selection.targetDate.month + 1, 0).day;
      // extract completed sessions of each day
      for (int day = 1; day <= daysInMonth; day++) {
        final currentDate = DateTime(selection.targetDate.year, selection.targetDate.month, day);
        final daySessions = filteredSessions.where((s) =>
            s.startedAt.year == currentDate.year &&
            s.startedAt.month == currentDate.month &&
            s.startedAt.day == currentDate.day);
        // accumulate value
        double val = 0.0;
        for (final s in daySessions) {
          val += (selection.metricType == MetricType.distance) 
            ? s.totalDistance
            : (s.durationSeconds / 3600.0);
        }
        // add chartPoint to list
        chartPoints.add(ChartBarDataPoint(
          date: currentDate,
          value: val,
          label: '$day',
          count: daySessions.length
        ));
      }
    // period: year (same as month)
    } else if (selection.period == AnalyticsPeriod.year) {
      for (int month = 1; month <= 12; month++) {
        final currentDate = DateTime(selection.targetDate.year, month, 1);
        final monthSessions = filteredSessions.where((s) =>
          s.startedAt.year == currentDate.year &&
          s.startedAt.month == currentDate.month);
        
        double val = 0.0;
        for (final s in monthSessions) {
          val += (selection.metricType == MetricType.distance)
            ? s.totalDistance
            : (s.durationSeconds / 3600.0);
        }

        chartPoints.add(ChartBarDataPoint(
          date: currentDate,
          value: val,
          label: '$month月',
          count: monthSessions.length
        ));
      }
    // period: all
    } else {
      final sortedSessions = List<Session>.from(completedSessions)
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      int count = 0;
      
      double runningTotal = 0.0;
      for (final s in sortedSessions) {
        runningTotal += (selection.metricType == MetricType.distance)
          ? s.totalDistance
          : (s.durationSeconds / 3600.0);
        count++;

        chartPoints.add(ChartBarDataPoint(
          date: s.startedAt,
          value: runningTotal,
          label: '${s.startedAt.year}/${s.startedAt.month}/${s.startedAt.day}',
          count: count
        ));
      }
    }

    yield AnalyticsSummaryData(
      chartPoints: chartPoints,
      totalDistance: totalDistance,
      totalDurationSeconds: totalDurationSeconds,
      totalSessionCounts: totalSessionCounts,
      totalActiveDistance: totalActiveDistance,
      maxDistance: maxDistance,
      maxDurationSeconds: maxDurationSeconds,
      maxElevationGain: maxElevationGain,
      maxAltitude: maxAltitude,
      minAltitude: minAltitude,
    );
  }
});
