# 同期API

同期API(`/api/users/{user_id}/sessions`)のサーバー側の実装と、削除済みのセッションのパージ(worker)。
端末とサーバーにまたがる同期の仕組みは`docs/design/sync.md`。

## パージ(worker)

- `worker`は`api`と同じイメージ・同じコードで起動コマンドだけを変え、APSchedulerで定期実行する(`app/worker.py`)
- パージ期間90日・実行間隔1日(`PURGE_RETENTION_DAYS`・`PURGE_INTERVAL_HOURS`)。`deleted_at`(削除した日時)が
  パージ期間より古いtombstoneを物理削除する(`app/services/purge_service.py`。track_pointsはON DELETE CASCADEで一緒に消える)
  - 起動直後に1回実行し、以降は実行間隔ごとに実行する。前回の実行が終わっていなければ重ねて実行しない
  - 失敗してもworkerは止めず、ログに残して次の実行で再び試みる
- パージ期間はGETの`request_existence_check`の判定と同じ設定値を参照する
- 同じパージのジョブで、期限切れのリフレッシュトークン・無効にした端末のログイン状態(「認証」)と、保持期間を過ぎたメールの送信の記録
  (「メール送信の基盤」)・監査ログ(「監査ログ」)も消す
- `worker`は1つだけ起動する(複数起動するとジョブが重複して実行されるため)。メールの送信もworkerの別のジョブ(5秒ごと)で行う
- 以前は`cron`コンテナがPostgREST経由でパージしていたが、frontendの切り替えに合わせて削除した(0003)

## 同期APIの実装

- `app/routers/sessions.py`(HTTPの受け口)・`app/services/session_service.py`(業務ルール)・`app/schemas/session.py`
  (入力チェック)に分けている。仕様は下記「エンドポイント」
- パスのuser_idを操作してよいかの確認は、依存関係`verify_user_access`(`app/dependencies.py`)で行う。アクセストークンの検証の後、
  本人か管理者か(403 `forbidden`)、メールアドレスの確認(403 `email_not_verified`)、ユーザーの存在(404 `user_not_found`)の順に判定し、
  他人のデータへのアクセスの拒否と、管理者による他のユーザーのデータへのアクセスは監査ログに残す
- 時刻はDBの`clock_timestamp()`(実行した瞬間のサーバー時刻)を正とする。`now()`はトランザクションの開始時刻で固定されるため
  使わない。DBとの接続のタイムゾーンはUTCに固定し(`app/db.py`の`DB_CONNECT_ARGS`)、レスポンスの日時は常にUTC
- 既知の制約: GETの`synced_at`より前の時刻を`updated_at`に持つ書き込みが、GETの後にコミットされると、次回の差分取得で
  取りこぼしうる(書き込みのトランザクションがGETをまたいで長く続いた場合)。同一ユーザーの同時操作は想定しないので許容している
- 位置情報の型: `track_points.location`は`geography(POINTZ, 4326)`(地球上の経度・緯度・高度。距離・範囲の計算は
  メートルで行われる)。geometry型は計算には使わず、次の2か所で一時的に経由するだけ(どちらも座標の値は変わらない):
  - 登録時: `ST_MakePoint`(geometry型を返す)で点を作り、`ST_SetSRID(..., 4326)`の後にgeographyへ変換する
    (新しいAPIでは列への代入時の暗黙の変換に任せている)
  - 取得時: `ST_X`/`ST_Y`/`ST_Z`はgeometry型の関数なので、geographyからgeometryに変換してから座標を取り出す。
    SQLAlchemyで型を指定せずに`cast(..., Geometry)`すると`geometry(GEOMETRY,-1)`(2次元)への変換になり、高度を持つ点が
    エラーになるので、`Geometry(geometry_type="POINTZ", srid=4326)`を指定する
- トラックポイントの高度(altitude)はnullを許さず、nullなら422にする(2026-10-06決定)。`location`は高度込みの点(POINTZ)で
  NOT NULLのため。frontendでも高度がnullになることは無い(Geolocatorの高度はnull不可で、信頼度の低い高度は前回の点との差が
  0.5m未満・75m超のときに前回の高度で補っている)。高度を別の列に分ける案・NaNで保存する案は、実際には起きないケースのための
  仕組みになるので採らなかった
