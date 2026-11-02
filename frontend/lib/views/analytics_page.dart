import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:holiday_jp/holiday_jp.dart' as holiday_jp;
import '../providers/analytics_providers.dart';

class AnalyticsPage extends ConsumerWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch / read providers
    final selection = ref.watch(analyticsSelectionProvider);
    final notifier = ref.read(analyticsSelectionProvider.notifier);
    final analyticsAsync = ref.watch(analyticsDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('統計・分析'),
        centerTitle: true
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // period tab
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<AnalyticsPeriod>(
                    segments: const [
                      ButtonSegment(value: AnalyticsPeriod.month, label: Text('月')),
                      ButtonSegment(value: AnalyticsPeriod.year, label: Text('年')),
                      ButtonSegment(value: AnalyticsPeriod.all, label: Text('全期間'))
                    ],
                    selected: {selection.period},
                    onSelectionChanged: (Set<AnalyticsPeriod> newSelection) {
                      notifier.setPeriod(newSelection.first);
                    }
                  )
                )
              ]
            ),

            const SizedBox(height: 12),

            // date navigation (for month and year view)
            if (selection.period !=  AnalyticsPeriod.all)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => notifier.previousPeriod()
                  ),
                  Text(
                    selection.period == AnalyticsPeriod.month
                      ? '${selection.targetDate.year}年 ${selection.targetDate.month}月'
                      : '${selection.targetDate.year}年',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => notifier.nextPeriod()
                  )
                ]
              ),

              const SizedBox(height: 16),

              // async data handling
              analyticsAsync.when(
                loading: () => const SizedBox(
                  height: 200,
                  child:Center(child: CircularProgressIndicator())
                ),
                error: (err, stack) =>Center(child: Text('エラーが発生しました: $err')),
                data: (data) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // graph mode selection tab
                    _buildGraphHeader(ref, selection, notifier),
                    const SizedBox(height: 12),
                    selection.period == AnalyticsPeriod.all
                      ? _buildCumulativeLineChart(data.chartPoints, selection.metricType)
                      : _buildBarChart(data.chartPoints, selection.metricType, selection.period),
                    const SizedBox(height: 24),

                    // main summary
                    const Text('サマリー', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildSummaryGrid(data),
                    const SizedBox(height: 24),

                    // personal records
                    const Text('自己ベスト', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildPersonalRecordCard(data)
                  ]
                )
              )
          ]
        )
      )
    );
  }
}

// helper components

// graph header
Widget _buildGraphHeader(
  WidgetRef ref,
  AnalyticsSelectionState selection,
  AnalyticsSelectionNotifier notifier
) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(
        selection.metricType == MetricType.distance 
          ? selection.period == AnalyticsPeriod.all ? '累計移動距離 [km]' : '移動距離 [km]'
          : selection.period == AnalyticsPeriod.all ? '累計移動時間 [h]' : '移動時間 [h]',
        style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.bold)
      ),
      ToggleButtons(
        isSelected: [
          selection.metricType == MetricType.distance,
          selection.metricType == MetricType.duration
        ],
        onPressed: (index) {
          notifier.setMetricType(index == 0 ? MetricType.distance : MetricType.duration);
        },
        constraints: const BoxConstraints(minHeight: 32, minWidth: 50),
        children: const [
          Text('距離', style: TextStyle(fontSize: 12)),
          Text('時間', style: TextStyle(fontSize: 12))
        ]
      )
    ]
  );
}

// graph
Widget _buildBarChart(List<ChartBarDataPoint> points, MetricType metricType, AnalyticsPeriod period) {
  if (points.isEmpty) {
    return const Card(
      child: SizedBox(height: 120, child: Center(child: Text('データがありません'))),
    );
  }

  final maxValue = points.map((p) => p.value).fold(0.0, (max, v) => v > max ? v : max);

  return Card(
    elevation: 1.5,
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        key: const PageStorageKey('analytics_bar_chart_scroll'),
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: points.map((point) {
            final ratio = (maxValue > 0) ? (point.value / maxValue) : 0.0;
            Color labelColor = Colors.grey.shade700;
            Color barColor = point.value > 0 ? Colors.blueAccent : Colors.grey.shade200;
            if (period == AnalyticsPeriod.month) {
              final isSunday = point.date.weekday == DateTime.sunday;
              final isSaturday = point.date.weekday == DateTime.saturday;
              final isHoliday = holiday_jp.isHoliday(point.date);
              if (isSunday || isHoliday) {
                labelColor = Colors.red;
                if (point.value > 0) barColor = Colors.redAccent;
              } else if (isSaturday) {
                labelColor = Colors.blue;
                if (point.value > 0) barColor = Colors.blue;
              }
            }

            final itemWidth = (period == AnalyticsPeriod.month) ? 28.0 : 40.0;

            return SizedBox(
              width: itemWidth, child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    width: 12,
                    height: max(2.0, 80 * ratio),
                    decoration: BoxDecoration(
                      color:barColor,
                      borderRadius: BorderRadius.circular(3)
                    )
                  ),
                  const SizedBox(height: 6),
                  Text(
                    point.label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: (labelColor != Colors.grey.shade700)
                        ? FontWeight.bold
                        : FontWeight.normal,
                      color: labelColor
                    ),
                    textAlign: TextAlign.center
                  )
                ]
              )
            );
          }).toList()
        )
      )
    )
  );
}

