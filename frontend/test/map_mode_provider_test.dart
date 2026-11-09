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

void main() {
  // 保存/破棄画面を閉じたときのように、収録画面が非表示(TickerModeがoff)の間に現在地が更新され、
  // build中に再び表示されても、providerの変更でassertにならないこと
  testWidgets('非表示の間に現在地が更新されても、再表示のbuild中にproviderが変更されない', (tester) async {
    final positions = StreamController<Position>();
    addTearDown(positions.close);
    final tickerEnabled = ValueNotifier(true);
    addTearDown(tickerEnabled.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentPositionProvider.overrideWith((ref) => positions.stream),
      ],
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
    positions.add(_position(36.0));
    await tester.pump();

    tickerEnabled.value = true;
    await tester.pump();

    expect(tester.takeException(), isNull);
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
