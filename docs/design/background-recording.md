# バックグラウンド収録設計

関連: `frontend/lib/services/tracking_service.dart`(`_syncPositionStream()`)・`frontend/lib/services/location_stream_settings.dart`・`views/main_page.dart`・AndroidManifest.xml/Info.plist

収録中はアプリがバックグラウンドに回っても記録を継続し、収録していない間はバックグラウンドで
位置情報の購読を止める(サスペンドする)。別isolateのバックグラウンドserviceは使わず、
geolocatorの購読設定だけでプロセスを生かし続け、既存のDartコード(ストリームのlisten・
`Timer.periodic`・Driftへの書き込み)をそのまま動かす方式:

- **購読の開始/停止/設定の切り替えは`TrackingService._syncPositionStream()`に集約し、直列化している**。
  `_setPhase()`(フェーズ変化)と`handleAppLifecycleState()`(`main_page.dart`の
  `didChangeAppLifecycleState`から呼ぶ)の両方から呼ばれ、次の状態に合わせる:
  - `starting`/`recording`: バックグラウンド継続用の設定(`buildPositionStreamSettings(background: true)`)。
    Androidはgeolocatorの`ForegroundNotificationConfig`でForeground Service(常駐通知付き)を起動し、
    iOSは`allowBackgroundLocationUpdates: true`(Info.plistの`UIBackgroundModes`に`location`が必要)
  - `idle`/`stopping`: フォアグラウンド専用の設定。`hidden`/`paused`で購読と監視タイマーを止め、
    `resumed`で`refreshLocationAvailability()`経由で再開する。`inactive`は権限ダイアログや
    コントロールセンター表示中にも来るため購読を止めない
- **`starting`の時点でバックグラウンド用に切り替える**。Android 12以降はバックグラウンドから
  Foreground Serviceを起動できないため、RECを押した直後(確実にフォアグラウンドにいる時点)で
  起動しておく。バックグラウンドにいる間に購読が止まっている場合、フェーズ変化をきっかけに
  再購読はしない(`startIfStopped: false`)
- 権限は「使用中のみ許可」で足りる(フォアグラウンドで開始した更新はバックグラウンドでも継続できる)ため、
  Androidの`ACCESS_BACKGROUND_LOCATION`は要求しない(Play Consoleでの用途申告も不要)。Android 13以降の
  常駐通知の表示に必要な通知権限は、起動時に位置情報の権限の後で`permission_handler`で要求する
  (拒否されてもServiceは動く)
- iOSは`pauseLocationUpdatesAutomatically: false`にしている。trueだと静止中にOSが更新を止め、
  アプリがサスペンドされて`Timer.periodic`(5秒ごとのtrackpoint記録)も止まるため
- サスペンドからの復帰直後は、止めていた間の空白を「更新停止」バナーとして出さないよう、
  `_monitoringStartedAt`(監視を再開した時刻)を起点に10秒の猶予を置く。`startRecording()`の
  15秒フォールバック判定は従来通り実際の最終受信時刻(`_lastGoodPositionAt`)で行う
- 一部のAndroid端末(独自のバッテリー最適化を持つメーカー)は、Foreground Serviceでもプロセスごと
  終了させることがある。その場合は`docs/design/session-recovery.md`の経路で保存/破棄させる
- 動作確認は実機、または位置の移動をシミュレートしたシミュレータ/エミュレータで行う
  (iOSシミュレータは`Features > Location > City Run`、Androidエミュレータは
  Extended controlsのRoutes)。収録中にホームへ戻り、数分後に復帰して軌跡が途切れていないかを見る
