# osampo-trackerバックエンドサーバーAPI設計ドラフト

このドキュメントにはサーバー側の挙動のみを記載する。クライアント(frontend)側で必要な対応は
`frontend/docs/ユーザー機能追加に伴う変更予定.md`を参照。

## server
url: https://localhost/api (開発環境。リバースプロキシ経由。`backend/docs/HTTPSとリバースプロキシ.md`)
(以下のendpointsのパスはこのurlからの相対パス。例: `GET /users/{user_id}/sessions` は `https://localhost/api/users/{user_id}/sessions`。
実装: 同期は`backend/app/routers/sessions.py`、認証・ユーザーは`backend/app/routers/auth.py`・`backend/app/routers/users.py`)

OpenAPI(実装から自動生成): apiのコンテナの中の`http://localhost:8080/openapi.json`(リバースプロキシでは公開しない。`docker compose exec api python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/openapi.json').read().decode())"`で取り出せる)
- 役割分担: このドキュメント=判断の理由と処理の手順、OpenAPI=入出力の型・各項目の説明・例・ステータスごとのcode
- OpenAPIの内容(operationId・エラーのcodeの記載・例)は`backend/tests/test_openapi.py`で確認している

## 共通事項

### 判定の順番
各エンドポイントの「処理」の手順は、次の順に判定する(実装の都合で、DBに問い合わせない確認を先に行う):
1. リクエストの形式: bodyのサイズ(413)、Content-Type(415)、Accept(406)
2. 認証と権限: 401(`unauthenticated`・`token_expired`)、403(`forbidden`)、同期APIでは403(`email_not_verified`)
3. ユーザーの存在: 404(`user_not_found`)
4. 入力チェック: 422
5. 業務ルール(sessionの存在・削除済みかどうか等): 404(`session_not_found`)・409

ただし、パスパラメーターの書式の不正(UUIDでない等)は、ユーザーの存在の確認より先に422になる

### 認証と権限
認証の仕組みの詳細は下記「認証のendpoints」と`backend/docs/認証.md`の「認証」。
- ログイン・サインアップ・トークンの更新以外のendpointは、`Authorization: Bearer <アクセストークン>`ヘッダーが必須
- アクセストークンはES256で署名したJWT(有効期限15分)。中身は`sub`(ユーザーID)・`sid`(端末ごとのログイン状態のID)・`type`("access")・
  `iat`・`exp`。ロールはトークンに入れず、リクエストのたびにDBから読む
- リクエストのたびに、トークンの署名・有効期限に加えて、DBで「ユーザーが存在し無効化(`disabled_at`)されていない」
  「`sid`の端末のログイン状態が無効化されていない」ことを確認する(ログアウト・削除・停止がすぐ反映されるようにするため)
- 401(認証できない): トークンがない、署名が不正、トークンの持ち主のユーザーが存在しない・無効化されている、
  端末のログイン状態が無効化されている場合は`unauthenticated`(クライアントは再ログインを促す)。有効期限切れは`token_expired`
  (クライアントはリフレッシュトークンでトークンを更新し、元のリクエストをやり直す)
- 403(権限がない): 認証はできたが、トークンのユーザーが管理者でなく、かつパスパラメーターのuser_idが自分自身でない場合
  再ログインしても結果は変わらない
- 403(`email_not_verified`): 同期API(`/users/{user_id}/sessions/...`)は、トークンのユーザーのメールアドレスの確認が
  済んでいなければ403にする(ログインはできるが同期はできない。確認は下記「メールアドレスの確認のendpoints」)
- 上記の順に判定するので、一般ユーザーに404("user_not_found")が返ることはない(他ユーザーのuser_idを指定すると403で止まり、
  自分自身のユーザーが存在しなければ401で止まる)。404("user_not_found")が返るのは管理者が存在しないuser_idを指定した場合のみで、
  一般ユーザーには他ユーザーの存在有無が分からない
- パスパラメーターのuser_idは操作対象のユーザーを指定するためのもので、秘密の情報ではない(URLやログに残り、JWTの中身も
  暗号化されていない)。本人であることの確認はトークンの署名の検証のみで行う

### リクエストID
- 全てのレスポンスに`X-Request-ID`ヘッダーを付ける(サーバーのアクセスログ・アプリのログ・監査ログの突き合わせに使う)
- IDはリバースプロキシがリクエストごとに作る。クライアントが`X-Request-ID`を送っても使わない(サーバーのログに残るIDを、サーバーが
  作ったものだけにするため)。クライアントは応答の`X-Request-ID`を自分のログに出す(このアプリの端末は出す)。
  詳細は`backend/docs/HTTPSとリバースプロキシ.md`の「リクエストID」
- ログでの振り返りにだけ使い、処理(認証・重複の判定等)には使わない

