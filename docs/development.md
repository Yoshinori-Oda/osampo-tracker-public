# 開発ガイド

開発環境・ディレクトリ構成・テスト・git運用など、このリポジトリで開発するために必要なことをまとめる。
システムの全体像は`docs/basic-design/system-overview.md`を参照。

## 開発環境 (コンテナ/ホストの役割分担)

- コーディングエージェント(Claude Code)は、ホストのファイルや他の業務に触れないよう、権限と外部への通信を制限した
  devcontainerの中で動かしている。devcontainerにはFlutter SDKもDockerデーモンも入れない
- 解析・テスト・コード生成・ビルド・実機/シミュレータ操作、backendの`docker compose`は、すべてホスト側で行う
- **テストを軸に開発を進める**。コンテナの中では実行による動作確認ができないため:
  - 実装と一緒に、その変更を検証するテスト(`test/`配下のユニット/ウィジェットテスト、画面確認が必要なら
    `integration_test/`のシナリオ、backendはpytest)を書く
  - ホスト側で`frontend/scripts/run_checks.sh`(backendは`backend/scripts/run_checks.sh`)を実行する
  - 結果はファイル(`host_check_logs/`)に残るので、コンテナ側からは出力を貼り付けてもらわなくても`SUMMARY.md`・各ログ・
    スクリーンショットを読んで修正できる
- Driftの`*.g.dart`などコード生成物もホスト側の`build_runner`で更新する(`run_checks.sh <run_id> codegen`)
- push・PRごとに、E2E以外のチェック(backendのlint・マイグレーション・pytest、frontendのコード生成物の確認・analyze・test)を
  GitHub ActionsのCIで実行する(下記「CI」)。ホストの`run_checks.sh`は、E2E・画面の確認、コミットするファイルを作る処理
  (`codegen`・`lock`)、push前に手元で確かめたいときに使う

## ディレクトリ構成

