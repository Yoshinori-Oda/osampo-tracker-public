# DBとマイグレーション

スキーマとマイグレーション(Alembic)、DBのロールと接続、行レベルセキュリティ(RLS)の設計。

## スキーマとマイグレーション

- スキーマはAlembicで管理する(`backend/alembic.ini`・`backend/migrations/`)。初期マイグレーション
  (`migrations/versions/0001_initial_schema.py`)は旧`initdb.sql`のスキーマ(users / sessions / track_points、
  インデックス、PostgRESTが使っていたストアドファンクション)をそのまま写し、変更は2本目以降のマイグレーションで行う
  - ORMのモデル(`app/models/`)はマイグレーションと同じ定義にし、`alembic check`で差分が無いことを確認する
  - マイグレーションのrevisionは連番(`0001`, `0002`, ...)を手で付け、ファイル名は`連番_内容.py`にする
- DBの中身は2段階で作る:
  1. DBコンテナの初回起動時(ボリュームが空のときだけ): `db/init/20_roles_and_databases.sh`がロール・テスト用データベース・
     拡張機能(postgis / uuid-ossp)・権限を用意する。拡張機能の作成にはスーパーユーザーの権限が必要なので、Alembicではなくここで作る。
     postgis/postgisイメージの`10_postgis.sh`の後に実行されるよう、ファイル単位でマウントしている。
     `10_postgis.sh`が開発用のデータベースに入れる使わない拡張機能(`postgis_topology`・`fuzzystrmatch`・
     `postgis_tiger_geocoder`)は削除し、`search_path`も元に戻す(`postgis_topology`が追加する`topology`スキーマの
     テーブルを`alembic check`がモデルに無いテーブルとして検出するため。テスト用のデータベースと環境を揃えるためでもある)
  2. 起動後: 開発用・テスト用の各データベースに`alembic upgrade head`を実行し、テーブル等を作る
- データベースは同じDBコンテナ(PostgreSQLサーバー)の中に2つ置く:
  - `location_db`(`POSTGRES_DB`): 開発用。api・worker(frontendの同期)が使う
  - `location_db_test`(`POSTGRES_TEST_DB`): pytest専用。`tests/conftest.py`で接続先をこちらに切り替える
- 最初のスキーマ変更(`0002_altitude_columns_to_double_precision.py`): `elevation_gain`・`max_altitude`・`min_altitude`を
  `REAL`から`double precision`にした(POSTの再送判定で値を比較するため。同期で取得したデータの精度を落とさないため)。
  PostgRESTが使っていた`register_session_with_points`も3列の値を`::real`に変換していたので、`::double precision`に作り直した
- PostgRESTの削除(`0003_remove_postgrest.py`、frontendの同期を新しいAPIへ切り替えた後): ストアドファンクションを削除し、
  `deleted_at`の意味を「削除した日時」に統一した。PostgREST時代のtombstoneは`deleted_at`にパージ予定日時(削除の90日後。
  未来の日時)が入っているので、その行だけを90日前に戻すデータ移行を行う(新しいAPIで削除した行は過去の日時なので当たらない)。
  PostgREST用のロール`web_anon`の権限も外す(ロール自体の削除はスーパーユーザーの権限が必要なので行わない。
  既存のボリュームには`web_anon`・`authenticator`が残るが、権限は無い。ボリュームを作り直せば作られない)。
  downgradeはストアドファンクションを0001・0002のファイルから読み込んで作り直す
- `postgis/postgis`イメージに含まれるPostGISのテーブル(`spatial_ref_sys`等)は、Alembicの自動生成の対象から外す
- マイグレーションは`api`の起動時には実行せず、別のコマンドで個別に実行する
  (例: `docker compose run --rm api alembic upgrade head`)。本番ではデプロイの手順の中で1回だけ実行するのが一般的なため
- 既存の開発データは移行しない。ボリュームを作り直し、シード(初期の管理者・パスワード付きのテストユーザー・
  テスト用のセッション)で入れ直す

## DBのロールと接続

- ロールを分ける(アプリに穴があってもテーブルの削除・変更はできないようにするため):

  | ロール | 用途 | 権限 |
  |---|---|---|
  | `POSTGRES_USER`(例: `postgres`) | 管理用のスーパーユーザー | 全て。拡張機能とロールの作成にだけ使う |
  | `osampo_migrator`(`MIGRATOR_DB_USER`) | マイグレーション(Alembic) | publicスキーマへのテーブルの作成・変更。テーブルの所有者になる |
  | `osampo_app`(`APP_DB_USER`) | `api` | データの読み書きのみ(DDL不可)。`sessions`・`track_points`はRLSで本人(管理者は全て)の行だけ |
  | `osampo_worker`(`WORKER_DB_USER`) | `worker` | ジョブで使うテーブル・操作だけ(下記「行レベルセキュリティ(RLS)」の「workerのロール」) |

