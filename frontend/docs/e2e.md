# E2Eテスト(integration_test + flutter drive)

`frontend/integration_test/`のシナリオの書き方と注意点。2026-11-10時点のmainの実装を正とする。実行方法と結果(`host_check_logs/`)の読み方は
`docs/development.md`の「テスト」、AIコーディングエージェントを使う場合の分担は同じ文書の「AIコーディングエージェントを使った開発」。

## シナリオ

| ファイル | 内容 |
|---|---|
| `integration_test/app_test.dart` | 既定のシナリオ(`run_checks.sh <run_id> e2e`)。起動・未完了の収録の回収・保存/破棄など |
| `integration_test/showcase_test.dart` | README等で機能を紹介するためのスクリーンショットを撮る(テストではない。下記「機能紹介用のスクリーンショット」) |

## スクリーンショットの仕組み

- `test_driver/integration_test.dart`の`onScreenshot`で、PNGを`integration_test_screenshots/<name>.png`に書き出す。このディレクトリは毎回上書きされる
  一時的なものなので`.gitignore`済み。`run_checks.sh`は実行のたびに`host_check_logs/.../screenshots/`へコピーする
- シナリオでは、`binding.convertFlutterSurfaceToImage()` → `tester.pumpAndSettle()` → `binding.takeScreenshot('name')`の順に呼ぶ
  (`binding`は`IntegrationTestWidgetsFlutterBinding.ensureInitialized()`の戻り値)。`convertFlutterSurfaceToImage`はAndroidで必須で、
  iOSでも呼んでおいて問題ない。`showcase_test.dart`ではこの3つを`_capture`にまとめている

## 書き方の注意

- **`pumpAndSettle()`は`flutter_map`のタイルの読み込み(ネットワーク)の完了を待たない**(アニメーション・再描画が収まるのを待つだけ)。
  地図が写る画面を撮る前は、実時間の待ちを挟む(`app_test.dart`の`_waitForMapTiles`は3秒、`showcase_test.dart`は4秒)。
  挟まずに撮ると、タイルがそろう前の一部がグレーの地図が写る
- 実時間の待ちを挟むと、`flutter drive`が`VMServiceFlutterDriver: request_data message is taking a long time to complete...`という警告を
  出すことがある。待ち時間に対する定型の進捗のログで、テストの失敗ではない
- **シナリオは、実機・シミュレータの本物の`app.sqlite`に対して動く**。DBに直接入れた(seedした)記録は、保存/破棄のどちらに転んでも
  (アサーションの失敗で途中で止まっても)残らないよう、`addTearDown`で消す(`app_test.dart`の`_purgeSeededSession`)。残ってしまったら、
  アプリの履歴タブの編集モードから削除する
- `app_test.dart`は、ログインした状態を`_SignedInAuthStorage`(偽のトークン)で作り、端末のsecure storageには触れない。トークンが偽物なので、
  同期は401になって再ログインのバナーが出るが、画面の操作には影響しない(サーバーには何も送られない)
- 同じテストのプロセスの中で`AppDatabase()`を複数回作ると(`app.main()`で作られた後に、seed用に`AppDatabase()`を作る等)、Driftが
  `WARNING: It looks like you've created the database class AppDatabase multiple times`という警告を出す。debugビルドだけの警告で、テストは失敗しない

## 位置情報の注入

- iOSシミュレータの位置は、Xcodeの`Features > Location`か`xcrun simctl location`で動かす(macOSだけの機能)
- Androidエミュレータ・実機は、APIへの接続(証明書を信頼させる対応)ができていないので、今はE2Eに使わない(`docs/development.md`の「起動方法」)

## 機能紹介用のスクリーンショット

`integration_test/showcase_test.dart`は、DBをメモリ上のもの(`AppDatabase.forTesting`)に差し替えてダミーデータを入れ、ローカルアカウント「デモ」で入る。
端末の本物の`app.sqlite`・secure storageには触れず、同期も走らない。

撮る画面(ファイル名は`integration_test_screenshots/`・`host_check_logs/.../screenshots/`に出る):

| ファイル | 画面 |
|---|---|
| `01_login` | ログイン(メールアドレス・パスワードを入力した状態) |
| (02) | 収録中。GPSが動いている必要があるので、このシナリオでは撮らず手動で撮る |
| `03a_save_or_discard`・`03b_save_dialog` | 収録の停止後の保存/破棄、保存の確認ダイアログ(日比谷公園の散歩) |
| `04_history` | 履歴の一覧(約100日分のダミーの記録) |
| `05a_detail_route`・`05b_detail_points`・`05c_detail_elevation` | 詳細(皇居外周ラン)のルートの表示・全ピンの表示・高度のグラフ |
| `06a_analytics_month`・`06b_analytics_year`・`06c_analytics_all` | 統計の月・年・全期間。月は、月の前半(15日より前)に撮ると先月を出す。年は棒グラフを右端までスクロールして撮る |

実行の手順(iOSシミュレータ):

1. 実行中はシミュレータの位置を動かしておく。止まっていると10秒で「位置情報の更新が◯◯から止まっています。」のバナーが全タブに出る
   (出た場合は`flutter drive`のログに`[showcase] 警告`が出る)。皇居外周を走る経路の例:

   ```bash
   xcrun simctl location booted start --speed=3 --interval=1 \
     35.6773,139.7528 35.6790,139.7560 35.6838,139.7611 35.6870,139.7620 35.6905,139.7585 \
     35.6910,139.7530 35.6890,139.7470 35.6840,139.7445 35.6790,139.7465 35.6765,139.7500 35.6773,139.7528
   ```

   1周(約4.9km)で約27分かかり、終点で止まる。収録中の画面を手動で撮るときも同じ経路を使うと、詳細画面(皇居外周ラン)と見た目がそろう。
   止めるときは`xcrun simctl location booted clear`
2. `scripts/run_checks.sh <run_id> e2e -e integration_test/showcase_test.dart`

ダミーデータは乱数の種を固定して実行日から100日前までに作るので、同じ日に実行すれば同じ内容になる。
実際の自宅周辺などの記録が写らないよう、経路は公共の場所(皇居外周・日比谷公園)にしている。
