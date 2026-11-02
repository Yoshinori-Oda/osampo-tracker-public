import 'package:fl_chart/fl_chart.dart';

import '../database/app_database.dart';

// 高度プロファイルグラフ(セッション詳細画面)用のデータ変換。
// X軸はポイントの順番ではなくrecordedAtの時間軸にする。X値は「高度を持つ最初のポイントからの
// 経過分」(double)で持ち、軸ラベル表示時にoriginへ足し戻して時刻に変換する。
// 収録間隔が不均一でも、時間の流れどおりの横位置で描画される。
class ElevationChartData {
  // X=0に対応する時刻
  final DateTime origin;
  final List<FlSpot> spots;

  const ElevationChartData({required this.origin, required this.spots});

  double get maxX => spots.last.x;

  // X値(経過分)を時刻に戻す
  DateTime timeAt(double x) => origin.add(
        Duration(milliseconds: (x * Duration.millisecondsPerMinute).round()),
      );

  // 高度を持たないポイントは除外する。残りが2点未満、または全点が同時刻(X軸の幅が0)なら
  // null(グラフを描けない)。
  static ElevationChartData? fromTrackPoints(List<TrackPoint> trackPoints) {
    final points = trackPoints.where((p) => p.altitude != null).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    if (points.length < 2) return null;

    final origin = points.first.recordedAt;
    if (!points.last.recordedAt.isAfter(origin)) return null;
    final spots = points.map((p) {
      final elapsedMs = p.recordedAt.difference(origin).inMilliseconds;
      return FlSpot(elapsedMs / Duration.millisecondsPerMinute, p.altitude!);
    }).toList();

    return ElevationChartData(origin: origin, spots: spots);
  }
}

// X軸ラベルの間隔(分)。ラベル数がmaxLabels以下に収まる最小の「きりの良い」間隔を選ぶ。
double elevationChartTimeInterval(double totalMinutes, {int maxLabels = 5}) {
  const candidates = [1, 2, 5, 10, 15, 30, 60, 120, 180, 360, 720, 1440];
  for (final c in candidates) {
    if (totalMinutes / c <= maxLabels) return c.toDouble();
  }
  // 数日に跨る長時間セッション: 日単位で切り上げる
  return (totalMinutes / maxLabels / 1440).ceil() * 1440.0;
}

// X軸ラベル用の時刻表示("HH:mm")
String formatChartTimeLabel(DateTime time) {
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}