- テスト: `tests/conftest.py`の`db_session`がテストごとにトランザクションを開始し、最後にロールバックする。`api_client`は
  FastAPIの`dependency_overrides`でAPIのDBセッションを`db_session`に差し替える。APIの中の`commit()`はセーブポイントの確定になる

## エンドポイント

パスは`/users/{user_id}/sessions`の下。共通の判定(413・415・406・401・403・404 `user_not_found`・422)は`backend/docs/バックエンド概要.md`の
「判定の順番」のとおりで、以下では業務ルールの部分だけを書く。端末とサーバーにまたがる流れは`docs/design/sync.md`。

不変の項目と可変の項目を次のように呼ぶ(`app/services/session_service.py`):

- 特定項目\*1(不変。再送で同じsessionかどうかを見分ける): started_at, ended_at, total_distance, duration_seconds, elevation_gain,
  max_altitude, min_altitude
- 特定項目\*2(端末で編集できる): name, is_favorite, move_method

### GET /users/{user_id}/sessions?last_synced_at=<日時>

1. last_synced_atの書式が不正、またはサーバー時刻より後: 422
2. synced_atに現在のサーバー時刻を入れる
3. last_synced_atが無い: 当該ユーザーの生きている(deleted_atがnullの)sessionを全て返す。
   ある: updated_atがlast_synced_atより後のsessionを全て返す(tombstoneはidとdeleted_atだけ)
4. last_synced_atが(サーバー時刻 - パージ期間)より前: `request_existence_check`をtrueにする(パージ済みの削除は差分に含まれないので、
   端末はexistence-checkで突き合わせる)

- リクエストした端末自身がpushしたsessionも返す
- sessionsはstarted_atの昇順、track_pointsはrecorded_atの昇順
- ページングは行わない(個人のデータの件数では不要で、カーソルの扱いが複雑になるため)。必要になったら、このGETではidと
  updated_at(tombstoneはdeleted_at)の一覧だけを返し、本体は1件ずつ(または数件ずつ)取得する形にする
  (途中で失敗しても、取得済みの分を残して残りだけをやり直せる)

### POST /users/{user_id}/sessions

1. updated_atに現在のサーバー時刻を入れる
2. sessionsテーブル(全ユーザー)に同じidのレコードがあるとき:
   - 他ユーザーのレコード、または特定項目\*1が1つでも違う: 409(`id_conflicted`)
   - 当該ユーザーのレコードで、特定項目\*1が全て同じ(同じsessionの再送):
     - tombstoneで、特定項目\*2が違う: 409(`deleted`)。同じなら既存のupdated_atを返して200
     - 生きていて、特定項目\*2が違う: 特定項目\*2とupdated_atだけを更新して200。同じなら既存のupdated_atを返して200
3. 無ければ登録して201

- ended_atは必須(サーバーには終了したセッションだけを記録する)。track_pointsのaltitudeもnull不可(locationが高度込みの点(POINTZ)のため。
  高度の信頼度が低い場合は端末が前回の点の高度で補う)
- max_altitude・min_altitudeの比較ではnullに注意する(SQLでは`NULL = NULL`が真にならない)
- 同じidのsessionが同時に登録されたときのため、登録は`INSERT ... ON CONFLICT DO NOTHING`で行い、挿入が0件なら手順2からやり直す
- セッションとトラックポイントは1つのトランザクションで登録する
- uvicorn・FastAPIにはリクエストの大きさの上限が無いので、bodyに10MBの上限をかける(不正なリクエストで処理が滞らないように)

### PATCH /users/{user_id}/sessions/{session_id}

1. updated_atに現在のサーバー時刻を入れる
2. idとパスのuser_idの両方で絞って検索し、無い: 404(`session_not_found`)
3. tombstone: 409(`deleted`)
4. 特定項目\*2が全て同じ: 既存のupdated_atを返して200。違う: 特定項目\*2とupdated_atだけを更新して200