### エラーレスポンス
- 4xx・5xxのレスポンスbodyは全て以下の形式で返す FastAPIが既定で返すエラー(バリデーションエラーの422、
  存在しないパスへの404など)も例外ハンドラーでこの形式に揃える
    ```
    {
        "code": "session_not_found",   (エラーの種類。クライアントはこれで処理を分岐する)
        "message": "...",   (人が読むための説明。クライアントは分岐に使わない)
        "details": [   (422のときだけ含める。それ以外のエラーではキー自体を含めない)
            {
                "field": "body.move_method",   (不正だった項目。受け取った場所(body/query/path/header)と項目名をドットでつなぐ)
                "reason": "..."   (不正な理由。人が読むための説明)
            }
        ]
    }
    ```
- 同じステータスコードでも意味が異なる場合があるため、クライアントが処理を分岐する必要があるエラーには必ず`code`を付ける。
  `code`の無いエラーは返さない(クライアントが「`session_not_found`以外の404では同期を止める」のように判定しやすくするため)
- 想定外のエラー(500)では、原因(スタックトレース等)はサーバーのログにのみ出し、レスポンスには含めない
- 実装: `app/errors.py`(`ErrorCode`・`AppError`)、`app/error_handlers.py`(例外ハンドラー・bodyのサイズの上限)、
  `app/dependencies.py`(Content-Typeの確認)

### codeの一覧
| code | ステータス | 意味 |
| --- | --- | --- |
| `unauthenticated` | 401 | トークンが無い・署名が不正・トークンの持ち主が存在しない・無効化されている(クライアントは再ログインを促す) |
| `token_expired` | 401 | アクセストークンの有効期限切れ(クライアントはリフレッシュトークンでトークンを更新し、元のリクエストをやり直す) |
| `invalid_credentials` | 401 | ログインの失敗(メールアドレスが無い・パスワードが違うを区別しない) |
| `invalid_refresh_token` | 401 | リフレッシュトークンが無い・期限切れ・使用済み・端末のログイン状態が無効(クライアントは再ログインを促す) |
| `forbidden` | 403 | 認証はできたが、その操作の権限が無い(一般ユーザーが他ユーザーのuser_idを指定した等) |
| `account_disabled` | 403 | アカウントが停止されている(ログインでパスワードが合っていた場合のみ返す) |
| `email_not_verified` | 403 | メールアドレスの確認が済んでいないので同期APIを使えない |
| `user_not_found` | 404 | パスパラメーターのuser_idのユーザーが存在しない |
| `session_not_found` | 404 | 当該ユーザーのsessionとして存在しない(パージ済み・未登録・他ユーザーのもの) |
| `not_found` | 404 | 存在しないパス |
| `method_not_allowed` | 405 | そのパスでは使えないメソッド(Allowヘッダーで使えるメソッドを返す) |
| `not_acceptable` | 406 | Acceptで`application/json`を受け付けていない(GET) |
| `id_conflicted` | 409 | 登録しようとしたidが別のsessionと衝突している |
| `email_already_registered` | 409 | サインアップしようとしたメールアドレスは登録済み |
| `invalid_current_password` | 400 | パスワードの変更で、現在のパスワードが違う(401にしない。クライアントは401をログイン状態の無効として扱うため) |
| `email_already_verified` | 409 | メールアドレスは確認済みなので、確認コードを送らない |
| `invalid_verification_code` | 400 | 確認コードが違う(入力し直せる) |
| `verification_code_expired` | 400 | 有効な確認コードが無い(期限切れ・失敗の上限に達した・未送信。クライアントは再送を促す) |
| `too_many_requests` | 429 | 確認コードの送信の間隔・回数、ログイン・現在のパスワードの確認の試行回数、または送信元のIPごとの流量(リバースプロキシ)の上限に達した(`Retry-After`ヘッダーの秒数だけ待つ) |
| `deleted` | 409 | 対象のsessionが削除済み(tombstone)で、編集内容と競合している |
| `payload_too_large` | 413 | bodyがサイズの上限(10MB)を超えている |
| `unsupported_media_type` | 415 | Content-Typeが`application/json`でない(media typeはContent-Typeの値を指すHTTPの用語) |
| `validation_error` | 422 | 入力チェックの失敗。`details`にどの項目がなぜ不正かを入れる |
| `internal_error` | 500 | 想定外のエラー |
| `service_unavailable` | 502・504 | apiにつながらない・apiの応答が時間内に来ない(リバースプロキシが返す。クライアントは後で再試行する) |
| `http_error` | その他 | 上記に当てはまらないHTTPのエラー |

