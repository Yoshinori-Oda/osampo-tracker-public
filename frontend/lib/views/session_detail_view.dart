import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../database/app_database.dart'; // Drift DBのモデルクラス
import '../providers/tracking_providers.dart'; // trackPointsBySessionIdProvider があるファイル
import '../utils/elevation_chart_data.dart';
import '../utils/map_tiles.dart';
import '../widgets/osm_attribution.dart';

/// セッション詳細画面
class SessionDetailView extends StatelessWidget {
  final Session session;

  const SessionDetailView({
    super.key,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: SessionDetailTitle(
          name: session.name ?? 'アクティビティ詳細',
          moveMethodLabel: session.moveMethod.label,
          startedAt: session.startedAt,
        ),
      ),
      body: SessionDetailBody(
        sessionId: session.id,
        totalDistance: session.totalDistance,
        durationSeconds: session.durationSeconds,
        elevationGain: session.elevationGain,
        maxAltitude: session.maxAltitude,
        minAltitude: session.minAltitude,
      ),
    );
  }
}

/// セッション詳細のAppBarタイトル(セッション名 + 移動手段・開始日時)。
/// 収録停止後の保存/破棄画面(save_or_discard_page.dart)でも、詳細画面と同じ見た目で使う。
/// moveMethodLabelがnull(未選択)の場合は開始日時だけを表示する
class SessionDetailTitle extends StatelessWidget {
  final String name;
  final String? moveMethodLabel;
  final DateTime startedAt;

  const SessionDetailTitle({
    super.key,
    required this.name,
    required this.moveMethodLabel,
    required this.startedAt,
  });

  @override
  Widget build(BuildContext context) {
    final startedAtString = startedAt.toString().substring(0, 16);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          moveMethodLabel != null
              ? '$moveMethodLabel ・ $startedAtString'
              : startedAtString,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}

/// セッション詳細の本文(マップ・統計グリッド・高度プロファイル)。
/// 保存済みの`Session`と収録停止直後の`RecordingSession`の両方から使えるよう、値で受け取る
class SessionDetailBody extends ConsumerStatefulWidget {
  final String sessionId;
  final double totalDistance;
  final int durationSeconds;
  final double elevationGain;
  final double? maxAltitude;
  final double? minAltitude;

  const SessionDetailBody({
    super.key,
    required this.sessionId,
    required this.totalDistance,
    required this.durationSeconds,
    required this.elevationGain,
    required this.maxAltitude,
    required this.minAltitude,
  });

  @override
  ConsumerState<SessionDetailBody> createState() => _SessionDetailBodyState();
}

class _SessionDetailBodyState extends ConsumerState<SessionDetailBody> {
  // マップの表示モード切り替え（false: スタート/ゴールのみ, true: 全トラックポイント）
  bool _showAllMarkers = false;

  @override
  Widget build(BuildContext context) {
    // 指定された sessionId に紐づくトラックポイントを取得
    final trackPointsAsync =
        ref.watch(trackPointsBySessionIdProvider(widget.sessionId));

    // 平均速度の計算 (km/h)
    final double? avgSpeed = (widget.durationSeconds >= 5 &&
            widget.totalDistance > 0)
        ? (widget.totalDistance /
            (widget.durationSeconds / 3600.0))
        : null;

    // 経過時間のフォーマット (HH:MM:SS)
    final hours = widget.durationSeconds ~/ 3600;
    final minutes = (widget.durationSeconds % 3600) ~/ 60;
    final seconds = widget.durationSeconds % 60;
    final timeString =
        '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    return trackPointsAsync.when(
      data: (trackPoints) {
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. マップ表示エリア（タブ切替ボタン付き）
              SizedBox(
                height: 300,
                child: Stack(
                  children: [
                    _DetailMapView(
                      trackPoints: trackPoints,
                      showAllMarkers: _showAllMarkers,
                    ),
                    // マップ右上: マーカー表示モード切替タブ
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Card(
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment<bool>(
                              value: false,
                              label: Text('ルート'),
                              icon: Icon(Icons.route, size: 16),
                            ),
                            ButtonSegment<bool>(
                              value: true,
                              label: Text('全ピン'),
                              icon: Icon(Icons.pin_drop, size: 16),
                            ),
                          ],
                          selected: {_showAllMarkers},
                          onSelectionChanged: (Set<bool> newSelection) {
                            setState(() {
                              _showAllMarkers = newSelection.first;
                            });
                          },
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // 2. 6項目統計グリッド
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'アクティビティ統計',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    GridView.count(
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.3,
                      children: [
                        _StatCard(
                          label: '移動距離',
                          value:
                              '${widget.totalDistance.toStringAsFixed(2)} km',
                          icon: Icons.straighten,
                        ),
                        _StatCard(
                          label: '移動時間',
                          value: timeString,
                          icon: Icons.timer,
                        ),
                        _StatCard(
                          label: '平均速度',
                          value: avgSpeed != null
                              ? '${avgSpeed.toStringAsFixed(1)} km/h'
                              : '--- km/h',
                          icon: Icons.speed,
                        ),
                        _StatCard(
                          label: '獲得標高',
                          value:
                              '${widget.elevationGain.toStringAsFixed(0)} m',
                          icon: Icons.filter_hdr,
                        ),
                        _StatCard(
                          label: '最高高度',
                          value:
                              '${widget.maxAltitude!.toStringAsFixed(0)} m',
                          icon: Icons.arrow_upward,
                        ),
                        _StatCard(
                          label: '最低高度',
                          value:
                              '${widget.minAltitude!.toStringAsFixed(0)} m',
                          icon: Icons.arrow_downward,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // 3. 最下部: 高度変化グラフ (fl_chart)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '高度プロファイル',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ElevationChart(trackPoints: trackPoints),
                  ],
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        );
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(48.0),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (err, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text('トラックポイントの読み込みに失敗しました: $err'),
        ),
      ),
    );
  }
}

// =============================================================================
// サブウィジェット1: マップ領域 (LatLngBounds による完全自動画角調整)
// =============================================================================
class _DetailMapView extends StatefulWidget {
  final List<TrackPoint> trackPoints;
  final bool showAllMarkers;

  const _DetailMapView({
    required this.trackPoints,
    required this.showAllMarkers,
  });

  @override
  State<_DetailMapView> createState() => _DetailMapViewState();
}

class _DetailMapViewState extends State<_DetailMapView> {
  final MapController _mapController = MapController();

  @override
  Widget build(BuildContext context) {
    if (widget.trackPoints.isEmpty) {
      return Container(
        color: Colors.grey.shade200,
        child: const Center(child: Text('位置情報データが保存されていません')),
      );
    }

    // 全トラックポイントを LatLng リスト化
    final points = widget.trackPoints
        .map((tp) => LatLng(tp.latitude, tp.longitude))
        .toList();

    // 画面枠に最適フィットさせるバウンディングボックスの作成
    final bounds = LatLngBounds.fromPoints(points);

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: bounds.center,
        initialZoom: 14.0,
        // 初期表示時にbounds全体が収まるようカメラを自動フィットさせる。
        // build()内でMapController.fitCamera()を後から呼ぶと、TileLayerの
        // 初回タイル読み込みと競合してタイルがグレーのまま表示されなくなるため、
        // MapOptions.initialCameraFitを使ってレイアウト確定後に一度だけ適用する
        initialCameraFit: CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(36.0), // 画面縁からの余白設定
          // トラックポイントが1点のみ(幅・高さ0の退化したbounds)の場合、
          // ズーム計算がInfinityになりタイルが表示されなくなるため上限を設ける
          maxZoom: 18.0,
        ),
        // マップ操作は無効化 (北上固定)
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.none,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: osmTileUrlTemplate,
          userAgentPackageName: osmUserAgentPackageName,
        ),

        // トラックポイントをつなぐポリライン
        PolylineLayer(
          polylines: [
            Polyline(
              points: points,
              strokeWidth: 4.0,
              color: Colors.blueAccent,
            ),
          ],
        ),

        // マーカー層 (モードで分岐)
        MarkerLayer(
          markers: widget.showAllMarkers
              ? _buildAllMarkers(points)
              : _buildStartEndMarkers(points.first, points.last),
        ),

        // OpenStreetMap のクレジット
        const OsmAttribution(),
      ],
    );
  }

