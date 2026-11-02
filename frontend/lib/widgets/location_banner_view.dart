import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../models/location_banner.dart';
import '../providers/tracking_providers.dart';
import 'gps_help_link.dart';

// 位置情報の不具合(権限/未取得/更新停止/精度低下)を、収録タブに限らず常時上部に表示するバナー。
class LocationBannerView extends ConsumerWidget {
  const LocationBannerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = ref.watch(locationBannerProvider).value ?? LocationBannerState.none;
    if (!banner.isActive) return const SizedBox.shrink();

    return Material(
      color: Colors.orange.shade700,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                banner.message,
                style: const TextStyle(color: Colors.white, fontSize: 13)
              )
            ),
            if (banner.showsSettingsLink)
              TextButton(
                onPressed: () {
                  if (banner.kind == LocationBannerKind.serviceDisabled) {
                    Geolocator.openLocationSettings();
                  } else {
                    Geolocator.openAppSettings();
                  }
                },
                child: const Text('設定を開く', style: TextStyle(color: Colors.white))
              ),
            if (banner.showsGpsHelpLink) const GpsHelpLinkButton()
          ]
        )
      )
    );
  }
}