## endpoints
- GET /users/{user_id}/sessions?last_synced_at=<日時>
    パスパラメーター:
        user_id: usersテーブルに登録されているid
    クエリパラメーター:
        last_synced_at: 最終同期時刻(absentを許容、Time Stamp (UTC))
    header: 
        Authorization: Bearer <token>
        Accept: application/json
    body: なし

    レスポンス:
        header: Content-Type: application/json
        body:
            {
                "synced_at": "2026-10-01T17:30:00.000Z",
                "request_existence_check": false,   (デフォルトはfalse)
                "sessions": [
                    {   (生きているレコードの場合)
                        "id": "11111111-1111-1111-1111-111111111111",   (UUID)
                        "name": "近所のお散歩",
                        "started_at": "2026-10-01T17:00:00.000Z",   (Time Stamp (UTC))
                        "ended_at": "2026-10-01T17:29:00.000Z",   (Time Stamp (UTC))
                        "is_favorite": true,   (bool)
                        "move_method": "walk",   (walk, run, bicycle, car, train, plane, shipのいずれか)
                        "total_distance": 2.0,　 ([km])
                        "duration_seconds": 1740,   ([sec])
                        "elevation_gain": 50.0,   ([m])
                        "max_altitude": 30.0,　(nullable, [m])
                        "min_altitude": 7.5,  (nullable, [m])
                        "updated_at": "2026-10-01T17:30:00.000Z",   (Time Stamp (UTC))
                        "track_points": [
                            {"recorded_at": "2026-10-01T17:00:00.000Z",    (Time Stamp (UTC))
                            "latitude": 37.33003773,
                            "longitude": -122.02088037,
                            "altitude": 12.5},  ([m]、nullは不可)
                            ...
                        ]
                    },
                    {   (削除されたレコードの場合、last_synced_atがnot absentの時のみ)
                        "id": "11111111-1111-1111-1111-111111111111",   (UUID)
                        "deleted_at": "2026-09-30T15:00:00.000Z"   (Time Stamp (UTC)、削除した日時)
                    },
                    ...
                ]
            }

    処理:
        1. Acceptにapplication/jsonがない場合: 406を返す
        2. トークンがない、あるいは無効だった場合: 401を返す
        3. user_id、またはlast_synced_atの書式が不正な場合、またはlast_synced_atがサーバー時刻より大きい場合: 422を返す
        4. header の認証情報に紐づいたユーザーが管理者でなく、かつuser_id と異なる場合: 403 を返す
        5. user_idが存在しない場合: 404("code": "user_not_found")を返す
        6. synced_atに現在のサーバー時刻(UTC)を入力する
        7. last_synced_atがabsent:　該当ユーザーのsessionのうちdeleted_atがnullのものを全て拾ってくる
           not absent: 該当ユーザーのsessionのうちupdated_atがlast_synced_atよりも後のものを全て拾ってくる
        8. last_synced_atがnot absentかつ(サーバー時刻 - パージ期間)より前: request_existence_checkをtrueにする
        9. json形式に変換して200で返す
    備考:
        - 現行実装のp_sync_timeは廃止する(サーバー時刻を基準とするため) リクエストした端末自身がpushしたsessionもレスポンスに含まれる
        - パージはdeleted_at(削除した日時)がパージ期間より古いtombstoneを物理削除する(現行のパージ期間は90日)
        - request_existence_checkがtrueの場合、パージ済みの削除はレスポンスに含まれない可能性がある(`POST /users/{user_id}/sessions/existence-check`で整合性チェックを行う)
        - sessionsの並び順はstarted_atの昇順
        - track_pointsの並び順はrecorded_atの昇順
        - 認証(401・403)は共通事項の「認証と権限」の通り(同期APIはメールアドレスの確認済みが必須)
        - ページングは行わない(開発用データの件数では不要で、カーソルの扱いが複雑になるため)。
          必要になった場合は、このGETではsessionのid・updated_at(tombstoneはdeleted_at)の一覧のみを返し、本体は
          `GET /users/{user_id}/sessions/{session_id}`で1件ずつ(または数件ずつまとめて)取得する形にする
          (途中で失敗しても取得済みの分は残るので、残りだけをやり直せる)