- アプリ用のロールへの権限は、初回起動時のスクリプトで`ALTER DEFAULT PRIVILEGES FOR ROLE osampo_migrator`を
  設定し、マイグレーション用のロールが作ったテーブル・シーケンスに自動で付くようにしている
  (マイグレーションごとにGRANTを書かなくてよい)
- composeでは各サービスに必要な接続情報だけを渡す。マイグレーション用のロールは`api`(`docker compose run --rm api alembic ...`
  で使う)にだけ渡し、`worker`には渡さない。`worker`にはworker用のロールだけを渡す(api用のロールは渡さない)。`api`にはworker用のロールも
  渡す(マイグレーションでポリシー・権限の対象のロール名に使い、pytestでworkerの権限を確かめるため)
- DBセッションは`app/db.py`の`app_session()`(api・管理用のコマンド)と`worker_session()`(worker)で作る。接続は使うときに初めて作る
  (プロセスが使わないロールの接続情報を要求しないため)
- `api`・`worker`からはcomposeのネットワーク内でサービス名`db`で接続する
- 開発中はホストのDBクライアントから確認できるよう、現行通り5432番を公開する(本番ではDockerでDBを動かさない想定)

## 行レベルセキュリティ(RLS)(2026-10-26に設計)

アプリ層の分離(`verify_user_access`でパスの`user_id`とトークンのユーザーを比べる)に加えて、DBでも本人の行だけを扱えるようにする
(多層防御。アプリにクエリの条件の書き忘れ等があっても他人の行に届かない)。

### 方針(決定)

- **対象は`sessions`・`track_points`だけ**。認証系(`users`・`auth_sessions`・`refresh_tokens`・`email_codes`)・`outbox_emails`・
  `audit_events`は対象外(ログインの時点ではユーザーが決まっていないため、RLSと相性が悪い)
- **ホワイトリスト(未設定なら0件)**: apiはトランザクションごとに今のユーザーのIDを`set_config('app.user_id', <ID>, true)`
  (=`SET LOCAL`)で渡し、ポリシーはそのユーザーの行だけを許す。渡し忘れたときは全件ではなく何も見えない側に倒れる
- **`track_points`**: `user_id`の列を持たず、`session_id`経由で`sessions`の`user_id`と比べる(`EXISTS`のサブクエリ)。
  INSERTの検査にも同じ条件を使い、他人のsessionにtrack_pointを足せないようにする
- **管理者**: DBのロールは分けない。apiは`app.user_id`だけを渡し、ポリシーが`users.role`を引いて管理者か判定する
  (管理者かどうかの根拠を`users.role`の1か所にし、apiの不具合で「管理者のふり」ができないようにする)。
  管理者は全ての行を読み書きできる
- **書き込みの検査(`WITH CHECK`)**: 一般ユーザーにだけかけ、自分の`user_id`(`track_points`は自分のsession)でしか書けないようにする。
  管理者・`worker`・`osampo_migrator`にはかけない
- **`worker`**: 専用のロールを作り、`api`とは別の接続情報にする。パージのために`sessions`の全行を扱えるよう、`BYPASSRLS`の属性ではなく
  そのロール向けのポリシー(`TO <workerのロール> USING (true)`)で許す(素通りできるテーブルと操作がマイグレーションに残り、権限も最小にできる)。
  `track_points`は`sessions`のON DELETE CASCADEで消える(外部キーの処理はRLSの対象外)ので、ポリシーは要らない
- **`osampo_migrator`(テーブルの所有者)**: `FORCE ROW LEVEL SECURITY`を付けず、RLSの対象外のままにする。`db/seed.sql`の投入・
  外部キーのCASCADEは今のまま動く。apiを誤ってmigratorの接続情報で起動するとRLSが黙って無効になるので、テストで
  「apiのロールがテーブルの所有者でないこと」「対象のテーブルでRLSが有効なこと」を確認する

### 今のユーザーを渡すタイミング

`SET LOCAL`はトランザクションが終わると消える。一般ユーザーが自分を指定する同期APIは、認証からserviceの最後のcommitまでが
1つのトランザクションなので1回渡せば足りる。管理者が他のユーザーを指定する場合だけ、トランザクションが2つになる:

1. `get_auth_context`(`authenticate`): トークンを検証し、`users`・`auth_sessions`を読む(1つ目のトランザクションが始まる)
2. `verify_user_access`: 対象のユーザーの存在を確認し、監査ログ(`admin_user_access`)を積んで**commit**(1つ目が終わる)
3. service: `sessions`を読み書きして**commit**(2つ目)。ここで`app.user_id`が消えていると0件になり、管理者なのに404になる

SQLAlchemyのセッションの`after_begin`イベントで、トランザクションが始まるたびに`set_config`する(2026-10-26に決定)。
認証が終わった時点でセッションに今のユーザーを記録し(`session.info`)、その時点で始まっているトランザクションにもすぐ渡す。
以降はcommitの場所が増えても渡し忘れが起きない。管理者の経路だけ渡し直す案・1つのトランザクションにまとめる案は、
commitの場所が変わると壊れる(後者はGETで監査ログをcommitする場所も変わる)ので採らなかった。