- bodyは特定項目\*2の3項目を全て必須にする(端末で変更した項目を追跡しなくて済むように)。3項目を毎回受け取るので、
  同じPATCHが2回届いても結果は変わらない
- それ以外の項目は422(`extra="forbid"`。端末のバグで不変の項目を変えようとしても気づけるように)
- 他ユーザーのsessionのidも、存在しない場合と区別せず404にする(403だと、そのidのsessionを誰かが持っていることが分かるため)
- 409(`deleted`)はパージ前のtombstone、404(`session_not_found`)はパージ済み(または他ユーザーのもの・未登録)を表す
- 同じユーザーが複数の端末で同時に操作することは想定しないので、競合の検出は削除済みかどうかだけで、他の端末での編集は上書きする
  (楽観ロックは入れない)

### DELETE /users/{user_id}/sessions/{session_id}

1. idとパスのuser_idの両方で絞って検索し、無い: 404(`session_not_found`)
2. 既にtombstone: 何も変えずに204
3. deleted_atとupdated_atに現在のサーバー時刻を入れて204

- 既にtombstoneのときにdeleted_atを更新しないのは、パージまでの期間が延びることと、他の端末に同じtombstoneが差分として再び届くことを避けるため
- 無い場合(パージ済み・未登録・他ユーザーのもの)を204ではなく404にするのは、PATCHと判定・エラーコードを揃え、ログで「削除した」のか
  「元から無かった」のかを区別できるようにするため。どちらでもサーバーにそのsessionが無い状態になるので、同じDELETEを繰り返しても
  サーバーの状態は変わらない(冪等)
- tombstoneになってもsessionとtrack_pointsのデータは残す(復活と、POSTの再送の比較に要るため)
- 他の端末での編集より後に届いた削除は、その編集を上書きして削除する(楽観ロックは入れない)

### POST /users/{user_id}/sessions/{session_id}/restore

削除と編集が競合したときに、編集内容を残して削除を取り消す。bodyの扱い(3項目全て必須、それ以外の項目は422)はPATCHと同じ。

1. updated_atに現在のサーバー時刻を入れる
2. idとパスのuser_idの両方で絞って検索し、無い: 404(`session_not_found`。パージ済みで、復活させる対象が残っていない)
3. tombstone: deleted_atをnullにし、特定項目\*2とupdated_atを更新して200
4. 生きている(復活済み): PATCHの手順4と同じ

- パスが処理名で終わる(リソースではなく操作を表す)ので、メソッドはPOSTにする
- 既に復活済みでも200を返すので、同じrestoreを繰り返してもサーバーの状態は変わらない(冪等)
- 復活したsessionはupdated_atが更新されるので、tombstoneを受け取ってローカルから消していた他の端末にも、次のGETで
  生きているsessionとして全データ(track_pointsを含む)が届き、復活する
- パージと同時に実行された場合は、トランザクションでどちらかが先に確定する。restoreが先ならdeleted_atがnullになってパージの対象から外れ、
  パージが先ならrestoreは404になる

### POST /users/{user_id}/sessions/existence-check

GETで`request_existence_check`がtrueだったときに、パージ済みで差分に含まれなかった削除を補う。

1. session_idsのうち、当該ユーザーの生きているsessionとして存在するものを検索する
2. session_idsからそれを除いたものを`missing_session_ids`として200で返す

- DBは変えないが、IDが多いとクエリ文字列の長さの上限にかかるのでPOSTにする
- tombstone・他ユーザーのsessionのIDも「存在しない」として返す(他ユーザーのデータの有無を伝えないため)
- 返すのは存在しないIDだけ(削除の漏れは通常ごく少数なので、レスポンスが小さくなる)。並び順は保証しない
- IDの数に個別の上限は設けず、bodyの10MBの上限だけにする(約25万件に相当し、個人のsessionの数には十分)
- 重複したIDは1つにまとめる。空の配列なら空の`missing_session_ids`を返す
- サーバーは突き合わせの状態を持たない(どのGETに続く突き合わせかは関知しない)