- POST /users/{user_id}/sessions
    パスパラメーター:
        user_id: usersテーブルに登録されているid
    header:
        Authorization: Bearer <token>
        Content-Type: application/json
    body:
        {
            "id": "11111111-1111-1111-1111-111111111111",   (UUID)
            "name": "近所のお散歩",   (>= 1文字、<= 100文字)
            "started_at": "2026-10-01T17:00:00.000Z",   (Time Stamp (UTC))
            "ended_at": "2026-10-01T17:29:00.000Z",   (Time Stamp (UTC))
            "is_favorite": true,   (bool)
            "move_method": "walk",   (walk, run, bicycle, car, train, plane, shipのいずれか)
            "total_distance": 2.0,   ([km])
            "duration_seconds": 1740,   ([sec])
            "elevation_gain": 50.0,   ([m])
            "max_altitude": 30.0,   (nullable, [m])
            "min_altitude": 7.5,   (nullable, [m])
            "track_points": [
                {
                    "recorded_at": "2026-10-01T17:00:00.000Z",   (Time Stamp (UTC))
                    "latitude": 37.33003773,   (double precision, -90~90)
                    "longitude": -122.02088037,   (double precision, -180~180)
                    "altitude": 12.5   ([m]、nullは不可。高度の信頼度が低い場合は端末が前回の点の高度で補う)
                },
                ...
            ]
        }

    レスポンス:
        header:
            Content-Type: application/json
        body:
            {
                "updated_at": "2026-10-01T17:30:00.000Z"   (Time Stamp (UTC))
            }
    
    処理:
        1. リクエストのbodyサイズが10MBを超える場合: 413を返す
        2. Content-Typeがapplication/jsonでない場合: 415を返す
        3. トークンがない、あるいは無効だった場合: 401を返す
        4. header の認証情報に紐づいたユーザーが管理者でなく、かつパスパラメーターのuser_id と異なる場合: 403 を返す
        5. パスパラメーターのuser_idが存在しない場合: 404("code": "user_not_found")を返す
        6. updated_atに現在のサーバー時刻(UTC)を入力する
        7. validationを行って不正があった場合: 422を返す
        8. sessionsテーブル(全ユーザー)でidが等しいレコードがあった場合:
            他ユーザーのレコードだった場合、または特定項目(\*1)が1つでも異なる場合: 409("code": "id_conflicted")を返す
            当該ユーザーのレコードであり、特定項目(\*1)が完全に一致する場合:
                該当レコードのdeleted_atがnullでない場合:
                    特定項目(\*2)が1つでも異なる場合: 409("code": "deleted")を返す
                    特定項目(\*2)が完全に一致する場合: レスポンスbodyのupdated_atを当該レコードのupdated_atに変更して200を返す
                該当レコードのdeleted_atがnullの場合:
                    特定項目(\*2)が1つでも異なる場合: 特定項目(\*2)とupdated_atのみを更新して200を返す
                    特定項目(\*2)が完全に一致する場合: レスポンスbodyのupdated_atを当該レコードのupdated_atに変更して200を返す
        9. 登録処理を行い201を返す
    備考
        - リモートDBには終了したセッションのみを記録する方針なので、ended_atはnon-nullとする
        - uvicornとFastAPIは仕様上リクエストサイズの制限がないため、不正なリクエストによって処理が停滞しないようにbodyに10MBの制限をかける
        - 特定項目\*1: started_at, ended_at, total_distance, duration_seconds, elevation_gain, max_altitude, min_altitude
        - 特定項目\*2: name, is_favorite, move_method
        - 現行のDB設定ではelevation_gain, max_altitude, min_altitudeがREALなのでマイグレーションでdouble precisionに変更する必要がある
        - max_altitude, min_altitudeの比較時にnullチェックが必要(SQLではNULL = NULLが真にならない)
        - validationチェックの項目は以下の通り
            - idがUUID型である
            - nameが1文字以上100文字以内である
            - ended_atがstarted_at以降である
            - move_methodがwalk, run, bicycle, car, train, plane, shipのいずれかである
            - total_distance, duration_seconds, elevation_gainが0以上
            - latitudeが-90~90, longitudeが-180~180
            - nullはmax_altitude, min_altitudeのみ許す(track_pointsのaltitudeはnull不可。locationが高度込みの点(POINTZ)のため)
        - 万が一同時に同じIDのセッションが登録されようとした時のために、登録処理はINSERT ... ON CONFLICT DO NOTHINGで行い、DO NOTHINGで挿入が0件の場合は手順8からやり直す
        - セッションとトラックポイントは1つのトランザクションで登録する