### ポリシー

2つの関数をマイグレーション0009で作り、ポリシーからは`(SELECT 関数())`の形で呼ぶ(行に依存しないサブクエリになり、1回の検索につき
1回だけ実行される):

```sql
-- 今のユーザー(未設定ならNULL)。一度SET LOCALした接続では、トランザクションの終了後に''へ戻ることがあるのでNULLIFで受ける
app_current_user_id()       = NULLIF(current_setting('app.user_id', true), '')::uuid
-- 今のユーザーが管理者か
app_current_user_is_admin() = EXISTS (SELECT 1 FROM users WHERE id = app_current_user_id() AND role = 'admin')
```

| テーブル | ポリシー | 対象のロール | 操作 | USING(読める・変えられる行) | WITH CHECK(書ける値) |
|---|---|---|---|---|---|
| `sessions` | 本人 | api | 全て | `user_id = <今のユーザー>` | 同左 |
| `sessions` | 管理者 | api | 全て | 管理者か | 管理者か |
| `sessions` | パージ | worker | SELECT・DELETE(ポリシーは操作ごとに2つ) | `true` | - |
| `track_points` | 本人 | api | 全て | `EXISTS (sessions s WHERE s.id = session_id AND s.user_id = <今のユーザー>)` | 同左 |
| `track_points` | 管理者 | api | 全て | 管理者か | 管理者か |

- 同じテーブル・操作の複数のポリシーはOR(permissive)で組み合わさる
- ポリシーの対象のロール名は、マイグレーションの中で設定(`APP_DB_USER`・`WORKER_DB_USER`)から読む

### 既存のコードへの影響

- **POSTの`id_conflicted`**: 他人のsessionが見えなくなるので、SELECTも`INSERT ... ON CONFLICT DO NOTHING`も0件になる(以前の
  2回のループでは`RuntimeError`(500)になっていた)。INSERTが衝突で0件になり、その後のSELECTでも見えなければ「他人の行との衝突」として
  409 `id_conflicted`にする(一意制約はRLSに関係なく効く。他人の行の中身を見ずに判定できる)。管理者は他人の行も見えるので、
  今まで通り`user_id`を比べて判定する
- **404の理由のログ**: 「無い(`not_exists`)」と「他人のもの(`other_user`)」の区別をやめ、`not_found_or_not_visible`の1つにした
  (RLSの「見えないものは存在しない」と一貫させる。区別のためにRLSを迂回する関数は作らない。2026-10-26に決定)

### テスト

- `tests/conftest.py`はapiと同じロールで接続するので、テストにもRLSがかかる。準備のデータを直接INSERTするテストは、先に
  `set_rls_user()`で今のユーザーを渡す
- `db_session`のcommitはセーブポイントの確定で、`SET LOCAL`は外側のトランザクションが続く限り残る。そのため、APIを通したテストでは
  「commitの後に渡し直す」ことは確かめられない。`tests/test_rls.py`で本物のトランザクションを使って確認する
- `tests/test_rls.py`: RLSが有効でapiのロールが所有者でないこと、未設定なら0件、他人の行が見えず書けないこと、管理者は全て
  扱えること(`users.role`で判定)、commitの後の渡し直し、workerのロールでの全ユーザーのパージ(マイグレーション用のロールでデータを
  commitして最後に消す)、workerのジョブが権限の範囲で動くこと、ジョブの外のテーブル・操作が拒否されること
- `test_purge.py`のパージのロジックのテストは、今まで通り`db_session`(apiのロール。今のユーザーの行だけが見える)で行う

### workerのロール(`osampo_worker`)

- 接続情報は`WORKER_DB_USER`・`WORKER_DB_PASSWORD`(`backend/.env`)。ロールはサーバー全体のものなのでmigratorでは作れず、
  `db/init`で作る。`worker`には今の`APP_DB_*`の代わりにこちらを渡す
- **権限は今のジョブで使うテーブル・操作だけにする(最小権限)**。`ALTER DEFAULT PRIVILEGES`は付けないので、workerが新しい
  テーブルを使うときは、そのマイグレーションでGRANTを足す:

  | テーブル | 権限 | 使うジョブ |
  |---|---|---|
  | `sessions` | SELECT・DELETE | tombstoneのパージ(条件で列を読むのでSELECTも要る) |
  | `refresh_tokens` | SELECT・DELETE | 期限切れのトークンのパージ |
  | `auth_sessions` | SELECT・DELETE | 無効にしたログイン状態のパージ |
  | `outbox_emails` | SELECT・UPDATE・DELETE | 送信(`FOR UPDATE`で取り出して結果を書く)・送信の記録のパージ |
  | `audit_events` | SELECT・DELETE | 監査ログのパージ |

  `track_points`(sessionsのCASCADE)・`refresh_tokens`(auth_sessionsのCASCADE)の連鎖の削除は外部キーの処理として行われるので、
  workerにそのテーブルの権限は要らない。`users`・シーケンスも使わない
