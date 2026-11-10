# 位置情報の取得と収録の状態

GPSが未確定・不正確な状態(アプリの起動直後・屋内・電波が弱い等)でも収録が壊れないようにする仕組み。2026-11-10時点のmainの実装を正とする。
中心は`frontend/lib/services/tracking_service.dart`の`TrackingService`。関連: `models/`の`RecordingPhase`・`LocationBannerState`、
`widgets/`の各バナー、`views/main_page.dart`・`views/recording_page.dart`。
バックグラウンドでの収録は`frontend/docs/background-recording.md`、停止後の保存/破棄は`frontend/docs/session-recovery.md`。

## 収録の状態(`RecordingPhase`)

- `idle` → `starting` → `recording` → `stopping` → `idle`
- `startRecording()`は`idle`のときだけ受け付ける。`starting`の間は、連打による二重の開始を防ぐ。`recording_page.dart`は`starting`の間、
  収録タブ全体を`AbsorbPointer`とオーバーレイで操作できなくし、キャンセルボタンを出す
- `stopping`は、停止してから保存/破棄が済むまでの状態。この間も収録中のセッション(`_session`)は残る

## 位置の取得

- `Geolocator.getCurrentPosition`は必ず`LocationSettings(timeLimit: ...)`付きで呼ぶ(無期限に待つと、GPSが未確定のままハングする)。
  呼び出しを重ねない(`frontend/docs/overview.md`の「位置情報 (geolocator)」)
- フォアグラウンド用の設定で位置情報ストリームを購読し始めるたびに(`_startPositionStream`)、初期位置を`timeLimit`1秒で取る
  (取れなくても、以後はストリームからの更新を待つだけ)
- 収録の開始時は`timeLimit`5秒で新しい位置を取る(アプリの起動直後にすぐ開始する場合はGPSが温まっていないため、長めにしている)

## 位置情報の監視とバナー

- 位置を受信するたびに、精度に関わらず`_lastGoodPositionAt`(最後に受信した時刻)と`_lastReceivedPosition`を更新する
- バナー(`LocationBannerView`)の状態は次の順に判定し、1つだけ出す:
  1. 権限・位置情報サービスの問題
  2. 未取得(一度も受信していない)
  3. 更新停止: 最後の受信から10秒以上。ただし監視を再開した時刻(サスペンドからの復帰)の方が新しければそちらを起点にする
     (止めていた間の空白を「停止」と見なさないため。表示する経過時間は実際の最後の受信から)
  4. 精度の低下: 精度が50mより悪い受信で+3、良い受信で-1するカウンタ(0〜9)が1以上
- 精度のカウンタは、更新停止から復帰したときは0に戻す(停止前の状態を引きずらない)
- バナーは1秒ごとに計算し直す(受信が止まっても「更新停止」に変わるように)

## 収録の開始

- OSの位置情報のキャッシュ(`getLastKnownPosition()`)は使わない(別の文脈の古い位置の可能性があるため)
- 5秒以内に新しい位置が取れなければ、アプリの起動後に最後に受信した位置を、受信から15秒以内のときだけ候補にし、
  ダイアログ「現在地を取得できませんでした」で、その位置から始めるかを聞く
- 15秒を超えている・一度も受信していない場合は`StartRecordingBlockedException`を投げて開始しない(再試行ボタン付きのエラーダイアログを出す)
- 開始地点のトラックポイントの`recordedAt`は、ボタンを押した時刻ではなく`Position.timestamp`(その位置を取得した時刻)。
  候補の位置から始めたときは数秒〜15秒前の時刻になるが、意図した挙動

## 収録中の記録

- 1秒ごとのタイマーで経過時間を進め、5秒ごとに、その時点で最後に受信した位置をトラックポイントとして記録する(`recordedAt`は記録した時刻)

## 収録の停止と終了地点

- `stopRecording()`はタイマーを止めて(待つ間に経過時間・トラックポイントが増えないように)`stopping`にし、終了地点の取得を待たずに戻る
  (保存/破棄画面をすぐ開けるように)
- 終了地点: 経過秒数が5の倍数でない(最後の記録から時間が空いている)ときだけ、停止後に最初に受信した位置(停止で購読を切り替えたときの
  初期位置の取得と、ストリームのどちらか)を最大5秒、裏で待つ(`_addFinalPoint`)。受信できたら、停止した時刻を`recordedAt`として
  トラックポイントに足す
  - `getCurrentPosition`を別に呼ばないのは、購読の切り替えの初期位置の取得と重なり、iOSでは先の呼び出しが完了しないため
  - 取れなかった場合はそれまでの記録のまま保存し、画面には出さない(`appLog`の`[tracking]`の行にだけ出す)
  - 終了地点は統計(距離・高度)には加えず、地図のトラックポイントに足すだけ
- 取得の間も保存/破棄はできる。`completeSession()`は、DBへの反映(保存・削除)だけを終了地点の追加が済むまで待つ(保存では終了地点も
  含めて同期し、破棄では削除の後に終了地点が書き込まれないように)

## 権限・位置情報サービスを失ったとき

- 収録中に位置情報の権限・サービスが失われたら、`_forceStopForPermissionTrouble()`が終了地点を取らずに停止し
  (`stopRecording(skipFinalPositionFetch: true)`)、`_presentPendingCompletion()`で保存/破棄を促す。収録タブを見ていれば
  保存/破棄画面を直接開き、ほかのタブならスナックバー「保存/破棄が必要なセッションがあります」(「収録画面へ」で開く)を出す
- 検知の経路は2つある:
  - ストリームの`onError`(`_handleLocationStreamError`)。`isRecording`(収録中のセッションがある)なら強制停止する
  - フォアグラウンド復帰時に`main_page.dart`から呼ぶ`refreshLocationAvailability()`。`RecordingPhase.recording`のときだけ強制停止する
- `onError`だけでは足りない。設定アプリで権限・サービスを変えるには一度アプリをバックグラウンドに回すので、多くの場合`onError`は
  発火しない。実際の主な検知の経路はフォアグラウンド復帰時の確認

## バナーの表示

- 全タブ共通のバナーは、`main_page.dart`の`body`の上部に、収録状態(`RecordingPhaseBannerView`)・位置情報(`LocationBannerView`)・
  認証(`AuthBannerView`)の順に並べる。どれも出ていないときは高さ0
- ステータスバーの分の上端の余白は、バナーが1つでも出ているときだけ、バナーの上に`Padding`で1回だけ取る。その下のタブ(各`AppBar`)は
  自分でも同じ分の余白を取ってしまうので、`MediaQuery.removePadding(removeTop: hasAnyBanner)`で消費済みにする
  (`frontend/docs/overview.md`の「レイアウト」)

## GPSのヘルプ

- GPSを掴みやすくするコツは`views/gps_help_page.dart`にまとめ、「未取得・更新停止」の位置情報バナーと、開始できなかったときのエラーダイアログの
  両方から`widgets/gps_help_link.dart`の`GpsHelpLinkButton`(「取得のコツ」)で開く