- .github: GitHub Actionsのワークフロー(`workflows/ci.yml`)とDependabotの設定(`dependabot.yml`)。下記「CI」
- backend: Dockerで動かすバックエンド(FastAPIのapi + 定期実行のworker + PostgreSQL)
  - app/: FastAPIのアプリ本体(config.py: 設定、db.py: DB接続、main.py: アプリ、worker.py: 定期実行、
    logging_config.py・request_context.py: ログの形式とリクエストID・アクセスログ、security.py: パスワードのハッシュ・トークン、
    mail.py: SMTPでのメールの送信、cli.py: 管理用のコマンド(シード・アカウントの停止・テストメール)、
    routers/・schemas/・services/・models/: レイヤ。詳細は`backend/docs/バックエンド構成.md`)
  - tests/: pytest
  - pyproject.toml・uv.lock: 依存パッケージ(uv)。Dockerfile: api・worker共通のイメージ
  - alembic.ini・migrations/: Alembicのマイグレーション。0001は旧initdb.sqlのスキーマ(とPostgREST用のストアドファンクション)を
    そのまま写したもの、0002は高度関連の3列のdouble precision化、0003はPostgRESTの削除(ストアドファンクションの削除と
    deleted_atの「削除した日時」への統一)、0004は認証、0005はメールのoutbox、0006はメールアドレスの確認コード、0007は監査ログ、
    0008は監査ログのリクエストID、0009はRLSとworker用のロールの権限
  - db/init/: DBコンテナの初回起動時に実行するスクリプト(ロール(migrator・api・worker)・テスト用データベース・拡張機能・権限)
  - db/seed.sql: 開発用のダミーデータ(テストユーザー`1111...`とセッション)
  - docker-compose.yml: db / api / worker / mailpit。DBの接続情報は`backend/.env`(コミットしない)。
    メールはapiがoutboxに積み、workerがmailpitへ送る(届いたメールは http://localhost:8025 で見る)
  - docs/: API設計・バックエンド構成の詳細設計(下記「ドキュメント索引」)
- docs: 基本設計・詳細設計・テスト・落とし穴(下記「ドキュメント索引」)
- frontend: Flutterによるモバイルアプリ本体(`flutter create`の出力から開発)
  - docs/: ユーザー機能追加に伴うfrontendの変更内容(下記「ドキュメント索引」)
  - lib/
    - auth/: 認証(ログイン・トークンの更新・ログアウト・アカウントの削除)、トークンのsecure storageへの保存、
      アクセストークンを付けるHTTPクライアント(authorized_client.dart)
    - database/: Drift定義(ローカルSQLite)。ログインしたユーザー(users)ごとにデータを分ける
    - repositories/: リモート同期ロジック(push/pull/競合解決)
    - services/: tracking_service.dart(位置情報監視・収録の状態管理の中心)、
      location_stream_settings.dart(位置情報ストリームのプラットフォーム別設定)
    - models/: RecordingSession/Status/MoveMethod、RecordingPhase(収録の状態遷移)、
      LocationBannerState/LocationBannerKind(位置情報バナーの状態)
    - providers/: Riverpodのprovider定義
    - views/: 画面(main_page / recording_page / saved_sessions / session_detail_view /
      save_or_discard_page / gps_help_page / settings_page、auth/のログイン・新規登録 など)。
      起動時の画面は`main.dart`のAuthGate(未ログインならログイン画面)
    - widgets/: 全タブ共通のバナー(location_banner_view / recording_phase_banner_view /
      auth_banner_view)、地図に重ねるOpenStreetMapのクレジット(osm_attribution)など
    - utils/: navigatorKeyやダイアログ等、UI外から呼ぶための小物。save_or_discard_screen.dartは
      保存/破棄画面を開く共通の入口`showSaveOrDiscardScreen()`。map_tiles.dartは地図タイルのURLとUser-Agentの設定
  - android/, ios/: 各OSの端末設定
  - test/: ユニット/ウィジェットテスト
  - integration_test/: `flutter drive`によるE2Eシナリオ(スクリーンショット取得含む)
  - test_driver/: `flutter drive`のドライバ(スクリーンショットをホストのファイルとして保存する)
  - scripts/: run_checks.sh(ホスト側で解析・テスト等を実行し結果を`host_check_logs/`へ保存)と、
    そのe2eステップだけを呼ぶrun_e2e_tests.sh

## ドキュメント索引

毎回読む必要はないが、**該当箇所を変更する前には読むこと**。設計を変えたら同じ変更で該当ドキュメントも更新する。

| ドキュメント | 内容 | 読むタイミング |
| --- | --- | --- |
| `docs/basic-design/` | 基本設計書(システム概要・機能一覧・画面一覧と遷移・データ設計・API一覧・認証とセキュリティ)。全体像と一覧に徹し、詳細は下記の各文書へリンクする | 全体像を掴む、機能・画面・テーブル・APIを追加/削除する(該当の一覧も更新する) |
| `docs/design/sync.md` | pull型差分同期、tombstone削除、削除と編集の競合 | `repositories/`・`backend/`を触る |
| `docs/design/location-tracking.md` | RecordingPhase、timeLimit、位置情報バナー、収録開始のフォールバック、権限喪失時の強制停止 | `tracking_service.dart`・バナー・`main_page`/`recording_page`を触る |
| `docs/design/background-recording.md` | バックグラウンドでの収録継続と非収録時の購読停止 | 位置情報の購読設定・ライフサイクル・権限・マニフェストを触る |
| `docs/design/session-recovery.md` | 起動時の未完了セッション回収、保存/破棄画面 | 収録停止〜保存/破棄の流れを触る |
| `docs/design/screens.md` | 各画面・バナー・utilsの個別仕様(編集ダイアログの挙動等) | `views/`・`widgets/`・`utils/`を触る |
| `docs/testing/e2e.md` | integration_testの書き方・スクリーンショット・実DBの後始末 | `integration_test/`を書く・直す |
| `docs/pitfalls.md` | 下記「既知の落とし穴」の症状・原因の詳細 | 該当箇所を触る、似た不具合を調べる |
| `backend/docs/API設計ドラフト.md` | APIサーバー(FastAPI)のエンドポイント・エラー形式・認証と権限 | APIを実装する、APIの仕様を変える |
| `backend/docs/バックエンド構成.md` | 構成の選定理由・主な決定事項と、実装方針・マイグレーション・DBロール・パージ・テストの詳細設計 | `backend/`を触る |
| `backend/docs/メール送信の運用.md` | メールをサーバーから送って運用するための論点(送信手段・到達性・バウンス・outbox・悪用対策・テスト)の整理 | メール送信の設計・実装をする |
| `frontend/docs/ユーザー機能追加に伴う変更予定.md` | APIに合わせてfrontendで必要になる変更 | `repositories/`・認証・アカウントまわりを触る |

## 開発ルール

### コーディング規約

- 現状はlinterは未導入(frontend)。backendはruffの既定のルール
- Dartのインデントは2文字、SQLのインデントは4文字で行い、Dartではリスト項目の末尾にも`,`を入れる
- 端末のログは`utils/app_log.dart`の`appLog`で出す(`print`は使わない)

### テスト

- 標準の`flutter_test`(`test/`配下)以外のテストフレームワーク・モックライブラリは未導入
- **ホスト側での実行はすべて`scripts/run_checks.sh <run_id> [step...]`で行う**(frontendで実行)。
  stepは`pubget`/`codegen`/`analyze`/`test`/`e2e`/`all`(=analyze test e2e)で、省略時は
  `analyze test`。指定順に関わらずpubget→codegen→analyze→test→e2eの順に1回ずつ実行し、
  途中で失敗しても残りのstepは実行する。`test`は`-t <path>`(複数可)で対象を絞れる
  (省略すると`test/`配下を全件実行する)。`analyze`は`--no-fatal-infos`で
  実行するためinfoだけではFAILEDにならないが、指摘は全件記録する
- 結果は`frontend/host_check_logs/<timestamp>_<run_id>_<PASSED|FAILED>/`に保存される(`.gitignore`済み):
  - `SUMMARY.md`: 実行環境(ブランチ/コミット/未コミット変更の有無/ホストのFlutterバージョン)、
    stepごとの結果・終了コード・所要時間、analyzeの指摘一覧、testの失敗テスト名、
    失敗したstepのログ末尾。**まずこれを読む**
  - `<step>.log`: 各stepの出力全文
  - `screenshots/`: e2eのスクリーンショットのコピー(実行ごとに残るので前回との比較にも使える)
- `run_id`はテスト内容の説明ではなく、**実行の依頼ごとに変わる相関トークン**(どの依頼に対応する実行結果かを
  特定するためのもの)。再実行するときも新しいrun_idにする
- E2E/画面確認は`integration_test` + `flutter drive`で行う。E2Eだけなら
  `scripts/run_e2e_tests.sh <run_id>`でもよい(`run_checks.sh <run_id> e2e`のラッパー)。
  デバイスの決定順は`-d <device_id>` > `E2E_DEVICE_ID`環境変数 > `run_checks.sh`冒頭の
  `DEFAULT_DEVICE_ID`。シナリオは`-e <path>`で変えられる(省略時は`integration_test/app_test.dart`。
  機能紹介用のスクリーンショットは`integration_test/showcase_test.dart`)。シナリオの書き方は`docs/testing/e2e.md`
- `integration_test`は実機/シミュレータの本物の`app.sqlite`に対して動く。**seedして保存した
  セッションは必ず`addTearDown`等で後始末すること**(実機の履歴・リモートDBが汚染される)
- **backendのホスト側での実行は`backend/scripts/run_checks.sh <run_id> [step...]`で行う**(どこから実行してもよい)。
  frontend版と同じ形で、run_idの扱い・step順の固定・途中で失敗しても残りを実行するのも同じ。stepは
  `lock`(uv lock)/`up`(docker compose up -d --build)/`migrate`(開発用・テスト用DBへのalembic upgrade head)/`check`(alembic check)/
  `lint`(ruff check)/`test`(pytest。`-t`で絞れる)/`all`(=up migrate check lint test)で、省略時は`migrate check lint test`。
  - 依存パッケージを変えたら`lock up`、Dockerfile・compose・`pyproject.toml`・`alembic.ini`を変えたら`up`も付けて実行する
    (`app/`・`tests/`・`migrations/`以外はbind mountしていないので、イメージの作り直しが必要)
  - 結果は`backend/host_check_logs/<timestamp>_<run_id>_<PASSED|FAILED>/`に保存される(`.gitignore`済み)。
    `SUMMARY.md`(実行環境、stepごとの結果、適用したマイグレーションとrevision、alembic checkの結果、ruffの指摘、
    pytestの失敗一覧と詳細、失敗したstepのログ末尾)をまず読む
  - 前提: `backend/.env`があり、`up`以外のstepはサービスが起動済みであること

### CI

- `.github/workflows/ci.yml`。mainへのpush・PR・手動実行(Actionsのタブ)で、`backend`と`frontend`の2つのジョブを並列に実行する。
  mainへはPR経由でしか入れず、2つのジョブが通らないとマージできない(GitHubのルールセットで設定)
  - `backend`: PostGISのサービスコンテナを起動し、composeと同じ`db/init/20_roles_and_databases.sh`をコンテナの中で実行して
    ロール・テスト用データベースを作る。ランナー上のuv(Python 3.12)で`uv sync --locked` → `ruff check` →
    `alembic upgrade head`(開発用・テスト用) → `alembic check` → `pytest`。APIはpytestの中でアプリを直接呼び、workerはジョブの関数を
    直接呼ぶので、api・worker・mailpitのコンテナは起動しない(Dockerfileでのビルドと起動は確かめていない)
  - `frontend`: Flutterのバージョンはホストと同じ値に固定する(ホストのFlutterを上げたら、`ci.yml`の`flutter-version`も同じPRで上げる)。
    `flutter pub get --enforce-lockfile` → `build_runner`を実行してコミット済みの生成物と差分が無いかの確認 →
    `flutter analyze --no-fatal-infos` → `flutter test`
- `uv sync --locked`・`pub get --enforce-lockfile`は、lockファイルが`pyproject.toml`・`pubspec.yaml`と食い違っていると失敗する。
  依存パッケージを変えたら、ホストで`lock`(backend)・`pubget`(frontend)を実行してlockファイルもコミットする
- 生成物の確認で失敗したら、ホストで`run_checks.sh <run_id> codegen`を実行して生成物をコミットする
- CIのDBの接続情報は使い捨てのダミーの値で、`ci.yml`に直接書いている(秘密情報ではない)
- アクションはタグではなくコミットのSHAで固定する(タグは付け替えられるため)。更新は`.github/dependabot.yml`の
  バージョン更新(月1回、アクション・uv・pubの種類ごとに1つのPR)で行い、CIが通ればマージする

### git

- 作業はブランチを切って行い、並行する作業はgit worktree(`.claude/worktrees/<作業名>/`。`.gitignore`済み)で分ける。
  worktreeごとに依存・生成物が別になるため、作った直後に`run_checks.sh <run_id> pubget`(テーブル定義を
  変えた場合は`codegen`も)を実行する。backendの`docker compose`はディレクトリ名から
  同じプロジェクト名(`backend`)になるので、メインのチェックアウトとworktreeで同時に起動しない
- commitメッセージはConventional Commitsに従う
- 1PR1目的を基本とし、無関係な変更を混在させない
- mainへの直接のpushは禁止。ブランチをpushしてPRを作り、CIが通ってからマージする。CIで見つかった問題は同じブランチに
  修正のコミットを足して直す
- マージはmerge commit(`gh pr merge --merge`)を基本とし、PRの中の個々のコミットを残す。squash・rebaseも設定上は許可している。
  PR単位の履歴は`git log --first-parent main`で見る
- `frontend/pubspec.lock`はコミット対象(Flutterはアプリについてはlockをコミットするのが公式推奨)。
  `flutter analyze`等の実行で無関係な依存バージョンの差分が紛れ込むことがあるので、
  意図しない変更はコミット前に`git checkout`で戻す

## 既知の落とし穴

守るべきルールの要点のみ。症状・原因・見分け方は`docs/pitfalls.md`を参照。

- `last_synced_at`はGETのレスポンスの`synced_at`をそのまま保存・送信する(端末で日時を組み立て直さない)
- `TrackingRepository`のコンストラクタは開発中、毎回`last_synced_at`をクリアする
  (`_clearLastSyncedAtForTest`)。本番相当の挙動を確認する場合は外す
- 同期APIの404は`code`が`session_not_found`のときだけ「サーバーにそのセッションが無い」として扱う
  (`code`の無い404・`user_not_found`では同期を止め、ローカルのデータに触れない)
- `TrackingRepository.updateSession()`はpush用の内部メソッド。ローカル編集用は`updateSessionInfo()`
  のように別名にする(同名だと`duplicate_definition`)
- `Geolocator.getCurrentPosition`は必ず`LocationSettings(timeLimit: ...)`付きで呼ぶ(無期限だとハングする)
- flutter_mapで初期表示時にboundsへフィットさせるときは、後から`fitCamera()`/`move()`を呼ばず
  `MapOptions.initialCameraFit`を使い、`CameraFit.bounds`には`maxZoom`を付ける(タイルがグレーのままになる)
- 地図の`TileLayer`は`utils/map_tiles.dart`の定数を使う。`userAgentPackageName`を`com.example.*`のような汎用の値にしたり
  省略したりすると、OpenStreetMapのタイルサーバーに拒否されて地図が表示されない。地図のクレジットは`widgets/osm_attribution.dart`の
  `OsmAttribution`を使う(flutter_mapの`SimpleAttributionWidget`を直接置くと、内部の`SafeArea`で画面下端の安全領域の分だけ浮く)
- 上部に出し入れするバナーと`AppBar`の二重のステータスバー余白は`MediaQuery.removePadding`で揃える
- ホストとdevcontainerでVSCodeを同時に開く場合、`"dart.runPubGetOnPubspecChanges": "never"`が
  効いているか確認する(`.dart_tool/package_config.json`の取り合い)
- mainとworktreeの`backend`はcomposeのプロジェクト名(`backend`)・DBのボリュームを共有する。ユーザーの登録し直しは不要だが、
  古いコンテナが残ると`secrets/`のマウントが反映されずログインだけが500になる。おかしいときは`down`→`up`し直す
- シミュレータのアプリだけがAPIに繋がらない(タイムアウトし、APIのログにも届かない)ときは、Macの`127.0.0.1:8080`を
  Docker以外(VSCodeのプロセス等)が待ち受けていないか`lsof -nP -iTCP:8080 -sTCP:LISTEN`で確認する
- Driftのクエリで`&`・`|`を使うファイルでは`package:drift/drift.dart`をimportする。`flutter_secure_storage`は11系を使う
  (9系は`geolocator`とwin32が衝突する)

## デバッグ Tips

- 端末のログは`appLog`の`[sync] ...`・`[auth] ...`・`[http] ...`の行で見る(リリースビルドでは出さない)。
  通信は`[http]`の行にリクエストID(`X-Request-ID`)が出るので、backendのログ(`docker compose logs api | grep <ID>`)と突き合わせられる
- backendのログは`docker compose logs api`・`docker compose logs worker`で見る(key=value。`LOG_FORMAT=json`でJSON)。
  3つのログ(アクセス・アプリ・監査)の役割は`backend/docs/バックエンド構成.md`の「ログ」
- 複数端末での同期テストは、複数のシミュレータ/実機で同じユーザー(`app.cli seed-dev`のテストユーザー
  `testuser@example.com`等)にログインして行う。同期はメールアドレスが確認済みのユーザーでしか行われない

## よく使うコマンド

backendの`docker compose`も含め、以下はすべてホスト側で実行する。

```bash
# 起動(同期先は既定でhttp://localhost:8080/api。実機・Androidエミュレータからはlocalhostに届かないので切り替える)
flutter run
flutter run --dart-define=API_BASE_URL=http://<ホストのIP>:8080/api

# 以下はfrontendディレクトリで実行し、結果はhost_check_logs/<timestamp>_<run_id>_<結果>/に残る
# 静的解析 + ユニット/ウィジェットテスト(既定)
scripts/run_checks.sh <run_id>
# テスト対象を絞る
scripts/run_checks.sh <run_id> analyze test -t test/xxx_test.dart
# ローカルDB設定更新(build_runner)を含める / worktree作成直後はpubgetも
scripts/run_checks.sh <run_id> pubget codegen analyze test
# E2Eまで全部(ホスト側でシミュレータ/実機起動後に実行)
scripts/run_checks.sh <run_id> all
# E2Eのみ(デバイスを既定と変える場合のみ -d)
scripts/run_e2e_tests.sh <run_id> -d <device_id>

# 以下はbackendディレクトリで実行し、結果はbackend/host_check_logs/<timestamp>_<run_id>_<結果>/に残る
# (事前にbackend/.envが必要: backend/docs/バックエンド構成.md)
# マイグレーション + スキーマの差分確認 + lint + テスト(既定。サービスは起動済みの前提)
scripts/run_checks.sh <run_id>
# 起動(イメージの作り直し)から全部
scripts/run_checks.sh <run_id> all
# 依存パッケージを変えた場合
scripts/run_checks.sh <run_id> lock up migrate check lint test
# テスト対象を絞る
scripts/run_checks.sh <run_id> test -t tests/test_models.py

# DBのボリュームを作り直した後は、マイグレーションの後に開発用のダミーデータを入れる(テーブルの所有者のロールで実行する)
docker compose down -v
scripts/run_checks.sh <run_id> up migrate
docker compose exec -T db psql -U osampo_migrator -d location_db < db/seed.sql
# 開発用のユーザー(管理者・テストユーザー1111...・メール未確認のユーザー)のパスワード等を設定する。ログイン情報が表示される
docker compose run --rm api python -m app.cli seed-dev

# アクセストークンを署名するES256の鍵のペアを作る(初回のみ。backend/secrets/はコミットしない)
mkdir -p secrets
openssl ecparam -name prime256v1 -genkey -noout -out secrets/jwt_private.pem
openssl ec -in secrets/jwt_private.pem -pubout -out secrets/jwt_public.pem
# アカウントの停止・解除(管理者の画面ができるまでの手段)
docker compose run --rm api python -m app.cli disable-user <email>
docker compose run --rm api python -m app.cli enable-user <email>
# テストメールをoutboxに積む(workerが数秒以内にmailpitへ送る。http://localhost:8025 で確認)
docker compose run --rm api python -m app.cli send-test-mail test@example.com
```
