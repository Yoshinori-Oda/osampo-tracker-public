# バックグラウンドでの収録

収録中はアプリがバックグラウンドに回っても記録を続け、収録していない間はバックグラウンドで位置情報の購読を止める(サスペンドする)。
2026-11-10時点のmainの実装を正とする。関連: `frontend/lib/services/tracking_service.dart`(`_syncPositionStream()`)・
`frontend/lib/services/location_stream_settings.dart`・`views/main_page.dart`・`android/app/src/main/AndroidManifest.xml`・`ios/Runner/Info.plist`。

別のisolateのバックグラウンドserviceは使わない。geolocatorの購読の設定だけでプロセスを生かし続け、Dartのコード(ストリームのlisten・
`Timer.periodic`・Driftへの書き込み)をそのまま動かす。

## 購読の切り替え

- 購読の開始・停止・設定の切り替えは`TrackingService._syncPositionStream()`にまとめ、直列に実行する。呼び出し元は次の4つ:
  - `_setPhase()`(収録の状態が変わったとき。バックグラウンドにいる間に購読が止まっていても、ここでは再購読しない: `startIfStopped: false`)
  - `_initTrackingStream()`(起動時)
  - `handleAppLifecycleState()`(`main_page.dart`の`didChangeAppLifecycleState`から)
  - `refreshLocationAvailability()`(フォアグラウンド復帰時)
- 収録の状態ごとの設定(`buildPositionStreamSettings(background: ...)`):
  - `starting`・`recording`: バックグラウンドでも続ける設定(`background: true`)
  - `idle`・`stopping`: フォアグラウンドだけの設定。アプリが`hidden`・`paused`になったら購読と監視のタイマーを止め、`resumed`で
    `refreshLocationAvailability()`から再開する。`inactive`は権限のダイアログやコントロールセンターの表示中にも来るので、購読を止めない
- `starting`の時点でバックグラウンド用に切り替える。Android 12以降はバックグラウンドからForeground Serviceを起動できないので、
  開始ボタンを押した直後(確実にフォアグラウンドにいる時点)で起動しておく

## 購読の設定(`location_stream_settings.dart`)

| | 共通 | バックグラウンド(`background: true`)のときだけ |
| --- | --- | --- |
| Android(`AndroidSettings`) | `accuracy: high`・`distanceFilter: 0`・`intervalDuration: 1秒` | `ForegroundNotificationConfig`でForeground Service(常駐通知「おさんぽ記録中」「移動ルートを記録しています」、`enableWakeLock`・`setOngoing`)を起動する。購読をcancelすると止まる |
| iOS(`AppleSettings`) | `accuracy: high`・`distanceFilter: 0`・`activityType: fitness`・`pauseLocationUpdatesAutomatically: false` | `allowBackgroundLocationUpdates`・`showBackgroundLocationIndicator`をtrueにする |

- iOSの`pauseLocationUpdatesAutomatically`は常にfalse。trueだと静止中にOSが更新を止め、アプリがサスペンドされて`Timer.periodic`
  (5秒ごとのトラックポイントの記録)も止まるため

## 権限とマニフェスト

- 位置情報の権限は「使用中のみ許可」で足りる(フォアグラウンドで始めた更新はバックグラウンドでも続けられる)。Androidの
  `ACCESS_BACKGROUND_LOCATION`は要求しない(Play Consoleでの用途の申告も要らない)
- Android 13以降で常駐通知を出すための通知の権限は、起動時(`_initTrackingStream`)に、Androidで、かつ位置情報の権限が取れた場合だけ
  `permission_handler`で求める(拒否されてもServiceは動くが、通知ドロワーに出なくなる)
- AndroidManifest.xml: `ACCESS_FINE_LOCATION`・`ACCESS_COARSE_LOCATION`・`FOREGROUND_SERVICE`・`FOREGROUND_SERVICE_LOCATION`
  (Android 14以降、`foregroundServiceType="location"`のServiceに必須)・`POST_NOTIFICATIONS`・`WAKE_LOCK`
- Info.plist: `UIBackgroundModes`に`location`。使用目的の説明は`NSLocationWhenInUseUsageDescription`と
  `NSLocationAlwaysAndWhenInUseUsageDescription`(「常に許可」は要求していない)

## サスペンドからの復帰

- 復帰の直後は、止めていた間の空白を「更新停止」のバナーにしないよう、監視を再開した時刻(`_monitoringStartedAt`)も起点にして10秒の猶予を置く
  (`frontend/docs/location-tracking.md`の「位置情報の監視とバナー」)。収録の開始時の15秒の判定は、実際の最後の受信の時刻
  (`_lastGoodPositionAt`)で行う
- 一部のAndroid端末(独自のバッテリーの最適化を持つメーカーのもの)では、Foreground ServiceでもOSがプロセスごと終了させることがある。
  その場合は`frontend/docs/session-recovery.md`の経路で保存/破棄させる

## テスト・確認

- 購読の設定の切り替えと終了地点は`test/tracking_service_background_test.dart`で確かめている
- 実際の動作は、実機、または位置の移動をシミュレートしたシミュレータで確かめる(iOSシミュレータは`Features > Location > City Run`)。
  収録中にホームへ戻り、数分後に復帰して軌跡が途切れていないかを見る
