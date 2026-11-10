# システム概要

基本設計書の1本目。システム全体の構成と主なデータの流れをまとめる。2026-10-15時点のmainの実装を正として書き(リバースプロキシは2026-11-09の追加を反映済み)、
未実装のものは「予定」と明記する。個々の仕組みの詳細は末尾の「関連文書」から辿る。

## 目的

散歩などの移動を記録するモバイルアプリ。収録中は数秒おきに現在位置を端末に記録し、地図上の軌跡・距離・時間として
振り返れるようにする。記録はサーバーと同期し、同じユーザーの別の端末からも見られる。

## システム構成図

```mermaid
flowchart LR
    subgraph device["端末 (iOS / Android)"]
        app["モバイルアプリ<br/>Flutter"]
        sqlite[("ローカルDB<br/>SQLite (Drift)")]
        secure[("トークン<br/>Keychain / Keystore")]
        gps["位置情報<br/>(OSのGPS)"]
        app --- sqlite
        app --- secure
        gps --> app
    end

    subgraph backend["バックエンド (docker compose)"]
        proxy["proxy<br/>nginx<br/>127.0.0.1:443 (HTTPS)"]
        api["api<br/>FastAPI + uvicorn<br/>:8080 (composeの中だけ)"]
        worker["worker<br/>APScheduler"]
        db[("db<br/>PostgreSQL 16 + PostGIS")]
        mailpit["mailpit<br/>開発用SMTP<br/>Web UI 127.0.0.1:8025"]
        proxy -- "HTTP /api/" --> api
        api --> db
        worker --> db
        worker -- SMTP --> mailpit
    end

    osm["OpenStreetMap<br/>タイルサーバー"]

    app -- "HTTPS (REST, JSON)<br/>Authorization: Bearer" --> proxy
    app -- 地図タイル --> osm
```

## 構成要素

| 構成要素 | 役割 | 実装 |
|---|---|---|
| モバイルアプリ | 位置情報の収録、記録の閲覧・編集・統計、ログイン・登録、サーバーとの同期 | `frontend/`(Flutter / Riverpod) |
| ローカルDB | 収録したセッションと位置情報の点を保存する。ログインしたユーザーごとにデータを分ける | `frontend/lib/database/`(Drift / SQLite) |
| トークンの保存領域 | アクセストークン・リフレッシュトークンを保存する。パスワードは端末に保存しない | `frontend/lib/auth/auth_storage.dart`(flutter_secure_storage) |
| proxy | リバースプロキシ。TLSを終端してHTTPSで公開し、`/api/`だけをapiへ転送する。送信元のIP・リクエストIDの付与、流量・大きさ・時間の上限、アクセスログ | `backend/proxy/`(nginx)。詳細は`backend/docs/https-proxy.md` |
| api | REST APIを提供する(認証・ユーザー・セッションの同期・ヘルスチェック) | `backend/app/`(FastAPI)。`main.py`・`routers/` |
| worker | 定期実行のジョブ。outboxのメールの送信(5秒ごと)と、期限切れデータのパージ(24時間ごと) | `backend/app/worker.py`。apiと同じイメージで起動コマンドだけ変える。ジョブの重複を避けるため1つだけ起動する |
| db | サーバー側のデータ(ユーザー・ログイン状態・セッション・位置情報の点・メール)を保存する | PostgreSQL 16 + PostGIS。スキーマはAlembic(`backend/migrations/`)で管理 |
| mailpit | 開発用のSMTP受信サーバー。メールを外部に出さず、Web UIで確認する | composeのサービス。本番相当のSMTPは未定 |
| 地図タイル | 地図の背景画像 | OpenStreetMapのタイルサーバーを端末から直接参照する(APIキー不要) |

## 主なデータの流れ

### 収録から同期まで

オフラインファーストで、収録・閲覧・編集は端末だけで完結する。サーバーとの同期は後から追いつく。

1. 収録中はGPSの位置情報のストリームを購読し、5秒ごとに位置情報の点をローカルDBへ書き込む。
   アプリがバックグラウンドに回っても収録は続く(Androidは常駐通知付きのForeground Service)
2. 収録を止めると、保存/破棄の画面で保存したセッションが同期の対象になる
3. 同期は push(未同期のセッションを登録・更新・削除)→ 削除と編集の競合の解決 → pull(前回からの差分の取得)の順に行う
4. 同期のきっかけは、ローカルでの書き込みの直後・アプリの起動時・フォアグラウンドへの復帰時。失敗したら5分後に再試行する
5. 通信できない間・トークンが切れている間も収録と閲覧はでき、止まるのは同期だけになる

```mermaid
sequenceDiagram
    participant GPS as 位置情報(OS)
    participant App as アプリ
    participant Local as ローカルDB
    participant API as api
    participant DB as db

    GPS->>App: 位置情報のストリーム
    loop 収録中、5秒ごと
        App->>Local: 位置情報の点を書き込む
    end
    App->>Local: 収録の停止・保存
    App->>API: push(POST / PATCH / DELETE /api/users/{id}/sessions)
    API->>DB: 書き込み(時刻はサーバー時刻)
    App->>API: pull(GET 差分。last_synced_at)
    API-->>App: 変更・削除されたセッションと synced_at
    App->>Local: 反映し、synced_at を次回の last_synced_at として保存
```

