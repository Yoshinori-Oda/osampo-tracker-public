import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../../providers/tracking_providers.dart';
import '../utils/map_tiles.dart';
import '../widgets/osm_attribution.dart';

class MapControlTabView extends ConsumerStatefulWidget {
  const MapControlTabView({super.key});

  @override
  ConsumerState<MapControlTabView> createState() => _MapControlTabViewState();
}

class _MapControlTabViewState extends ConsumerState<MapControlTabView> {
  final MapController _interactiveMapController = MapController();

  @override
  void dispose() {
    _interactiveMapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentPosition = ref.watch(currentPositionProvider).value;

    if (currentPosition == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final currentLatLng = LatLng(
      currentPosition.latitude,
      currentPosition.longitude,
    );

    return Stack(
      children: [
        // 1. 全画面フリー操作マップ
        FlutterMap(
          mapController: _interactiveMapController,
          options: MapOptions(
            initialCenter: currentLatLng,
            initialZoom: 16.0,
            // ドラッグ・ピンチズーム・回転などすべての標準ジェスチャーを許可
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
          ),
          children: [
            // OpenStreetMap タイルレイヤー
            TileLayer(
              urlTemplate: osmTileUrlTemplate,
              userAgentPackageName: osmUserAgentPackageName
            ),

            // 現在地マーカー
            MarkerLayer(
              markers: [
                Marker(
                  point: currentLatLng,
                  width: 24,
                  height: 24,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blueAccent,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // OpenStreetMap のクレジット (右下は再トラッキングボタンがあるので左下に出す)
            const OsmAttribution(alignment: Alignment.bottomLeft),
          ],
        ),

        // 2. 右下: 現在地へカメラを再トラッキングさせるフローティングボタン
        Positioned(
          bottom: 24,
          right: 16,
          child: FloatingActionButton(
            heroTag: 'recenter_btn',
            backgroundColor: Colors.white,
            foregroundColor: Colors.blueAccent,
            onPressed: () {
              _interactiveMapController.move(currentLatLng, 16.0);
            },
            child: const Icon(Icons.my_location),
          ),
        ),
      ],
    );
  }
}