- PATCH /users/{user_id}/sessions/{session_id}
    パスパラメーター:
        user_id: usersテーブルに登録されているid
        session_id: 修正対象のsessionのid
    header:
        Authorization: Bearer <token>
        Content-Type: application/json
    body:
        {
            "name": "近所のお散歩",   (>= 1文字、<= 100文字)
            "move_method": "walk",   (walk, run, bicycle, car, train, plane, shipのいずれか)
            "is_favorite": true   (bool)
        }

    レスポンス:
        header:
            Content-Type: application/json
        body:
            {
                "updated_at": "2026-10-01T17:30:00.000Z"   (Time Stamp (UTC))
            }

    処理:
        1. リクエストのbodyサイズが10MBを超える場合: 413を返す
        2. Content-Typeがapplication/jsonでない場合: 415を返す
        3. トークンがない、あるいは無効だった場合: 401を返す
        4. header の認証情報に紐づいたユーザーが管理者でなく、かつパスパラメーターのuser_id と異なる場合: 403 を返す
        5. パスパラメーターのuser_idが存在しない場合: 404("code": "user_not_found")を返す
        6. updated_atに現在のサーバー時刻(UTC)を入力する
        7. validationを行って不正があった場合: 422を返す
        8. sessionsテーブルをidとパスパラメーターのuser_idの両方で絞って検索し、該当するレコードがない場合: 404("code": "session_not_found")を返す
        9. 該当レコードのdeleted_atがnullでない場合: 409("code": "deleted")を返す
        10. 特定項目(\*2)が完全に一致する場合: レスポンスbodyのupdated_atを当該レコードのupdated_atに変更して200を返す
        11. 特定項目(\*2)が1つでも異なる場合: 特定項目(\*2)とupdated_atのみを更新して200を返す
    備考
        - bodyは特定項目(\*2)の3項目全てを必須とする(端末側で変更した項目を追跡しなくて済むようにするため)
        - 特定項目(\*2)以外の項目がbodyに含まれる場合は422を返す(Pydanticのextra="forbid"。端末のバグで不変の項目を変えようとしても気づけるようにするため)
        - 他ユーザーのsessionのidを指定した場合も、存在しない場合と区別せず404を返す(403を返すと、そのidのsessionを誰かが持っていることが分かってしまうため)
        - 3項目全てを毎回受け取るので、同じPATCHが2回届いても結果は変わらない
        - validationチェックの項目は以下の通り
            - session_idがUUID型である
            - 特定項目(\*2)の3項目が全て存在し、いずれもnullでない
            - nameが1文字以上100文字以内である
            - move_methodがwalk, run, bicycle, car, train, plane, shipのいずれかである
        - 409("deleted")はパージ前のtombstone、404("session_not_found")はパージ済み(または他ユーザーのもの・未登録)を表す
        - 同一ユーザーが複数端末で同時に操作することは想定しないため、競合の検出は削除済みかどうかのみで、他端末での編集は上書きする(楽観ロックは入れない)

- DELETE /users/{user_id}/sessions/{session_id}
    パスパラメーター:
        user_id: usersテーブルに登録されているid
        session_id: 削除対象のsessionのid
    header:
        Authorization: Bearer <token>
    body: なし

    レスポンス:
        body: なし

    処理:
        1. トークンがない、あるいは無効だった場合: 401を返す
        2. user_id、またはsession_idの書式が不正な場合: 422を返す
        3. header の認証情報に紐づいたユーザーが管理者でなく、かつパスパラメーターのuser_id と異なる場合: 403 を返す
        4. パスパラメーターのuser_idが存在しない場合: 404("code": "user_not_found")を返す
        5. sessionsテーブルをidとパスパラメーターのuser_idの両方で絞って検索し、該当するレコードがない場合: 404("code": "session_not_found")を返す
        6. 該当レコードのdeleted_atがnullでない場合: 何も変更せずに204を返す
        7. 該当レコードのdeleted_atとupdated_atに現在のサーバー時刻(UTC)を入力して204を返す
    備考
        - deleted_atは削除した日時(サーバー時刻)を表す(現行実装は削除予定時刻)
        - パージ(worker)はdeleted_atがパージ期間(90日)より古いtombstoneを物理削除する
        - 既にtombstoneの場合にdeleted_atを更新しないのは、パージまでの期間が延びることと、他端末に同じtombstoneが差分として再度届くことを避けるため
        - 該当レコードがない場合(パージ済み・未登録・他ユーザーのもの)を204ではなく404にするのは、PATCHと判定・エラーコードを揃え、
          将来ログを実装した際に「削除した」のか「元から無かった」のかを区別できるようにするため。
          どちらの場合もサーバーにそのsessionが存在しない状態になるので、同じDELETEを繰り返してもサーバーの状態は変わらない(冪等)
        - tombstoneになってもsessionとtrack_pointsのデータは残す(復活と、POSTの再送時の比較に必要なため)
        - 他端末での編集より後に届いた削除は、その編集を上書きして削除する(PATCHと同様、楽観ロックは入れない)