### 認証

- 登録・ログインはapiの`/api/auth/...`で行い、アクセストークン(ES256のJWT、15分)とリフレッシュトークン(30日、使うたびに取り替える)を受け取る
- アプリはAPIを呼ぶたびにアクセストークンを`Authorization: Bearer`で付け、401(`token_expired`)ならリフレッシュトークンで更新してから再送する
- 同期は、メールアドレスの確認が済んだユーザーだけが使える

### メール送信

apiはメールを直接送らず、DBのoutbox(`outbox_emails`)に積むだけにする。workerが5秒ごとにoutboxを確認してSMTPで送る。
apiの応答がSMTPサーバーの遅延・障害の影響を受けず、送信に失敗しても再試行できるようにするため。
現在メールを送るのは、メールアドレスの確認コード(6桁)だけ。

## 技術スタック

| 区分 | 技術 |
|---|---|
| モバイルアプリ | Dart / Flutter、Riverpod(状態管理)、Drift(ローカルDB)、geolocator(位置情報)、flutter_map + latlong2(地図)、fl_chart(グラフ)、http(API通信)、flutter_secure_storage(トークンの保存)、permission_handler(通知の権限) |
| APIサーバー | Python 3.12 / FastAPI、uvicorn、Pydantic・pydantic-settings、SQLAlchemy 2(非同期)+ psycopg 3、GeoAlchemy2、PyJWT(ES256)、pwdlib(Argon2)、APScheduler |
| DB | PostgreSQL 16 + PostGIS 3.4、Alembic(マイグレーション) |
| 開発・テスト | flutter_test・integration_test、pytest・ruff、uv(Pythonの依存パッケージ)、Docker Compose |

## 実行環境

- **開発環境だけがある**。本番環境・ステージング環境は無い
- バックエンドは開発者のPC(ホスト)の`docker compose`で起動する。ホストに公開しているポートは proxy `443`(HTTPS)・db `5432`・
  mailpit `8025`で、いずれもホストのループバック(`127.0.0.1`)だけ。apiはホストに公開せず、proxyを通してだけ使う
- アプリはホストの`flutter run`で、iOSシミュレータに入れて動かす。接続先のAPIは既定で`https://localhost/api`。証明書はmkcert
  (手元に作るCA)で発行し、シミュレータにCAを信頼させる。Androidエミュレータ・実機はCAを信頼させる対応をしていないので、今は使わない
- 開発の流れ・ローカルでのテスト・CIは`docs/development.md`
- ストアでの公開はしていない

## 前提・制約

- 同じユーザーが複数の端末で同時に操作することは想定しない。そのため同期は`updated_at`による単純なpull型の差分同期にしている
- 時刻はサーバー時刻を正とする(端末の時計で同期の基準時刻を作らない)
- 地図タイルはOpenStreetMapの公開タイルサーバーを直接使っている。地図には「© OpenStreetMap contributors」のクレジットを出し、
  `userAgentPackageName`にアプリ固有のID(`frontend/lib/utils/map_tiles.dart`)を設定している。一般に配布する場合は、タイル利用ポリシー(利用量・キャッシュ等)への適合を改めて確認する

## 関連文書

### 基本設計書(`docs/basic-design/`)

| 文書 | 内容 |
|---|---|
| `system-overview.md` | この文書 |
| `features.md` | 機能一覧 |
| `screens.md` | 画面一覧・画面遷移 |
| `data.md` | データ設計 |
| `api.md` | API一覧 |
| `security.md` | 認証・セキュリティ |

### 詳細設計

| 文書 | 内容 |
|---|---|
| `docs/design/sync.md` | 同期・削除(tombstone)・競合の解決 |
| `frontend/docs/location-tracking.md` | 収録の状態遷移・位置情報のバナー |
| `frontend/docs/background-recording.md` | バックグラウンドでの収録 |
| `frontend/docs/session-recovery.md` | 起動時の未完了セッションの回収 |
| `backend/docs/overview.md` | バックエンドの構成・主な決定事項・実装方針・設定・起動・テスト |
| `backend/docs/database.md` | マイグレーション・DBのロール・行レベルセキュリティ(RLS) |
| `backend/docs/sync-api.md` | 同期APIのサーバー側の実装・パージ |
| `backend/docs/auth.md` | 認証・ログインの試行回数の制限 |
| `backend/docs/mail.md` | メール送信の基盤・メールアドレスの確認コード |
| `backend/docs/logging.md` | アクセスログ・アプリのログ・監査ログ |
| `backend/docs/https-proxy.md` | リバースプロキシ(nginx)・証明書・TLSの設定・送信元のIPとリクエストID・流量などの上限 |
