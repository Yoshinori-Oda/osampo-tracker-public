import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

// 地図に重ねるOpenStreetMapのクレジット。FlutterMapのchildrenの最後に置く(マーカー等より手前に描くため)。
// SimpleAttributionWidgetは内部でSafeAreaを使うので、そのままだと画面下端の安全領域(ホームインジケータ)の分だけ
// 地図の中でも浮いて表示される。地図の端に揃えるため、安全領域の余白を外してから置く。
class OsmAttribution extends StatelessWidget {
  final Alignment alignment;

  const OsmAttribution({super.key, this.alignment = Alignment.bottomRight});

  @override
  Widget build(BuildContext context) {
    return MediaQuery.removePadding(
      context: context,
      removeLeft: true,
      removeTop: true,
      removeRight: true,
      removeBottom: true,
      child: SimpleAttributionWidget(
        source: const Text('OpenStreetMap contributors'),
        alignment: alignment,
      ),
    );
  }
}
