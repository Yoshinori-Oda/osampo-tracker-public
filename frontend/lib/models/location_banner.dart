import '../utils/duration_format.dart';

// 位置情報がらみの不具合を示すバナーの種類。
// 優先度は上から順(serviceDisabled/permissionDenied > neverAcquired/stalled > accuracyLow)。
enum LocationBannerKind {
  none,
  serviceDisabled,
  permissionDenied,
  neverAcquired,
  stalled,
  accuracyLow,
}

class LocationBannerState {
  final LocationBannerKind kind;
  final Duration? elapsedSinceLastGood;

  const LocationBannerState({required this.kind, this.elapsedSinceLastGood});

  static const none = LocationBannerState(kind: LocationBannerKind.none);

  bool get isActive => kind != LocationBannerKind.none;

  // 「位置情報が掴めていない系」のバナーにのみ、GPSを掴みやすくするヘルプページへのリンクを出す
  bool get showsGpsHelpLink =>
      kind == LocationBannerKind.neverAcquired || kind == LocationBannerKind.stalled;

  // 端末/アプリの設定変更が必要な系のバナーには設定画面へのリンクを出す
  bool get showsSettingsLink =>
      kind == LocationBannerKind.serviceDisabled || kind == LocationBannerKind.permissionDenied;

  String get message {
    switch (kind) {
      case LocationBannerKind.none:
        return '';
      case LocationBannerKind.serviceDisabled:
        return '端末の位置情報サービスがOFFになっています。設定から有効にしてください。';
      case LocationBannerKind.permissionDenied:
        return 'このアプリの位置情報の利用が許可されていません。設定から許可してください。';
      case LocationBannerKind.neverAcquired:
        return '位置情報をまだ取得できていません。電波状況の良い場所でお試しください。';
      case LocationBannerKind.stalled:
        return '位置情報の更新が${formatElapsedJa(elapsedSinceLastGood!)}から止まっています。';
      case LocationBannerKind.accuracyLow:
        return '位置情報の精度が低下しています。';
    }
  }
}