  // ルートモード: スタート (緑) と ゴール (赤)
  List<Marker> _buildStartEndMarkers(LatLng start, LatLng end) {
    return [
      Marker(
        point: start,
        width: 32,
        height: 32,
        child: const Icon(Icons.play_circle_fill, color: Colors.green, size: 30),
      ),
      Marker(
        point: end,
        width: 32,
        height: 32,
        child: const Icon(Icons.flag, color: Colors.redAccent, size: 30),
      ),
    ];
  }

  // 全ピン表示モード: 全トラックポイントにピンを刺す
  List<Marker> _buildAllMarkers(List<LatLng> points) {
    return points.map((p) {
      return Marker(
        point: p,
        width: 10,
        height: 10,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.redAccent,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
          ),
        ),
      );
    }).toList();
  }
}

// =============================================================================
// サブウィジェット2: 統計表示用小カード
// =============================================================================
class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: Colors.grey.shade700),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// サブウィジェット3: 高度変化折れ線グラフ (fl_chart)
// =============================================================================
class _ElevationChart extends StatelessWidget {
  final List<TrackPoint> trackPoints;

  const _ElevationChart({required this.trackPoints});

  @override
  Widget build(BuildContext context) {
    // TrackPoint から (recordedAtの経過分, 高度) の FlSpot 配列を生成
    final data = ElevationChartData.fromTrackPoints(trackPoints);
    if (data == null) {
      return Container(
        height: 120,
        color: Colors.grey.shade100,
        child: const Center(child: Text('高度グラフ表示に十分なデータがありません')),
      );
    }
    final timeInterval = elevationChartTimeInterval(data.maxX);

    return Container(
      height: 200,
      padding: const EdgeInsets.only(right: 24, left: 0, top: 12, bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: data.maxX,
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touchedSpots) => touchedSpots
                  .map((s) => LineTooltipItem(
                        '${formatChartTimeLabel(data.timeAt(s.x))}\n'
                        '${s.y.toStringAsFixed(0)} m',
                        const TextStyle(color: Colors.white, fontSize: 12),
                      ))
                  .toList(),
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => FlLine(
              color: Colors.grey.shade200,
              strokeWidth: 1,
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            // X軸: recordedAtの時刻(HH:mm)
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: timeInterval,
                getTitlesWidget: (value, meta) {
                  // fl_chartは両端(min/max)にもラベルを描くため、間隔の倍数以外は出さない
                  // (右端のラベルが直前の目盛りラベルと重なるのを防ぐ)
                  final remainder = value % timeInterval;
                  if (remainder > 1e-6 && timeInterval - remainder > 1e-6) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      formatChartTimeLabel(data.timeAt(value)),
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) {
                  return Text(
                    '${value.toInt()}m',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: data.spots,
              // 点の間隔が不均一でもスプラインが実データの範囲を大きくはみ出さないようにする
              preventCurveOverShooting: true,
              isCurved: true,
              color: Colors.blueAccent,
              barWidth: 2.5,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.blueAccent.withValues(alpha: 0.15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}