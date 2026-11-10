# 開発ガイド

開発の流れ・開発環境・ディレクトリ構成・テスト・CI・git運用など、このリポジトリで開発するために必要なことをまとめる。
システムの全体像は`docs/basic-design/system-overview.md`を参照。

## 開発の流れ

```mermaid
flowchart TD
    branch["mainからブランチを切る<br/>(並行する作業はgit worktreeで分ける)"]
    impl["実装と、その変更を検証するテストを書く<br/>(設計を変えたら同じ変更で設計書も更新する)"]
    local["ローカルで確かめる<br/>frontend/backendのscripts/run_checks.sh"]
    push["commitしてブランチをpushし、PRを作る"]
    ci["CI (GitHub Actions)<br/>backend・frontendのジョブを並列に実行"]
    merge["mainにマージ<br/>(merge commit)"]
    bot["Dependabot<br/>(月1回、依存の更新のPR)"]

    branch --> impl --> local
    local -->|失敗| impl
    local -->|通過| push --> ci
    ci -->|失敗: 同じブランチに修正を足す| impl
    ci -->|2つのジョブが通過| merge
    bot --> ci
```

- **テストを軸に進める**。実装と一緒に、その変更を検証するテスト(`test/`配下のユニット/ウィジェットテスト、画面の確認が必要なら
  `integration_test/`のシナリオ、backendはpytest)を書く
- ローカルの確認は`scripts/run_checks.sh`で行い、結果はファイル(`host_check_logs/`)に残る(下記「テスト」)。
  E2E・画面の確認と、コミットするファイルを作る処理(コード生成の`codegen`、依存の固定の`lock`)はローカルでしかできない。
  それ以外のチェックはCIでも実行するので、ローカルではpushの前に確かめたいときに使う
- push・PRごとに、E2E以外のチェック(backendのlint・マイグレーション・pytest、frontendのコード生成物の確認・analyze・test)を
  CIで実行し、通ったものだけをmainにマージする(下記「CI」「git」)

## 開発環境

開発者のPCに次のものを入れる。backendの依存パッケージ(Python・uv)はDockerのイメージの中にあるので、PCには要らない。

- Flutter SDK(CIと同じバージョン。`.github/workflows/ci.yml`の`flutter-version`)と、iOSシミュレータのためのXcode
- Docker(`docker compose`)。backendの起動・マイグレーション・テストはすべてcompose経由で行う
- mkcert・openssl・curl(HTTPSの証明書の作成と確認。下記「よく使うコマンド」)

