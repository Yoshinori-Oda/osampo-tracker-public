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
  (入力チェック)に分けている。仕様はAPI設計書
- ユーザーの確認は依存関係`verify_user_access`(`app/dependencies.py`)で行う。認証を実装するまでは
  トークンを検証せず、user_idのユーザーが存在するかだけを確認する
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
