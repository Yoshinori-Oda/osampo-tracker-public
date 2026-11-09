import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:latlong2/latlong.dart';
import '../models/recording_phase.dart';
import '../providers/tracking_providers.dart';
import '../services/tracking_service.dart' show StartRecordingBlockedException;
import '../widgets/compass.dart';
import '../widgets/gps_help_link.dart';
import '../widgets/osm_attribution.dart';
import '../utils/map_tiles.dart';
import 'map_view.dart';

class RecordingPage extends ConsumerStatefulWidget {
  const RecordingPage({super.key});

  @override
  ConsumerState<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends ConsumerState<RecordingPage> {
  final MapController _mapController = MapController();

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mapState = ref.watch(mapModeProvider);
    final notifier = ref.read(mapModeProvider.notifier);
    // 読み込み中・エラーの間も直前の値が返る(位置が一度取れた後は地図を出したままにする)
    final position = ref.watch(currentPositionProvider).value;
    final phase = ref.watch(recordingPhaseProvider).value ?? RecordingPhase.idle;
    final isRecording = phase == RecordingPhase.recording;
    final isStarting = phase == RecordingPhase.starting;
    final isStopping = phase == RecordingPhase.stopping;
    final canPress = phase == RecordingPhase.idle
      || phase == RecordingPhase.recording
      || phase == RecordingPhase.stopping;

    // camera follows current position
    if (position != null) {
      final currentLatLng = LatLng(
        position.latitude,
        position.longitude
      );

      final rotationAngle = (mapState.topMode == MapTopMode.heading)
        ? -position.heading
        : 0.0;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.moveAndRotate(currentLatLng, 17.0, rotationAngle);
      });
    }

    return Stack(
      children: [
        AbsorbPointer(
          absorbing: isStarting,
          child: Scaffold(
            appBar: AppBar(
              title: SegmentedButton<RecordingPageMode>(
                segments: const [
                  ButtonSegment(
                    value: RecordingPageMode.statistics,
                    label: Text('セッション情報')
                  ),
                  ButtonSegment(
                    value: RecordingPageMode.map,
                    label: Text('マップ操作')
                  )
                ],
                selected: {mapState.pageMode},
                onSelectionChanged: (Set<RecordingPageMode> newSelection) {
                  notifier.setRecordingPageMode(newSelection.first);
                }
              )
            ),
            body: IndexedStack(
              index: mapState.pageMode.index,
              children: [
                _buildStatisticsTabView(context, ref, mapState, position),
                const MapControlTabView()
              ]
            ),
            bottomNavigationBar: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isRecording
                      ? Colors.red
                      : (isStopping ? Colors.orange : Colors.blue),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30)
                    )
                  ),
                  onPressed: canPress
                    ? () async {
                        if (isStopping) {
                          await ref.read(trackingServiceProvider).resumePendingCompletion();
                        } else if (!isRecording) {
                          await _handleStartPressed(context, ref);
                        } else {
                          _showStopRecordingDialog(context, ref);
                        }
                      }
                    : null,
                  child: Text(
                    isStopping
                      ? '前回のセッションを処理'
                      : (isRecording ? '収録終了 (STOP)' : '収録開始 (REC)'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                  )
                )
              )
            )
          )
        ),
        if (isStarting) _buildStartingOverlay(context, ref)
      ]
    );
  }

  // 現在地取得中(startRecordingのローディング)のオーバーレイ。収録タブの操作を無効化する
  Widget _buildStartingOverlay(BuildContext context, WidgetRef ref) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.5),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              const Text('現在地を取得しています…', style: TextStyle(color: Colors.white)),
              const SizedBox(height: 24),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white)
                ),
                onPressed: () => ref.read(trackingServiceProvider).cancelStarting(),
                child: const Text('キャンセル')
              )
            ]
          )
        )
      )
    );
  }

  // 収録開始ボタン押下時の処理。位置情報が取れずブロックされた場合は再試行できるダイアログを出す
  Future<void> _handleStartPressed(BuildContext context, WidgetRef ref) async {
    final service = ref.read(trackingServiceProvider);
    try {
      await service.startRecording();
    } on StartRecordingBlockedException {
      if (!context.mounted) return;
      final retry = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('収録を開始できません'),
            content: const Text('現在地を取得できませんでした。電波状況の良い場所で再試行してください。'),
            actions: [
              GpsHelpLinkButton(textColor: Theme.of(dialogContext).colorScheme.primary),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('閉じる')
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('再試行')
              )
            ]
          );
        }
      );
      if (retry == true && context.mounted) {
        await _handleStartPressed(context, ref);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('収録を開始できませんでした: $e'))
      );
    }
  }

  // session statistics tab
  Widget _buildStatisticsTabView(
    BuildContext context,
    WidgetRef ref,
    MapModeState mapState,
    Position? position
  ) {
    return Column(
      children: [
        // map section (top 38%)
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.38,
          child: Stack(
            children: [
              _buildMapView(position),

              // compass button to toggle topMode
              Positioned(
                top: 12,
                right: 12,
                child: FloatingActionButton.small(
                  heroTag: 'compass_btn',
                  backgroundColor: Colors.transparent,
                  elevation: 2,
                  onPressed: () {
                    ref.read(mapModeProvider.notifier).toggleTopMode();
                  },
                  child: RealCompassWidget(
                    heading: position?.heading ?? 0.0,
                    isHeadingMode: mapState.topMode == MapTopMode.heading,
                    size: 40.0
                  )
                )
              )
            ]
          )
        ),

        // session info section (rest of bottom)
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _buildMetricTile('移動距離', ref.watch(totalDistanceProvider))),
                    const SizedBox(width: 8),
                    Expanded(child: _buildMetricTile('移動時間', ref.watch(elapsedTimeProvider))),
                  ]
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildMetricTile('現在速度', ref.watch(currentSpeedProvider))),
                    const SizedBox(width: 8),
                    Expanded(child: _buildMetricTile('平均速度', ref.watch(averageSpeedProvider))),
                  ]
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildMetricTile('現在高度', ref.watch(altitudeProvider))),
                    const SizedBox(width: 8),
                    Expanded(child: _buildMetricTile('獲得高度', ref.watch(elevationGainProvider))),
                  ]
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildMetricTile('最高高度', ref.watch(maxAltitudeProvider))),
                    const SizedBox(width: 8),
                    Expanded(child: _buildMetricTile('最低高度', ref.watch(minAltitudeProvider))),
                  ]
                ),
              ]
            )
          )
        )
      ]
    );
  }

  // flutter map builder
  Widget _buildMapView(Position? position) {
    if (position == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final currentLatLng = LatLng(
      position.latitude,
      position.longitude
    );

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: currentLatLng,
        initialZoom: 17.0,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.none
        )
      ),
      children: [
        TileLayer(
          urlTemplate: osmTileUrlTemplate,
          userAgentPackageName: osmUserAgentPackageName
        ),

        MarkerLayer(
          markers: [
            Marker(
              point: currentLatLng,
              width: 40,
              height: 40,
              child: Transform.rotate(
                angle: (position.heading * pi) / 180,
                child: const Icon(
                  Icons.navigation,
                  size: 32,
                  color: Colors.blueAccent
                )
              )
            )
          ]
        ),

        // OpenStreetMap のクレジット
        const OsmAttribution(),
      ]
    );
  }

  Widget _buildMetricTile(String title, String value) {
    return Card(
      elevation: 1.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
                fontWeight: FontWeight.bold
              )
            ),
            const SizedBox(height: 6),
            Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold
                    )
                  )
                ),
              ]
            )
          ]
        )
      )
    );
  }

  // popup for session end
  void _showStopRecordingDialog(BuildContext context, WidgetRef ref) async {
    final service = ref.read(trackingServiceProvider);

    // confirm stop dialog
    final shouldStop = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('トラッキング停止'),
          content: const Text('トラッキングを停止しますか?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('継続')
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('停止')
            )
          ]
        );
      }
    );

    if (shouldStop != true) return;

    final finalPointFetched = await service.stopRecording();

    if (!context.mounted) return;
    if (finalPointFetched == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('終了地点の位置情報が取得できなかったため、直前の記録までを保存しました'))
      );
    }

    // save / discard screen (強制停止/起動時リカバリと同じ経路で表示する)
    await service.resumePendingCompletion();
  }
}