- POST /users/{user_id}/sessions/{session_id}/restore
    パスパラメーター:
        user_id: usersテーブルに登録されているid
        session_id: 削除を取り消す対象のsessionのid
    header:
        Authorization: Bearer <token>
        Content-Type: application/json
    body:
        {
            "name": "近所のお散歩",   (>= 1文字、<= 100文字)
            "move_method": "walk",   (walk, run, bicycle, car, train, plane, shipのいずれか)
            "is_favorite": true   (bool)
        }

    レスポンス:
        header:
            Content-Type: application/json
        body:
            {
                "updated_at": "2026-10-01T17:30:00.000Z"   (Time Stamp (UTC))
            }

    処理:
        1. リクエストのbodyサイズが10MBを超える場合: 413を返す
        2. Content-Typeがapplication/jsonでない場合: 415を返す
        3. トークンがない、あるいは無効だった場合: 401を返す
        4. header の認証情報に紐づいたユーザーが管理者でなく、かつパスパラメーターのuser_id と異なる場合: 403 を返す
        5. パスパラメーターのuser_idが存在しない場合: 404("code": "user_not_found")を返す
        6. updated_atに現在のサーバー時刻(UTC)を入力する
        7. validationを行って不正があった場合: 422を返す(項目はPATCHと同じ)
        8. sessionsテーブルをidとパスパラメーターのuser_idの両方で絞って検索し、該当するレコードがない場合: 404("code": "session_not_found")を返す
        9. 該当レコードのdeleted_atがnullでない場合: deleted_atをnullにし、特定項目(\*2)とupdated_atを更新して200を返す
        10. 該当レコードのdeleted_atがnullの場合(復活済み): PATCHの手順10・11と同じ
            特定項目(\*2)が完全に一致する場合: レスポンスbodyのupdated_atを当該レコードのupdated_atに変更して200を返す
            特定項目(\*2)が1つでも異なる場合: 特定項目(\*2)とupdated_atのみを更新して200を返す
    備考
        - restoreは削除と編集が競合した際に編集内容を残して削除を取り消すためのエンドポイントで、編集項目と削除取り消しの両方を同時に行う
        - bodyの扱い(3項目全て必須、それ以外の項目は422)はPATCHと同じ
        - 処理名で終わるパスはリソースではなく操作を表すため、メソッドはPOSTとする
        - 既に復活済みの場合も200を返すので、同じrestoreを繰り返してもサーバーの状態は変わらない(冪等)
        - 復活したsessionはupdated_atが更新されるので、tombstoneを受け取ってローカルから削除していた他端末にも、
          次のGETで生きているsessionとして全データ(track_pointsを含む)が届き、復活する
        - 404("session_not_found")はパージ済みで、復活させる対象が残っていないことを表す
        - パージと同時に実行された場合は、トランザクションでどちらか一方が先に確定する。restoreが先ならdeleted_atがnullになり
          パージの対象から外れ、パージが先ならrestoreは404("session_not_found")になる

- POST /users/{user_id}/sessions/existence-check
    パスパラメーター:
        user_id: usersテーブルに登録されているid
    header:
        Authorization: Bearer <token>
        Content-Type: application/json
    body:
        {
            "session_ids": [
                "11111111-1111-1111-1111-111111111111",   (UUID)
                ...
            ]
        }

    レスポンス:
        header:
            Content-Type: application/json
        body:
            {
                "missing_session_ids": [
                    "11111111-1111-1111-1111-111111111111",   (UUID)
                    ...
                ]
            }

    処理:
        1. リクエストのbodyサイズが10MBを超える場合: 413を返す
        2. Content-Typeがapplication/jsonでない場合: 415を返す
        3. トークンがない、あるいは無効だった場合: 401を返す
        4. header の認証情報に紐づいたユーザーが管理者でなく、かつパスパラメーターのuser_id と異なる場合: 403 を返す
        5. パスパラメーターのuser_idが存在しない場合: 404("code": "user_not_found")を返す
        6. validationを行って不正があった場合: 422を返す
        7. session_idsのうち、当該ユーザーの生きている(deleted_atがnullの)sessionとして存在するものを検索する
        8. session_idsから7の結果を除いたものをmissing_session_idsとして200で返す
    備考
        - GETでrequest_existence_checkがtrueだった場合に、パージ済みで差分に含まれなかった削除を補うためのエンドポイント
        - DBは変更しないが、IDが多いとクエリ文字列の長さの上限にかかるためPOSTにする
        - tombstoneのsessionも「存在しない」として返す
        - 他ユーザーのsessionのIDも「存在しない」として返す(PATCH・DELETEの404と同様、他ユーザーのデータの有無を伝えないため)
        - 返すのは存在しないIDのみ。削除の漏れは通常ごく少数なので、レスポンスが小さくなる
        - IDの数に個別の上限は設けず、bodyの10MB制限のみとする(約25万件に相当し、個人のsession数では十分)
        - 重複したIDは1つにまとめて扱う。空の配列の場合は空のmissing_session_idsを200で返す
        - missing_session_idsの並び順は保証しない
        - サーバーは突き合わせの状態を持たない(どのGETに続く突き合わせかは関知しない)
        - validationチェックの項目は以下の通り
            - session_idsが存在し、配列である
            - session_idsの要素が全てUUID型である

## 認証のendpoints

