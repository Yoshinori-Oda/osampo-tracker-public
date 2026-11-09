import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:test_tracking_01/providers/tracking_providers.dart';

Position _position(double latitude) => Position(
  latitude: latitude,
  longitude: 139.0,
  timestamp: DateTime.now(),
  accuracy: 5,
  altitude: 10,
  altitudeAccuracy: 1,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

// currentPositionProviderの依存先の代わり(アプリではログインし直しでtrackingServiceProviderが作り直される)
class _RestartNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void restart() => state++;
}

final _restartProvider = NotifierProvider<_RestartNotifier, int>(_RestartNotifier.new);

void main() {
  // 保存/破棄画面を開いている間のように、収録画面が非表示(TickerModeがoff)で購読が止まっている間に
  // currentPositionProviderの依存先が変わると、再表示のbuild中にcurrentPositionProviderが作り直される。
  // そのときにmapModeProviderが変更されてassertにならないこと
  testWidgets('非表示の間に現在地のproviderの依存先が変わっても、再表示のbuild中にproviderが変更されない', (tester) async {
    // 作り直しで購読し直すのでbroadcastにする
    final positions = StreamController<Position>.broadcast();
    addTearDown(positions.close);
    final tickerEnabled = ValueNotifier(true);
    addTearDown(tickerEnabled.dispose);
    final container = ProviderContainer(overrides: [
      currentPositionProvider.overrideWith((ref) {
        ref.watch(_restartProvider);
        return positions.stream;
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: tickerEnabled,
          builder: (context, enabled, _) => TickerMode(
            enabled: enabled,
            child: Consumer(
              builder: (context, ref, _) {
                final mapState = ref.watch(mapModeProvider);
                final position = ref.watch(currentPositionProvider).value;
                return Text('${mapState.topMode.name} ${position?.latitude}');
              },
            ),
          ),
        ),
      ),
    ));

    positions.add(_position(35.0));
    await tester.pump();
    expect(find.text('direction 35.0'), findsOneWidget);

    tickerEnabled.value = false;
    await tester.pump();
    container.read(_restartProvider.notifier).restart();
    await tester.pump();

    tickerEnabled.value = true;
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 作り直した直後(新しい位置が届くまで)は、直前の位置を出したままにする
    expect(find.text('direction 35.0'), findsOneWidget);

    positions.add(_position(36.0));
    await tester.pump();
    expect(find.text('direction 36.0'), findsOneWidget);
  });

  testWidgets('現在地が更新されても、利用者が切り替えた表示モードは保たれる', (tester) async {
    final positions = StreamController<Position>();
    addTearDown(positions.close);
    final container = ProviderContainer(overrides: [
      currentPositionProvider.overrideWith((ref) => positions.stream),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(currentPositionProvider, (_, _) {});
    addTearDown(sub.close);

    container.read(mapModeProvider.notifier)
      ..toggleTopMode()
      ..setRecordingPageMode(RecordingPageMode.map);
    positions.add(_position(35.0));
    await tester.pump();

    final mapState = container.read(mapModeProvider);
    expect(mapState.topMode, MapTopMode.heading);
    expect(mapState.pageMode, RecordingPageMode.map);
    expect(container.read(currentPositionProvider).value?.latitude, 35.0);
  });
}
