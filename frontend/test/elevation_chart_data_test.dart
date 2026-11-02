import 'package:flutter_test/flutter_test.dart';

import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/utils/elevation_chart_data.dart';

final _base = DateTime(2026, 9, 28, 9, 0, 0);

TrackPoint _tp(int id, Duration offset, double? altitude) => TrackPoint(
      id: id,
      sessionId: 's1',
      recordedAt: _base.add(offset),
      latitude: 35.0,
      longitude: 139.0,
      altitude: altitude,
    );

void main() {
  group('ElevationChartData.fromTrackPoints', () {
    test('X値はポイントの順番ではなくrecordedAtからの経過分になる', () {
      final data = ElevationChartData.fromTrackPoints([
        _tp(1, Duration.zero, 10),
        _tp(2, const Duration(seconds: 30), 12),
        // 間隔が不均一でも時間どおりの位置になる
        _tp(3, const Duration(minutes: 10), 20),
      ])!;

      expect(data.origin, _base);
      expect(data.spots.map((s) => s.x).toList(), [0, 0.5, 10]);
      expect(data.spots.map((s) => s.y).toList(), [10, 12, 20]);
      expect(data.maxX, 10);
    });

    test('高度nullのポイントは除外し、originは高度を持つ最初のポイントになる', () {
      final data = ElevationChartData.fromTrackPoints([
        _tp(1, Duration.zero, null),
        _tp(2, const Duration(minutes: 1), 10),
        _tp(3, const Duration(minutes: 2), null),
        _tp(4, const Duration(minutes: 3), 15),
      ])!;

      expect(data.origin, _base.add(const Duration(minutes: 1)));
      expect(data.spots.map((s) => s.x).toList(), [0, 2]);
    });

    test('入力がrecordedAt順でなくても時刻順に並べ替える', () {
      final data = ElevationChartData.fromTrackPoints([
        _tp(2, const Duration(minutes: 5), 20),
        _tp(1, Duration.zero, 10),
      ])!;

      expect(data.spots.map((s) => s.y).toList(), [10, 20]);
    });

    test('高度を持つポイントが2点未満ならnull', () {
      expect(ElevationChartData.fromTrackPoints([]), isNull);
      expect(
        ElevationChartData.fromTrackPoints([
          _tp(1, Duration.zero, 10),
          _tp(2, const Duration(minutes: 1), null),
        ]),
        isNull,
      );
    });

    test('全ポイントが同時刻ならnull(X軸の幅が0になるため)', () {
      expect(
        ElevationChartData.fromTrackPoints([
          _tp(1, Duration.zero, 10),
          _tp(2, Duration.zero, 12),
        ]),
        isNull,
      );
    });

    test('timeAtでX値を時刻に戻せる', () {
      final data = ElevationChartData.fromTrackPoints([
        _tp(1, Duration.zero, 10),
        _tp(2, const Duration(minutes: 90), 20),
      ])!;

      expect(data.timeAt(0), _base);
      expect(data.timeAt(90), DateTime(2026, 9, 28, 10, 30));
    });
  });

  group('elevationChartTimeInterval', () {
    test('ラベルが5個以内に収まる最小のきりの良い間隔を選ぶ', () {
      expect(elevationChartTimeInterval(3), 1);
      expect(elevationChartTimeInterval(5), 1);
      expect(elevationChartTimeInterval(6), 2);
      expect(elevationChartTimeInterval(45), 10);
      expect(elevationChartTimeInterval(90), 30);
      expect(elevationChartTimeInterval(240), 60);
      expect(elevationChartTimeInterval(1440 * 3), 1440);
    });
  });

  test('formatChartTimeLabelはHH:mmでゼロ埋めする', () {
    expect(formatChartTimeLabel(DateTime(2026, 9, 28, 7, 5)), '07:05');
    expect(formatChartTimeLabel(DateTime(2026, 9, 28, 23, 59, 59)), '23:59');
  });
}