初回は`backend/.env`(項目は`backend/docs/バックエンド構成.md`の「設定と秘密情報」)と`backend/secrets/`(JWTの署名鍵・TLSの証明書)を
用意する。いずれもコミットしない。

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
  - proxy/: リバースプロキシ(nginx)の設定。TLSを終端してHTTPSで公開し、`/api/`だけをapiへ転送する
  - docker-compose.yml: proxy / db / api / worker / mailpit。DBの接続情報は`backend/.env`(コミットしない)。
    メールはapiがoutboxに積み、workerがmailpitへ送る(届いたメールは http://localhost:8025 で見る)。起動の順番は下記「backendの起動」
  - scripts/: run_checks.sh(マイグレーション・lint・テスト等をcompose経由で実行し、結果を`host_check_logs/`へ保存)
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
  - test_driver/: `flutter drive`のドライバ(スクリーンショットをファイルとして保存する)
  - scripts/: run_checks.sh(解析・テスト等を実行し結果を`host_check_logs/`へ保存)と、
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
| `backend/docs/HTTPSとリバースプロキシ.md` | リバースプロキシ(nginx)・証明書(mkcert)・TLSの設定・送信元のIPとリクエストID・流量などの上限 | `backend/proxy/`・composeのポート・証明書・接続先のURLを触る |
| `backend/docs/メール送信の運用.md` | メールをサーバーから送って運用するための論点(送信手段・到達性・バウンス・outbox・悪用対策・テスト)の整理 | メール送信の設計・実装をする |
| `frontend/docs/ユーザー機能追加に伴う変更予定.md` | APIに合わせてfrontendで必要になる変更 | `repositories/`・認証・アカウントまわりを触る |

## backendの起動 (docker compose)

`docker compose up`(`backend/scripts/run_checks.sh`の`up`)で起動する。各サービスは、矢印の元のサービスが
矢印のラベルの状態になってから起動する(`depends_on`)。

```mermaid
flowchart LR
    db[("db<br/>PostgreSQL / PostGIS<br/>127.0.0.1:5432")]
    mailpit["mailpit<br/>開発用のSMTP<br/>127.0.0.1:8025"]
    api["api<br/>FastAPI (uvicorn)"]
    worker["worker<br/>定期実行<br/>(メール送信・パージ)"]
    proxy["proxy<br/>nginx<br/>127.0.0.1:443"]

    db -->|healthy| api
    db -->|healthy| worker
    mailpit -->|started| worker
    api -->|healthy| proxy
```

| サービス | healthy の判定(healthcheck) |
| --- | --- |
| db | `pg_isready -h localhost`(TCPで接続できるか) |
| api | `GET /health`(DBに`SELECT 1`できるか) |
| proxy | コンテナの中だけで待ち受ける`/healthz` |

DBのボリュームが空のとき(初回、`docker compose down -v`の後)だけ、dbは初期化してから起動する。
**テーブルはcomposeの起動では作られない**。マイグレーションは起動とは別に実行する。

```mermaid
flowchart TD
    start["db コンテナの起動"] --> empty{"ボリュームが空?"}
    empty -->|いいえ| server["サーバーを起動<br/>(ソケットとTCPで待ち受け)"]
    empty -->|はい| initdb["initdb"]
    initdb --> temp["仮のサーバーを起動<br/>(ソケットだけで待ち受け)"]
    temp --> scripts["/docker-entrypoint-initdb.d/<br/>10_postgis.sh: 拡張機能<br/>20_roles_and_databases.sh: ロール・テスト用DB・権限"]
    scripts --> stop["仮のサーバーを停止"] --> server
    server --> healthy["healthcheckが通る → healthy<br/>(api・workerが起動する)"]
    healthy --> migrate["マイグレーション(composeの外で実行)<br/>run_checks.sh の migrate<br/>= alembic upgrade head (開発用・テスト用)"]
    migrate --> seed["開発用のデータ(任意)<br/>db/seed.sql、app.cli seed-dev"]
```

- workerは起動直後、マイグレーションの前だとテーブルが無いエラーを出すが、マイグレーションの後の次の実行で回復する
- 詳細は`backend/docs/バックエンド構成.md`の「スキーマとマイグレーション」「起動とヘルスチェック」

## 開発ルール

### コーディング規約

- 現状はlinterは未導入(frontend)。backendはruffの既定のルールに、DTZ(タイムゾーンなしの日時の指摘)を加えたもの(`pyproject.toml`の`[tool.ruff.lint]`)
- Dartのインデントは2文字、SQLのインデントは4文字で行い、Dartではリスト項目の末尾にも`,`を入れる
- 端末のログは`utils/app_log.dart`の`appLog`で出す(`print`は使わない)

### テスト

- 標準の`flutter_test`(`test/`配下)以外のテストフレームワーク・モックライブラリは未導入
- **ローカルでのチェックは`frontend/scripts/run_checks.sh`・`backend/scripts/run_checks.sh`で行う**。どちらも同じ形で動く:

```mermaid
flowchart LR
    cmd["run_checks.sh run_id step..."] --> order["指定されたstepを<br/>決まった順に並べる"]
    order --> step["stepを1つずつ実行<br/>(失敗しても残りを実行する)"]
    step --> log["step名.log<br/>(出力の全文)"]
    step --> summary["SUMMARY.md<br/>(実行環境・stepごとの結果・<br/>指摘や失敗の一覧・失敗したログの末尾)"]
    log --> dir["host_check_logs/<br/>時刻_run_id_PASSED または FAILED/"]
    summary --> dir
```

| | stepの実行順 | 省略時 | `all` |
| --- | --- | --- | --- |
| frontend | `pubget` → `codegen` → `analyze` → `test` → `e2e` | `analyze test` | `analyze test e2e` |
| backend | `lock` → `up` → `migrate` → `check` → `lint` → `test` → `https` | `migrate check lint test` | `up migrate check lint test https` |

- `run_id`は**実行を識別する任意の文字列**で、結果のディレクトリ名に入る。テスト内容の説明ではなく、実行ごとに変わる文字列にする
  (同じテストの再実行でも変える)と、どの実行の結果かを取り違えない
- 結果はまず`SUMMARY.md`を読む。`host_check_logs/`は`.gitignore`済み。前回の実行の結果も残るので、比べるのにも使える
- frontend(`frontend`ディレクトリで実行):
  - stepは`pubget`(flutter pub get)/`codegen`(build_runner)/`analyze`/`test`/`e2e`/`all`。`test`は`-t <path>`(複数可)で対象を絞れる
    (省略すると`test/`配下を全件実行する)。`analyze`は`--no-fatal-infos`で実行するためinfoだけではFAILEDにならないが、指摘は全件記録する
  - 結果は`frontend/host_check_logs/`。`SUMMARY.md`には実行環境(ブランチ/コミット/未コミット変更の有無/Flutterのバージョン)、
    analyzeの指摘一覧、testの失敗テスト名が入る。e2eのスクリーンショットは`screenshots/`にコピーされる
  - Driftの`*.g.dart`などコード生成物は`codegen`で更新してコミットする
- E2E/画面確認は`integration_test` + `flutter drive`で行う。E2Eだけなら
  `scripts/run_e2e_tests.sh <run_id>`でもよい(`run_checks.sh <run_id> e2e`のラッパー)。
  デバイスの決定順は`-d <device_id>` > `E2E_DEVICE_ID`環境変数 > `run_checks.sh`冒頭の
  `DEFAULT_DEVICE_ID`。シナリオは`-e <path>`で変えられる(省略時は`integration_test/app_test.dart`。
  機能紹介用のスクリーンショットは`integration_test/showcase_test.dart`)。シナリオの書き方は`docs/testing/e2e.md`
- `integration_test`は実機/シミュレータの本物の`app.sqlite`に対して動く。**seedして保存した
  セッションは必ず`addTearDown`等で後始末すること**(実機の履歴・リモートDBが汚染される)
- backend(どこから実行してもよい):
  - stepは`lock`(uvのDockerイメージでuv lock)/`up`(docker compose up -d --build --wait)/`migrate`(開発用・テスト用DBへのalembic upgrade head)/
    `check`(alembic check)/`lint`(ruff check)/`test`(pytest。`-t`で絞れる)/`https`(リバースプロキシ越しのHTTPSの確認。curlで証明書・ヘッダー・上限を確かめる)/`all`
  - 依存パッケージを変えたら`lock up`、Dockerfile・compose・`pyproject.toml`・`alembic.ini`を変えたら`up`も付けて実行する
    (`app/`・`tests/`・`migrations/`以外はbind mountしていないので、イメージの作り直しが必要)
  - 結果は`backend/host_check_logs/`。`SUMMARY.md`には実行環境、適用したマイグレーションとrevision、alembic checkの結果、ruffの指摘、
    pytestの失敗一覧と詳細が入る
  - 前提: `backend/.env`があり、`up`以外のstepはサービスが起動済みであること

### CI

`.github/workflows/ci.yml`。mainへのpush・PR・手動実行(Actionsのタブ)で、`backend`と`frontend`の2つのジョブを並列に実行する。
mainへはPR経由でしか入れず、2つのジョブが通らないとマージできない(GitHubのルールセットで設定)。

```mermaid
flowchart LR
    trigger["mainへのpush<br/>PR<br/>手動実行"]

    subgraph backend["backend ジョブ"]
        direction LR
        svc["PostGISのサービスコンテナ<br/>+ db/init のスクリプト"] --> bdeps["uv sync --locked"]
        bdeps --> ruff["ruff check"]
        bdeps --> mig["alembic upgrade head<br/>(開発用・テスト用)"]
        mig --> check["alembic check"]
        mig --> pytest["pytest"]
    end

    subgraph frontend["frontend ジョブ"]
        direction LR
        fdeps["flutter pub get<br/>--enforce-lockfile"] --> gen["build_runner<br/>生成物の差分の確認"]
        fdeps --> analyze["flutter analyze"]
        fdeps --> ftest["flutter test"]
    end

    trigger --> svc
    trigger --> fdeps
    backend --> rule["両方が通ればマージできる"]
    frontend --> rule
```

- 矢印は前提を表す。前提のステップ(依存のインストール、backendのマイグレーション)が失敗したら、それを使うステップは実行しない。
  前提が成功していれば、ほかのチェックが失敗しても残りのチェックは実行する(`if: ${{ !cancelled() && ... }}`。1回の実行で全ての問題が分かるように)
- `backend`: composeと同じ`db/init/20_roles_and_databases.sh`をサービスコンテナの中で実行して、ロール・テスト用データベースを作る。
  Pythonはランナー上のuv(Python 3.12)で動かす。APIはpytestの中でアプリを直接呼び、workerはジョブの関数を直接呼ぶので、
  api・worker・mailpitのコンテナは起動しない(Dockerfileでのビルドと起動は確かめていない)
- `frontend`: Flutterのバージョンはローカルと同じ値に固定する(ローカルのFlutterを上げたら、`ci.yml`の`flutter-version`も同じPRで上げる)
- `uv sync --locked`・`pub get --enforce-lockfile`は、lockファイルが`pyproject.toml`・`pubspec.yaml`と食い違っていると失敗する。
  依存パッケージを変えたら、ローカルで`lock`(backend)・`pubget`(frontend)を実行してlockファイルもコミットする
- 生成物の確認で失敗したら、ローカルで`run_checks.sh <run_id> codegen`を実行して生成物をコミットする
- CIのDBの接続情報は使い捨てのダミーの値で、`ci.yml`に直接書いている(秘密情報ではない)
- アクションはタグではなくコミットのSHAで固定する(タグは付け替えられるため)。更新は`.github/dependabot.yml`の
  バージョン更新(月1回、アクション・uv・pubの種類ごとに1つのPR)で行い、CIが通ればマージする

### git

- 作業はブランチを切って行い、並行する作業はgit worktreeで分ける。worktreeごとに依存・生成物が別になるため、
  作った直後に`run_checks.sh <run_id> pubget`(テーブル定義を変えた場合は`codegen`も)を実行する。backendの`docker compose`は
  ディレクトリ名から同じプロジェクト名(`backend`)になるので、メインのチェックアウトとworktreeで同時に起動しない
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
- `Geolocator.getCurrentPosition`は必ず`LocationSettings(timeLimit: ...)`付きで呼ぶ(無期限だとハングする)。
  呼び出しを重ねない(iOSでは先の呼び出しが完了せず、時間切れになる)
- flutter_mapで初期表示時にboundsへフィットさせるときは、後から`fitCamera()`/`move()`を呼ばず
  `MapOptions.initialCameraFit`を使い、`CameraFit.bounds`には`maxZoom`を付ける(タイルがグレーのままになる)
- 地図の`TileLayer`は`utils/map_tiles.dart`の定数を使う。`userAgentPackageName`を`com.example.*`のような汎用の値にしたり
  省略したりすると、OpenStreetMapのタイルサーバーに拒否されて地図が表示されない。地図のクレジットは`widgets/osm_attribution.dart`の
  `OsmAttribution`を使う(flutter_mapの`SimpleAttributionWidget`を直接置くと、内部の`SafeArea`で画面下端の安全領域の分だけ浮く)
- 上部に出し入れするバナーと`AppBar`の二重のステータスバー余白は`MediaQuery.removePadding`で揃える
- mainとworktreeの`backend`はcomposeのプロジェクト名(`backend`)・DBのボリュームを共有する。ユーザーの登録し直しは不要だが、
  古いコンテナが残ると`secrets/`のマウントが反映されずログインだけが500になる。おかしいときは`down`→`up`し直す
- backendのcomposeのネットワークはサブネットを固定している(proxyのIPを固定するため)。ネットワークの設定を変えた後や、
  リバースプロキシを入れる前のコンテナ・ネットワークが残っている場合は、`docker compose down`してから`up`する(DBのボリュームは消えない)
- シミュレータのアプリだけがAPIに繋がらない(タイムアウトし、APIのログにも届かない)ときは、Macの`127.0.0.1:443`を
  Docker以外(VSCodeのプロセス等)が待ち受けていないか`lsof -nP -iTCP:443 -sTCP:LISTEN`で確認する
- シミュレータのアプリがHTTPSでつながらない(証明書のエラー)ときは、シミュレータにmkcertのCAを入れたか確認する(シミュレータを作り直したり、
  初期化したりすると消える)。証明書の検証を無効にして回避しない
- Driftのクエリで`&`・`|`を使うファイルでは`package:drift/drift.dart`をimportする。`flutter_secure_storage`は11系を使う
  (9系は`geolocator`とwin32が衝突する)
- AIコーディングエージェントを使う場合の落とし穴は下記「AIコーディングエージェントを使った開発」

## デバッグ Tips

- 端末のログは`appLog`の`[sync] ...`・`[auth] ...`・`[http] ...`の行で見る(リリースビルドでは出さない)。
  通信は`[http]`の行に応答のリクエストID(`X-Request-ID`。リバースプロキシが作る)が出るので、backendのログ
  (`docker compose logs proxy api | grep <ID>`)と突き合わせられる。応答が届かなかったリクエストはIDが無いので、時刻でproxyのログを探す
- backendのログは`docker compose logs proxy`・`docker compose logs api`・`docker compose logs worker`で見る(key=value。`LOG_FORMAT=json`でJSON)。
  3つのログ(アクセス・アプリ・監査)の役割は`backend/docs/バックエンド構成.md`の「ログ」
- 複数端末での同期テストは、複数のシミュレータ/実機で同じユーザー(`app.cli seed-dev`のテストユーザー
  `testuser@example.com`等)にログインして行う。同期はメールアドレスが確認済みのユーザーでしか行われない

## よく使うコマンド

```bash
# 起動(同期先は既定でhttps://localhost/api。iOSシミュレータで使う。Androidエミュレータ・実機は証明書を信頼させる対応をしていないので使えない)
flutter run
# iOSシミュレータにmkcertのCAを入れる(シミュレータを起動した状態で。作り直し・初期化したら入れ直す)
xcrun simctl keychain booted add-root-cert "$(mkcert -CAROOT)/rootCA.pem"

# 以下はfrontendディレクトリで実行し、結果はhost_check_logs/<timestamp>_<run_id>_<結果>/に残る
# 静的解析 + ユニット/ウィジェットテスト(既定)
scripts/run_checks.sh <run_id>
# テスト対象を絞る
scripts/run_checks.sh <run_id> analyze test -t test/xxx_test.dart
# ローカルDB設定更新(build_runner)を含める / worktree作成直後はpubgetも
scripts/run_checks.sh <run_id> pubget codegen analyze test
# E2Eまで全部(シミュレータ/実機の起動後に実行)
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

# HTTPSの証明書を作る(初回と、約2年後の期限切れの前のみ。backend/secrets/はコミットしない。mkcert -installは実行しない)
mkdir -p secrets/tls
mkcert -cert-file secrets/tls/cert.pem -key-file secrets/tls/key.pem localhost 127.0.0.1 10.0.2.2
# 動作の確認
curl --cacert "$(mkcert -CAROOT)/rootCA.pem" https://localhost/api/
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

## AIコーディングエージェントを使った開発

このリポジトリの開発ではAIコーディングエージェント(Claude Code)も使っている。上記の流れ・ルールはエージェントを使う場合も同じで、
ここではエージェントを使うときの構成・運用・落とし穴をまとめる。

### 構成

- エージェントは、PCのほかのファイルに触れたり外部へ自由に通信したりしないよう、権限と通信先を制限したコンテナ(devcontainer)の中で動かす。
  リポジトリはbind mountでPC(ホスト)と共有する
- コンテナにはFlutter SDKもDockerデーモンも入れない。解析・テスト・コード生成・ビルド・シミュレータの操作・`docker compose`は、
  開発者がホストで`run_checks.sh`等を実行して行う
- そのため、エージェントは実装と一緒にその変更を検証するテストを書き、E2E以外のチェックはCIで確かめる。CIの結果は
  `gh pr checks <番号>`・`gh run view <run_id> --log-failed`で読める

### ホストでの実行と結果の受け渡し

`run_checks.sh`が結果をファイルに残すので、ホストでの実行結果を、出力を貼り付けずにエージェントへ渡せる。

```mermaid
sequenceDiagram
    participant A as エージェント(コンテナ)
    participant D as 開発者(ホスト)
    participant L as host_check_logs/
    A->>D: 実行するコマンドを依頼する(run_idを発行する)
    D->>L: run_checks.sh run_id step... を実行する
    D->>A: 完了を伝える
    A->>L: run_idで結果のディレクトリを探し、SUMMARY.md・ログ・スクリーンショットを読む
    A->>A: 結果を見て修正する
```

- エージェントはコピペで実行できる完全な形のコマンドを示し、開発者は実行と完了の報告だけを行う
- `run_id`は依頼のたびに新しく発行する(再実行の依頼でも変える)。複数の作業が並行しても、どの依頼の結果かを取り違えない
- E2E: シナリオ(`integration_test/*.dart`)はエージェントが書き、実行は開発者がホストで行う。エージェントは結果の
  `host_check_logs/.../screenshots/`(実行直後なら`frontend/integration_test_screenshots/`も同じ内容)の画像を開いて確かめる
- コミットするファイルを作る処理(`codegen`・`lock`)もホストで実行してもらい、できたファイルをコミットする
- 結果を確かめるまで(CIかホストの実行結果を読むまで)は、動作を確認したことにしない

### worktree

- エージェントの並行する作業は`.claude/worktrees/<作業名>/`(`.gitignore`済み)のgit worktreeで分ける
- コンテナで作ったworktreeをホストからも開いてテストできるよう、gitは2.48以上を使い、worktreeの参照を相対パスで記録する
  (`worktree.useRelativePaths=true`)。絶対パスだと、コンテナとホストでパスが違うため、ホストのgitがworktreeを認識できない
  (その場合も`run_checks.sh`は動き、`SUMMARY.md`にブランチ等の取得に失敗したことを残す)

### 落とし穴

- ホストとコンテナでVSCodeを同時に開く場合、`"dart.runPubGetOnPubspecChanges": "never"`が
  効いているか確認する(`.dart_tool/package_config.json`の取り合い。`docs/pitfalls.md`の「AIエージェントのコンテナとホストでの同時作業」)