トークンを返すendpoint(signup・login・refresh)のレスポンスは共通の形式にする:
    ```
    {
        "access_token": "eyJ...",   (ES256のJWT。有効期限15分)
        "refresh_token": "...",   (256ビットの乱数をURLセーフなBase64にした文字列。有効期限30日)
        "token_type": "Bearer",
        "expires_in": 900,   (アクセストークンの有効期限までの秒数)
        "user": { "id": "...", "email": "...", "display_name": "...", "email_verified": false, "role": "user" }
    }
    ```
端末ごとのログイン状態(`auth_sessions`)とリフレッシュトークンの系列はセットで管理する。端末IDはクライアントが初回起動時に生成した
UUIDを受け取る(ハードウェアの情報はOSが提供しないため)。同じ端末で再びログインした場合は、その端末の古いログイン状態を無効にする。

- POST /auth/signup
    body: { "email": "...", "password": "...", "display_name": "...", "device_id": "<UUID>", "device_name": "..." }
        - email: メールアドレスの形式、255文字以内。大文字小文字を区別せず一意(保存時に小文字にする)
        - password: 8文字以上128文字以内。文字の種類は強制しない(MFAは無い。NISTの「パスワードのみなら15文字以上」の推奨とは
          意識的に違えている)
        - display_name: 省略可(1〜50文字)。省略時はメールアドレスの@より前
        - device_name: 省略可(端末の表示名。100文字以内)
    レスポンス: 201 + トークンの形式。作成直後は`email_verified`がfalse(ログインはできるが同期はできない)
    エラー: 409(`email_already_registered`)、422
    備考:
        - 登録済みのメールアドレスを409で返すと、メールアドレスの登録の有無が分かってしまう。個人向けアプリなので許容する
          (本番運用の前に見直す観点)
        - 作成と同じトランザクションで、メールアドレスの確認コードを送る(下記「メールアドレスの確認のendpoints」。
          24時間あたりの送信回数の1回に数える)

- POST /auth/login
    body: { "email": "...", "password": "...", "device_id": "<UUID>", "device_name": "..." }
    レスポンス: 200 + トークンの形式
    処理:
        1. そのメールアドレスが試行回数の上限でロック中の場合: パスワードを照合せずに429(`too_many_requests`。待つ秒数は`Retry-After`)。
           直近の成功より後の`invalid_credentials`の失敗が15分以内に10回たまったら、最後の失敗から15分ロックする。
           存在しないメールアドレスも同じように数える(ロックの有無で登録の有無が分からないように)。ロック中の拒否は失敗に数えない
        2. メールアドレスのユーザーが無い、またはパスワードが違う場合: 401(`invalid_credentials`)
           (ユーザーが無い場合もダミーのハッシュで検証して、応答時間で区別できないようにする)
        3. アカウントが停止(`disabled_at`がnullでない)されている場合: 403(`account_disabled`)
        4. 同じユーザー・同じ端末の有効なログイン状態があれば無効にし、新しいログイン状態とリフレッシュトークンを作ってトークンを返す
    備考: メールアドレスの確認が済んでいなくてもログインできる。成功・失敗・ロック中の拒否は監査ログに残す

- POST /auth/refresh
    body: { "refresh_token": "..." }   (Authorizationヘッダーは不要。アクセストークンが期限切れでも使えるようにするため)
    レスポンス: 200 + トークンの形式(新しいリフレッシュトークンを含む)
    処理:
        1. リフレッシュトークンのハッシュで検索し、無い・期限切れ・端末のログイン状態が無効・ユーザーが無いか停止中の場合:
           401(`invalid_refresh_token`)
        2. 使用済み(`used_at`がnullでない)の場合: 盗まれた可能性があるので、その端末のログイン状態を無効にして
           401(`invalid_refresh_token`)。その端末では再ログインが必要になる(アカウント自体はロックしない。圏外でレスポンスが
           届かずにクライアントが古いトークンで再試行した場合も、この扱いになる)
        3. 使ったトークンに`used_at`を入れ、新しいリフレッシュトークン(有効期限は今から30日)とアクセストークンを発行する
           (ローテーション。使うたびに期限が延びる)

- POST /auth/logout
    header: Authorization: Bearer <アクセストークン>
    レスポンス: 204
    処理: トークンの`sid`の端末のログイン状態を無効にする。その端末のリフレッシュトークンもアクセストークンも、すぐに使えなくなる
    備考: アクセストークンが期限切れの場合、クライアントは先にrefreshしてからlogoutする。refreshも失敗した場合は、
          サーバー側のログイン状態は既に無効なので、クライアントはトークンを消すだけでよい

- GET /users/me
    レスポンス: 200 { "id", "email", "display_name", "email_verified", "role", "created_at" }

