# E2E/画面確認テスト (integration_test + flutter drive)

`integration_test/`のシナリオの書き方と注意点。実行方法とログの読み方は
`docs/development.md`の「テスト」を参照(AIコーディングエージェントを使う場合の分担は、同じ文書の
「AIコーディングエージェントを使った開発」)。

## スクリーンショットの仕組み

- `test_driver/integration_test.dart`が`onScreenshot`コールバックでPNGを
  `integration_test_screenshots/<name>.png`に書き出す。シナリオ側は
  `IntegrationTestWidgetsFlutterBinding.convertFlutterSurfaceToImage()`→
  `takeScreenshot('name')`の順で呼ぶ(Android実機/エミュレータでは
  `convertFlutterSurfaceToImage`が必須。iOSでは無視されるが呼んでおいて問題ない)
- `integration_test_screenshots/`は毎回上書きされる一時成果物なので`.gitignore`
  済み、コミット対象にしない

## 書き方の注意

- **`pumpAndSettle()`は`flutter_map`のタイル読み込み(ネットワーク経由)の完了を待たない**
  (アニメーション/再描画フレームが収まるのを待つだけで、任意のFuture/HTTP完了は
  対象外のため)。地図が写るシーンでスクリーンショットを撮る前は、`pumpAndSettle()`に
  加えて`tester.pump(const Duration(seconds: 3))`等の実時間待機を挟むこと(実例:
  `integration_test/app_test.dart`)。挟まずに撮ると、タイルが揃う前の一部グレーの
  地図が写り込む
- 上記の実時間待機を挟むと、`flutter drive`実行時に
  `VMServiceFlutterDriver: request_data message is taking a long time to complete...`
  という警告が出ることがあるが、これは想定通りの待機時間に対する定型の進捗ログであり、
  テスト失敗ではないので無視してよい
- **`integration_test`は(モックではなく)実機/シミュレータの本物の`app.sqlite`に対して動く**。
  テスト用データを`AppDatabase`へ直接seedするシナリオで「保存」を伴う場合、
  `addTearDown`等で確実にそのセッションを後始末すること(discardフロー経由 or 明示的な物理削除)。
  忘れると実機の履歴データが汚染され、backendが生きている環境ではリモートDBにもpushされてしまう。
  実際に後始末を忘れて実機の履歴一覧にテスト用の偽セッションが残ったことがある(残ってしまった
  場合はアプリの履歴タブの編集モードから手動で削除するしかない)
- 同一テストプロセス内で`AppDatabase()`を複数回生成すると(`app.main()`実行後にseed用の
  `AppDatabase()`を追加で作る等)、Driftが
  `WARNING: It looks like you've created the database class AppDatabase multiple times`
  という警告を出す。debugビルドのみの警告で今のところテスト失敗には至っていないが、
  今後flakyになるようならテスト間でのDB接続の`close()`を検討すること

## 位置情報の注入

- iOSシミュレータの位置情報操作(Xcodeの`Features > Location`、`xcrun simctl location`)は
  macOS専用の機能。AIコーディングエージェントのコンテナ(Linux)には`xcrun`/`simctl`が無いので、
  エージェントはスクリプトやGPXファイルの作成までを行い、実行(位置の注入)は開発者がホストで行う
- Androidエミュレータは Extended controls の Routes で移動をシミュレートできる

## 機能紹介用のスクリーンショット

`integration_test/showcase_test.dart`は、README等で機能を紹介するためのスクリーンショットを撮るシナリオ
(テストではない)。DBはメモリ上のもの(`AppDatabase.forTesting`)に差し替えてダミーデータを入れ、
ローカルアカウント「デモ」で入るので、端末の本物の`app.sqlite`・secure storageには触れず、同期も走らない。

撮る画面(ファイル名は`integration_test_screenshots/`・`host_check_logs/.../screenshots/`に出る):

| ファイル | 画面 |
|---|---|
| `01_login` | ログイン(メールアドレス・パスワードを入力した状態) |
| (02) | 収録中。GPSが動いている必要があるので、このシナリオでは撮らず手動で撮る |
| `03a_save_or_discard`・`03b_save_dialog` | 収録停止後の保存/破棄、保存の確認ダイアログ(日比谷公園の散歩) |
| `04_history` | 履歴の一覧(約100日分のダミーの記録) |
| `05a_detail_route`・`05b_detail_points`・`05c_detail_elevation` | 詳細(皇居外周ラン)のルート表示・全ピン表示・高度プロファイル |
| `06a_analytics_month`・`06b_analytics_year`・`06c_analytics_all` | 統計の月・年・全期間。月は、月の前半に撮ると先月を出す。年は棒グラフを右端までスクロールして撮る |

実行の手順(iOSシミュレータ):

1. 実行中はシミュレータの位置を動かしておく。止まっていると10秒で「位置情報の更新が止まっています」の
   バナーが全タブに出る(出た場合はflutter driveのログに`[showcase] 警告`が出る)。皇居外周を走る経路の例:

   ```bash
   xcrun simctl location booted start --speed=3 --interval=1 \
     35.6773,139.7528 35.6790,139.7560 35.6838,139.7611 35.6870,139.7620 35.6905,139.7585 \
     35.6910,139.7530 35.6890,139.7470 35.6840,139.7445 35.6790,139.7465 35.6765,139.7500 35.6773,139.7528
   ```

   1周(約4.9km)で約27分かかり、終点で止まる。収録中の画面を手動で撮るときも同じ経路を使うと、
   詳細画面(皇居外周ラン)と見た目がそろう。止めるときは`xcrun simctl location booted clear`
2. `scripts/run_checks.sh <run_id> e2e -e integration_test/showcase_test.dart`

ダミーデータは乱数の種を固定して実行日から100日前までに作るので、同じ日に実行すれば同じ内容になる。
自宅周辺などの実際の記録が写らないよう、経路は公共の場所(皇居外周・日比谷公園)にしている。
