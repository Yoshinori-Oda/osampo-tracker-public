# API一覧

基本設計書の5本目。apiが提供するREST APIの一覧と共通の方針をまとめる。2026-11-10時点のmainの実装を正とする。
各エンドポイントの処理の手順・判断の理由は`backend/docs/overview.md`の「API(共通)」と機能ごとの文書(`sync-api.md`・`auth.md`・`mail.md`)にあり、ここでは繰り返さない。
入出力の型と例はOpenAPI(実装から自動生成。外には公開しないので、取り出し方は`backend/docs/overview.md`の「API(共通)」)で見る。

## 共通の方針

要点だけを挙げる。詳細は`backend/docs/overview.md`の「API(共通)」。

| 項目 | 方針 |
|---|---|
| ベースURL | `https://localhost/api`(開発環境。リバースプロキシが`/api/`だけを公開する。ヘルスチェックの`/health`は`/api`の外にあり、composeの中からだけ使う) |
| 形式 | リクエスト・レスポンスともJSON(`Content-Type: application/json`) |
| 認証 | 新規登録・ログイン・トークンの更新以外は`Authorization: Bearer <アクセストークン>`が必須。トークンの仕組みは`security.md` |
| 権限 | 一般ユーザーは自分のデータだけを扱える(パスの`user_id`がトークンのユーザーと違えば403)。管理者は他のユーザーも扱える |
| 同期の条件 | 同期API(`/users/{user_id}/sessions/...`)は、メールアドレスが確認済みのユーザーだけが使える(未確認なら403 `email_not_verified`) |
| エラー | 4xx・5xxは全て`{"code", "message", "details"}`の形式で返す。クライアントは`code`で処理を分岐し、`message`は分岐に使わない。`details`は422のときだけ含める |
| 判定の順番 | リクエストの形式(413・415・406)→ 認証と権限(401・403)→ ユーザーの存在(404)→ 入力チェック(422)→ 業務ルール(404・409) |
| 時刻 | 全てUTC(ISO 8601、`Z`付き)。リクエストの日時もタイムゾーン付きだけを受け付ける。`updated_at`等はサーバー時刻で付ける |
| 冪等性 | 通信が切れて端末が再送しても壊れないようにする(同じ登録の再送・復活済みのrestore・確認済みのconfirmは200で受け流す) |
| サイズの上限 | リクエストのbodyは10MBまで(超えたら413) |
| 流量の上限 | 送信元のIPごとに、リバースプロキシで流量・同時接続の数を制限する(超えたら429 `too_many_requests`と`Retry-After`) |
| リクエストID | 全ての応答に`X-Request-ID`を付ける。IDはリバースプロキシが作り、クライアントが送った値は使わない |

## エンドポイント一覧

「認証」の列: ×=不要、○=アクセストークンが必要、◎=アクセストークンに加えてメールアドレスが確認済みであること。

### 認証(`/api/auth`)

| メソッド | パス | 名前 | 認証 | 成功 | 主なエラー | 使う機能 |
|---|---|---|---|---|---|---|
| POST | `/auth/signup` | 新規登録 | × | 201 + トークン | 409 `email_already_registered` | F-ACC-01 |
| POST | `/auth/login` | ログイン | × | 200 + トークン | 401 `invalid_credentials`、403 `account_disabled`、429 `too_many_requests`(試行回数の上限) | F-ACC-02 |
| POST | `/auth/refresh` | トークンの更新 | ×(bodyでリフレッシュトークン) | 200 + トークン | 401 `invalid_refresh_token` | F-ACC-03 |
| POST | `/auth/logout` | ログアウト | ○ | 204 | — | F-ACC-08 |

新規登録・ログイン・トークンの更新は、同じ形式(アクセストークン・リフレッシュトークン・有効期限・ユーザーの情報)を返す。
新規登録・ログインでは端末ID(`device_id`)を送る。

### 自分のユーザー(`/api/users/me`)