- PATCH /users/me
    body: { "display_name": "..." }   (1〜50文字。それ以外の項目は422。メールアドレスの変更は未実装(予定)、
          パスワードの変更は下記の別のendpoint)
    レスポンス: 200 + GET /users/meと同じ形式

- PUT /users/me/password(2026-10-14に設計)
    body: { "current_password": "...", "new_password": "..." }
        - new_password: サインアップと同じ条件(8〜128文字)。今と同じパスワードも受け付ける
    レスポンス: 204
    処理:
        1. 現在のパスワードの確認が試行回数の上限でロック中: 照合せずに429(`too_many_requests`。待つ秒数は`Retry-After`)。
           ログインとは別に、ユーザーごとに数える(直近の変更の成功より後の失敗が15分以内に10回で、最後の失敗から15分)
        2. 現在のパスワードが違う: 400(`invalid_current_password`)。何も変えない
        3. 新しいパスワードのハッシュを保存し、この端末(アクセストークンの`sid`)以外のログイン状態を全て無効にする
           (パスワードが漏れていた場合に、他の端末に残った攻撃者を締め出すため。この端末はログインしたまま)
        4. 変更を知らせるメールを本人に送る(outboxに積む。乗っ取りに早く気づけるように)
    備考:
        - 現在のパスワードの違いを401にしないのは、クライアントが401(`unauthenticated`)を「ログイン状態が無効になった」として
          扱い、再ログインを求めてしまうため。「認証できない」ではなく「入力が違う」として400にする
        - 現在のパスワードの総当たりは、ログイン中の端末(盗んだトークン等)からしかできない。ログインとは攻撃者が違うので別に数える
          (合算すると、盗んだトークンでの間違いで本人がログインできなくなる・ログインの推測で本人がパスワードを変えられなくなる)

- DELETE /users/me
    レスポンス: 204
    処理: ユーザーを物理削除する(tombstoneは残さない)。外部キーのON DELETE CASCADEで、sessions・track_points・
          端末のログイン状態・リフレッシュトークンも一緒に消える
    備考:
        - アプリの審査(App Storeの審査ガイドライン5.1.1(v)、Google Playのアカウント削除の要件)では、アプリ内からのアカウントと
          関連データの削除が求められる。停止(`disabled_at`)では足りない
        - 他の端末は次のリクエストで401(`unauthenticated`)になる
        - 将来のローカルアカウントへの変更(通常→ローカル)は、このendpointでサーバーのデータを削除し、端末のデータを残す形で行う

## メールアドレスの確認のendpoints

設計(テーブル・流れ・判断の理由)は`backend/docs/メール.md`の「メールアドレスの確認コード」。
確認コードは6桁の数字で、有効期限は10分。サインアップ時に自動で送り、届かなければ再送する。

- POST /users/me/email-verification
    header: Authorization: Bearer <アクセストークン>   (bodyは無い)
    レスポンス: 202 { "expires_in": 600, "resend_available_in": 60 }
        - expires_in: 送ったコードの有効期限までの秒数
        - resend_available_in: 次に再送できるまでの秒数(画面の再送ボタンを押せるようにするまでの待ち時間に使う)
        - 202: メールは受け付けて送信待ちに積んだだけで、まだ送っていない(workerが数秒以内に送る)
    処理:
        1. 確認済みなら409(`email_already_verified`)。送らない
        2. 前回の送信から60秒経っていない、または24時間あたりの送信回数(5回)に達している: 429(`too_many_requests`)。
           送れるようになるまでの秒数を`Retry-After`ヘッダーで返す
        3. 新しいコードを作って送る。前のコードは使えなくなり、前のコードのメールがまだ送られていなければ取り消す
    備考: GETではなくPOSTにするのは、コードを作り・メールを送り・回数を数える(状態を変える)操作で、コードはレスポンスではなく
          メールで届くため

- POST /users/me/email-verification/confirm
    header: Authorization: Bearer <アクセストークン>
    body: { "code": "123456" }   (6桁の数字の文字列。それ以外は422)
    レスポンス: 200 + GET /users/meと同じ形式(`email_verified`がtrue)
    処理:
        1. 確認済みなら、コードを見ずに200
        2. 有効なコードが無い(期限切れ・失敗の上限に達した・まだ送っていない): 400(`verification_code_expired`)
        3. コードが違う: 400(`invalid_verification_code`)。同じコードで5回間違えると、そのコードは使えなくなる
           (以降は`verification_code_expired`。再送で新しいコードを受け取る)
        4. コードが合う: メールアドレスを確認済みにする。以降、同期APIが使える
    備考: 確認済みで200を返すのは、確認に成功したのにレスポンスが届かず(圏外等)クライアントが再送した場合に、
          失敗に見えないようにするため(コードは使用済みで消えているので、照合すると失敗になる)