// cumulative line chart (for all period)
// chartPoints holds one running total per completed session (sorted by startedAt),
// so x = session index and y = cumulative value.
Widget _buildCumulativeLineChart(List<ChartBarDataPoint> points, MetricType metricType) {
  if (points.isEmpty) {
    return const Card(
      child: SizedBox(height: 120, child: Center(child: Text('データがありません'))),
    );
  }

  final spots = points.asMap().entries
    .map((entry) => FlSpot(entry.key.toDouble(), entry.value.value))
    .toList();
  final maxValue = points.last.value;
  final unit = metricType == MetricType.distance ? 'km' : 'h';
  // show about 4 date labels on the x axis regardless of the number of sessions
  final labelInterval = max(1, ((points.length - 1) / 3).ceil()).toDouble();

  return Card(
    elevation: 1.5,
    child: Padding(
      padding: const EdgeInsets.only(left: 8, right: 20, top: 16, bottom: 8),
      child: SizedBox(
        height: 180,
        child: LineChart(
          LineChartData(
            minX: 0,
            maxX: max(1, points.length - 1).toDouble(),
            minY: 0,
            maxY: maxValue > 0 ? maxValue * 1.1 : 1,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (value) => FlLine(
                color: Colors.grey.shade200,
                strokeWidth: 1
              )
            ),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 36,
                  interval: labelInterval,
                  getTitlesWidget: (value, meta) {
                    final index = value.toInt();
                    if (value != index || index < 0 || index >= points.length) {
                      return const SizedBox.shrink();
                    }
                    // split into year / month-day so that the label stays narrow enough
                    // to be centered on the tick without overflowing at the right edge
                    final date = points[index].date;
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        '${date.year}\n${date.month}/${date.day}',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 10, height: 1.2, color: Colors.grey.shade700)
                      )
                    );
                  }
                )
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (value, meta) {
                    if (value == meta.max) return const SizedBox.shrink();
                    return Text(
                      meta.formattedValue,
                      style: const TextStyle(fontSize: 10, color: Colors.grey)
                    );
                  }
                )
              )
            ),
            borderData: FlBorderData(show: false),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (touchedSpots) => touchedSpots.map((spot) {
                  final point = points[spot.x.toInt()];
                  return LineTooltipItem(
                    '${point.label}\n${point.value.toStringAsFixed(1)} $unit',
                    const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)
                  );
                }).toList()
              )
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                color: Colors.blueAccent,
                barWidth: 2.5,
                isStrokeCapRound: true,
                // dots are only useful while the number of sessions is small
                dotData: FlDotData(show: points.length <= 30),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.blueAccent.withValues(alpha: 0.15)
                )
              )
            ]
          )
        )
      )
    )
  );
}

// main summary
Widget _buildSummaryGrid(AnalyticsSummaryData data) {
  return GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    crossAxisSpacing: 12,
    mainAxisSpacing: 12,
    childAspectRatio: 1.5,
    children: [
      _buildMetricCard('総移動距離', '${data.totalDistance.toStringAsFixed(1)} km',Icons.route),
      _buildMetricCard('総移動時間', _formatDuration(data.totalDurationSeconds), Icons.timer),
      _buildMetricCard('セッション数', '${data.totalSessionCounts} 回', Icons.flag),
      _buildMetricCard('アクティブ距離', '${data.totalActiveDistance.toStringAsFixed(1)} km', Icons.directions_walk, Colors.orange)
    ]
  );
}

// metric card builder
Widget _buildMetricCard(String title, String value, IconData icon, [Color? color]) {
  return Card(
    elevation: 1.5,
    child: Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color ?? Colors.blue),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))
            ]
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5))
                )
              ]
            )
          )
        ]
      )
    )
  );
}

// personal best card builder
Widget _buildPersonalRecordCard(AnalyticsSummaryData data) {
  return Card(
    elevation: 1.5,
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          _buildRecordRow('最長移動距離', '${data.maxDistance.toStringAsFixed(1)} km'),
          const Divider(),
          _buildRecordRow('最長移動時間', _formatDuration(data.maxDurationSeconds)),
          const Divider(),
          _buildRecordRow('最高獲得標高', '${data.maxElevationGain.round()} m'),
          const Divider(),
          _buildRecordRow('最高到達標高', data.maxAltitude != null ? '${data.maxAltitude!.round()} m' : '--- m'),
          const Divider(),
          _buildRecordRow('最低到達標高', data.minAltitude != null ? '${data.minAltitude!.round()} m' : '--- m')
        ]
      )
    )
  );
}

Widget _buildRecordRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4.0),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 14)),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold))
      ]
    )
  );
}

// seconds to hours-minutes transformation
String _formatDuration(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours > 0) {
    return '$hours時間 $minutes分';
  }
  return '$minutes分';
}