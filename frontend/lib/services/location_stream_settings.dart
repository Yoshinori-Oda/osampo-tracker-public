import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

// 位置情報ストリームの購読設定をプラットフォーム別に組み立てる。
// background=trueは収録中(アプリがバックグラウンドに回っても記録を継続する)、
// falseは非収録中(バックグラウンドに回ったら購読自体を止める前提の、前面専用の設定)
LocationSettings buildPositionStreamSettings({
  required bool background,
  TargetPlatform? platform,
}) {
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        // 指定するとgeolocatorがForeground Service(常駐通知付き)を起動し、
        // バックグラウンドでもプロセスが回収されにくくなる。購読をcancelすると停止する
        foregroundNotificationConfig: background
            ? const ForegroundNotificationConfig(
                notificationTitle: 'おさんぽ記録中',
                notificationText: '移動ルートを記録しています',
                enableWakeLock: true,
                setOngoing: true,
              )
            : null,
      );
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        activityType: ActivityType.fitness,
        // trueだと静止中にOSが更新を止め、アプリがサスペンドされてTimerも止まってしまう
        pauseLocationUpdatesAutomatically: false,
        // Info.plistのUIBackgroundModesにlocationが必要
        allowBackgroundLocationUpdates: background,
        showBackgroundLocationIndicator: background,
      );
    default:
      return const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );
  }
}
