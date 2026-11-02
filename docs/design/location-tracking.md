# 位置情報取得の堅牢性設計

関連: `frontend/lib/services/tracking_service.dart`・`models/`のRecordingPhase/LocationBannerState・`widgets/`の各バナー・`views/main_page.dart`・`views/recording_page.dart`

GPSが未確定/不正確な状態(アプリ起動直後・屋内・電波不良など)でも収録が壊れないよう、
`TrackingService`に位置情報監視の状態管理を持たせている。設計の要点:

- **収録の状態は`RecordingPhase`(idle/starting/recording/stopping)で管理する**。
  `startRecording()`はidleの時のみ受け付け、`starting`中は連打による二重start
  (レースコンディション)を防ぐガードになる。`recording_page.dart`は`starting`中、
  収録タブ全体を`AbsorbPointer`+オーバーレイでinactive化し、キャンセルボタンも出す。
- **`Geolocator.getCurrentPosition`は必ず`LocationSettings(timeLimit: ...)`を設定して
  呼ぶこと**(標準パラメータの`timeLimit`はdeprecated。`LocationSettings`経由で渡す)。
  無期限に待つと、GPS未確定のままハングし続ける。呼び出し箇所ごとにtimeLimitを変えている:
  `_initTrackingStream`の初回取得とstopRecordingは1秒、startRecordingは5秒
  (ストリームが既に動いていれば大抵は温まっているが、アプリ起動直後にすぐRECを
  押すケースは温まっていないため長めに取っている)。
- **`_lastGoodPositionAt`(DateTime?)が位置情報監視の中心的な状態**。精度に関わらず
  位置を受信するたびに更新し、これを起点に「未取得(null)」「更新停止(10秒以上経過)」
  を判定してバナー(`LocationBannerView`)に表示する。精度(accuracy>50m)は別軸の
  ヒステリシス付きカウンタ(+3/-1、無更新中は凍結、長時間の停止から復帰した際は
  クリーンに0リセット)で管理する。バナーの優先順位は権限エラー > 未取得/タイムアウト
  > 精度低下(1つだけ表示)。
- **`startRecording()`はOSの位置情報キャッシュ(`getLastKnownPosition()`)を使わない**。
  新鮮な位置が取れなければ、このセッション内で最後に確認できた位置
  (`_lastGoodPositionAt`が15秒以内)のみをフォールバック候補にし、確認ダイアログで
  開始可否を聞く。15秒を超える/一度も取得できていない場合は
  `StartRecordingBlockedException`を投げて開始をブロックする(再試行ボタン付きの
  エラーダイアログを表示)。「セッションとして意味のあるデータかどうか」を基準に
  しており、別セッション/別文脈の可能性があるOSキャッシュは意図的に除外している。
- **収録開始時のtrackpointの`recordedAt`は押下時刻ではなく`Position.timestamp`
  (実際にその位置情報が取得された時刻)を使う**。フォールバック開始時は数秒〜15秒
  古い時刻になり得るが、意図した挙動。
- **`stopRecording()`の終了地点取得もtimeLimit 1秒**。失敗した場合は最終ポイントの
  追加だけをスキップしてそのまま保存し、スナックバーで通知する。戻り値は`bool?`
  (null=取得を試みなかった、true=取得できた、false=取得を試みたが失敗した)。
- **収録中に位置情報の権限/サービスが失われた場合**、`_forceStopForPermissionTrouble()`が
  `stopRecording(skipFinalPositionFetch: true)`を呼んで強制停止し、
  `utils/save_or_discard_screen.dart`の`showSaveOrDiscardScreen()`(通常の停止フローと
  共通化済み)を`navigatorKey`経由で呼び出して保存/破棄を確認する。**検知経路は
  `getPositionStream`の`onError`だけでは不十分**(実際に発生した不具合)。設定アプリでの
  権限/サービス変更は必ず一度アプリをバックグラウンドに回すため、多くの場合onErrorは
  発火しない。実質的な主検知経路は`main_page.dart`のフォアグラウンド復帰フックから呼ぶ
  `refreshLocationAvailability()`で、`RecordingPhase.recording`中にtroubleを検知した
  場合も同じ強制停止をトリガーする(`stopping`中の多重発火は`_phase`チェックで防止)。
- **収録状態バナーと位置情報バナーは全タブ共通で`main_page.dart`の`body`上部に表示する**。
  どちらも非アクティブ時は`SizedBox.shrink()`で高さ0にする設計だが、それを包む
  padding/`SafeArea`は「バナーが1つもない時は一切描画しない」ようにしないと、
  ステータスバー避けの空白だけが常時残ってしまう。逆にバナー表示中は、タブ側
  (各`AppBar`)が自前でも同じ分のステータスバー避けpaddingを確保してしまい二重の
  空白になるため、`MediaQuery.removePadding(removeTop: hasAnyBanner)`でタブ側の
  重複分を明示的に消費している(詳細は`main_page.dart`参照)。
- GPSを掴みやすくするTipsは`views/gps_help_page.dart`にまとめ、「未取得/更新停止」の
  位置情報バナーと`startRecording`のブロックダイアログの両方から
  `widgets/gps_help_link.dart`経由でリンクしている。