| メソッド | パス | 名前 | 認証 | 成功 | 主なエラー | 使う機能 |
|---|---|---|---|---|---|---|
| GET | `/users/me` | 自分の情報 | ○ | 200 | — | F-ACC-03、05 |
| PATCH | `/users/me` | 自分の情報の変更(表示名) | ○ | 200 | — | F-ACC-06 |
| PUT | `/users/me/password` | パスワードの変更 | ○ | 204 | 400 `invalid_current_password`、429 `too_many_requests`(試行回数の上限) | F-ACC-07 |
| DELETE | `/users/me` | アカウントの削除 | ○ | 204 | — | F-ACC-09 |
| POST | `/users/me/email-verification` | 確認コードの送信(再発行。新規登録時はサーバーが自動で送る) | ○ | 202 | 409 `email_already_verified`、429 `too_many_requests` | F-ACC-04 |
| POST | `/users/me/email-verification/confirm` | 確認コードの確認 | ○ | 200 | 400 `invalid_verification_code`・`verification_code_expired` | F-ACC-04 |

### 同期(`/api/users/{user_id}/sessions`)

| メソッド | パス | 名前 | 認証 | 成功 | 主なエラー | 使う機能 |
|---|---|---|---|---|---|---|
| GET | `/users/{user_id}/sessions?last_synced_at=` | 差分取得 | ◎ | 200(変更・削除と`synced_at`、`request_existence_check`) | — | F-SYN-01 |
| POST | `/users/{user_id}/sessions` | 登録(位置情報の点を含む) | ◎ | 201(同じ内容の再送は200) | 409 `id_conflicted`・`deleted` | F-SYN-01 |
| PATCH | `/users/{user_id}/sessions/{session_id}` | 修正(名前・移動手段・お気に入り) | ◎ | 200 | 404 `session_not_found`、409 `deleted` | F-SYN-01、02 |
| DELETE | `/users/{user_id}/sessions/{session_id}` | 削除(tombstone) | ◎ | 204 | 404 `session_not_found` | F-SYN-01 |
| POST | `/users/{user_id}/sessions/{session_id}/restore` | 削除の取り消し(編集内容の反映を含む) | ◎ | 200 | 404 `session_not_found`(パージ済み) | F-SYN-02 |
| POST | `/users/{user_id}/sessions/existence-check` | 削除の突き合わせ | ◎ | 200(サーバーに無いidの一覧) | — | F-SYN-03 |

同期の手順(push → 競合の解決 → pull)と、各エラーを端末がどう扱うかは`docs/design/sync.md`。

### 運用

| メソッド | パス | 名前 | 認証 | 成功 | 主なエラー | 使う機能 |
|---|---|---|---|---|---|---|
| GET | `/health` | ヘルスチェック | × | 200 | 503(DBに接続できない) | F-OPS-06 |

## 全てのエンドポイントに共通するエラー

上の表の「主なエラー」には、エンドポイントに固有のものだけを書いた。次のエラーはどのエンドポイントでも返り得る。

| ステータス | code | 意味 | 端末の扱い |
|---|---|---|---|
| 401 | `unauthenticated` | トークンが無い・不正・ログイン状態が無効 | 再ログインを促す(データは消さない) |
| 401 | `token_expired` | アクセストークンの期限切れ | トークンを更新して、元のリクエストを1回だけやり直す |
| 403 | `forbidden` | 他のユーザーの`user_id`を指定した | — |
| 403 | `email_not_verified` | メールアドレスが未確認(同期APIだけ) | 同期を止める |
| 404 | `user_not_found` | パスの`user_id`のユーザーがいない(管理者が指定した場合だけ) | 同期を止める |
| 404 | `not_found` | 存在しないパス | — |
| 405 | `method_not_allowed` | そのパスでは使えないメソッド(`Allow`ヘッダーで使えるメソッドを返す) | — |
| 413 / 415 / 406 | `payload_too_large` / `unsupported_media_type` / `not_acceptable` | リクエストの形式が違う(406はGETの差分取得だけ) | — |
| 422 | `validation_error` | 入力チェックの失敗(`details`に項目と理由) | — |
| 429 | `too_many_requests` | 送信元のIPごとの流量の上限を超えた(リバースプロキシが返す) | `Retry-After`の秒数だけ待つ |
| 500 | `internal_error` | 想定外のエラー(原因はサーバーのログにだけ出す) | — |
| 502 / 504 | `service_unavailable` | apiにつながらない・応答が時間内に来ない(リバースプロキシが返す) | 同期を後で再試行する |
| 400 | `http_error` | 壊れたリクエスト(リバースプロキシが返す) | — |

`code`の全ての一覧は`backend/app/errors.py`の`ErrorCode`(意味はOpenAPIに載る。`app/schemas/error.py`)。
