# メール

メール送信の基盤(outbox + worker)と、メールアドレスの確認コードの設計。2026-11-10時点のmainの実装を正とする。

## メール送信の基盤

このアプリでは、メールはcomposeの中のMailpitまで送り、外部の送信サービスは使わない(本物のメールは送らない)。ここでは送信基盤
(outbox + `worker`)の設計を書く。送るメールは、メールアドレスの確認コード(下記)と、パスワードの変更の通知(`backend/docs/auth.md`の
「PUT /users/me/password」)。「Tips(外部のサーバーで送る場合)」は、Mailpitまでなので実装していないが、送信サービスを使うときに気にすべき観点。

### 流れ

```
api(業務の処理と同じトランザクションで outbox_emails に1行積む) ─→ commit
worker(5秒ごと) ─→ 送る時刻が来た行を1行ずつロックして取り出す ─→ smtplibでMailpitへ送る ─→ 結果を書いてcommit
```

- apiはoutboxに積むだけで、SMTPには接続しない(SMTPの接続情報もapiには渡さない)。SMTPが止まっていてもapiの応答は遅れない
- outboxは「少なくとも1回は送る(at-least-once)」。SMTPが受け取った後、結果をDBに書く前にworkerが落ちると、次の起動で同じメールを
  もう一度送る。二重に届いて困るメールを作るときは、その種類ごとに対策を考える(確認コードは2通届いても害が小さいので許容する)

### テーブル`outbox_emails`(マイグレーション0005)

| 列 | 型 | 制約 | 内容 |
|---|---|---|---|
| `id` | UUID | 主キー | |
| `recipient_user_id` | UUID | null可、FK(`users.id`、ON DELETE CASCADE) | **宛先**のユーザー(差出人はアプリ共通の`MAIL_FROM`なので行ごとには持たない。操作した人も持たない)。アカウントの削除で送信待ち・送信の記録も消す(関連データの物理削除の方針に合わせる)。ユーザーに紐づかないメールのためにnullを許す |
| `to_address` | VARCHAR(255) | NOT NULL | 宛先のメールアドレス(積んだ時点のもの)。`users.email`から引かずに持つ(下記) |
| `subject` | VARCHAR(200) | NOT NULL | 件名 |
| `body` | TEXT | null可 | 本文(テキストのみ)。**送信に成功したらnullにする**(確認コードが平文で入るため) |
| `attempts` | INTEGER | NOT NULL、既定0 | 送信を試みた回数 |
| `next_attempt_at` | timestamptz | NOT NULL | 次に送信を試みる日時。積んだ時点では積んだ日時 |
| `status` | VARCHAR(20) | NOT NULL、CHECK | `pending`(送信待ち)・`sent`(送信済み)・`failed`(諦めた)・`cancelled`(送る必要が無くなった) |
| `completed_at` | timestamptz | null可 | 送信済みになった日時(SMTPサーバーが受け取った日時。相手に届いた日時ではない)、または諦めた・取り消した日時。`pending`ならnull |
| `send_deadline` | timestamptz | null可 | この日時を過ぎたら送らない(マイグレーション0006)。確認コードのメールではコードの有効期限。nullなら期限なし |
| `created_at` | timestamptz | NOT NULL | 積んだ日時 |

- 状態は`status`の1列で表す(「どちらか一方しか入らない2つの日時」にしない)
- `to_address`を持つ理由: 積んでから送るまでの間にアドレスが変わっても、積んだ時点の宛先に送る(まだ`users.email`になっていない
  アドレスにも送れる)。また、ユーザーの識別は`id`で、メールアドレスはアカウントの削除で空き、別の人が登録しうるので、送った記録には
  送った時点のアドレスを残す
- 失敗の理由はDBに持たず、workerのログに行のidと一緒に出す(理由を調べるのはログの役割とし、DBには「いつ・誰に・何を・どうなったか」だけを残す)
- インデックス: 送信待ちの検索用に`next_attempt_at`の部分インデックス(`status = 'pending'`の行のみ)、
  `recipient_user_id`(アカウントの削除のCASCADE用)、パージ用に`created_at`
- 送信済みの行は、本文を消して「いつ誰に何の件名で送ったか」の記録として残す(「メールが届かない」という問い合わせの調査用)

### worker の送信ジョブ

- APSchedulerで5秒ごとに実行する(`MAIL_POLL_INTERVAL_SECONDS`、既定5)。前回の実行が終わっていなければ重ねて実行しない
- 1回の実行で、次を送信待ちが無くなるまで(最大20通まで)繰り返す:
  1. 送信待ちで`next_attempt_at`が過ぎた行を、`next_attempt_at`の古い順に1行、`SELECT ... FOR UPDATE SKIP LOCKED`で取り出す
     (workerは1つだけ起動する前提だが、複数になってもロックされた行を飛ばすので同じ行を同時に送らない)
  2. smtplibで送る(smtplibは同期のライブラリなので、`asyncio.to_thread`で別スレッドで動かし、イベントループを止めない)
  3. 結果(`status`・`attempts`・`next_attempt_at`・`completed_at`、成功なら本文をnullに)を書いてcommitする
     (1通ずつcommitするので、途中で落ちても送った分の結果は残る)
- 送るメールのヘッダー: `From`(`MAIL_FROM`)、`To`、`Subject`、`Date`、`Message-ID`(送信のたびに作る)。本文はUTF-8のテキストのみ

### 失敗の扱い

- 失敗を2種類に分ける(`app/mail.py`の`classify_smtp_error`):
  - **恒久的な失敗**: SMTPサーバーが宛先・本文を5xxで拒否した(宛先が存在しない等)。何度送っても結果が変わらないので、再送せずすぐに諦める
  - **一時的な失敗**: 4xxの応答、接続できない、タイムアウトなど。間隔をあけて再送する。想定外の例外も再送の対象にしてログで気づけるようにする
  - 認証の失敗・差出人の拒否も5xxだが、一時的な失敗として扱う。メールごとの問題ではなく設定の誤りで
    全てのメールに共通するため、1通ずつすぐに諦めると、設定を直すまでに積まれたメールが全て失われる。再送の間にログで気づいて直す
- 再送の間隔は倍にしていく(指数バックオフ): 1回目の失敗から1分、2分、4分、8分。試行は合計5回まで(`MAIL_MAX_ATTEMPTS`、既定5)で、
  5回目も失敗したら諦める(`status`を`failed`にする)。同じ回数で長い障害(約15分)をカバーでき、復旧直後のサーバーに再送が集中しにくい
- 失敗の理由(SMTPの応答・例外)と、再送するか諦めたかはworkerのログに出す(宛先のアドレスはログに出さず、行のidで追う)
- `send_deadline`を過ぎた送信待ちの行は、送らずに`failed`にしてログに出す(SMTPの不調で送信が遅れ、届いた時点で
  確認コードが期限切れになっているメールを送らないため)。送信待ちの行を取り出した時点で判定する
- Tips(外部のサーバーで送る場合):
  - 送信サービスは送信速度の上限を超えると一時的な失敗(SESなら「Throttling」)を返す。再送の間隔にランダムなずれ(ジッター)を足すと、
    多数のメールの再送が同じ瞬間に重なるのを避けられる
  - SMTPサーバーが受け取った後に相手のサーバーで届かなかった場合(バウンス)は、送信の応答ではなく後から非同期に通知される。
    これを受け取るには、送信サービスからの通知(SESならSNS等)を受ける仕組みが別に要る(Mailpitでは起きない)

### 保持とパージ

- `status`が`sent`・`failed`・`cancelled`の行は、`created_at`から90日経ったら物理削除する(`OUTBOX_RETENTION_DAYS`、既定90)。パージのジョブ(24時間ごと。`backend/docs/sync-api.md`の「パージ(worker)」)で行う
- Tips(外部のサーバーで送る場合): 送信サービスの側にも、宛先・件名・送信の結果のログが残る。個人情報の保持期間を決めるときは、
  アプリのDBだけでなく送信サービス側の保持期間も確認する

### 設定(全て省略可で、既定はcomposeの中のMailpit)

| 項目 | 既定 | 内容 |
|---|---|---|
| `SMTP_HOST`・`SMTP_PORT` | `mailpit`・`1025` | 送信先のSMTPサーバー |
| `SMTP_USERNAME`・`SMTP_PASSWORD` | なし | SMTPの認証(Mailpitは不要) |
| `SMTP_STARTTLS` | false | 接続後にTLSへ切り替えるか(切り替えるときは、システムの信頼する証明書でサーバーの証明書とホスト名を検証する) |
| `SMTP_TIMEOUT_SECONDS` | 10 | 接続・送信のタイムアウト(composeが渡していないので、既定値で動いている) |
| `MAIL_FROM` | `osampo-tracker <no-reply@osampo-tracker.local>` | 差出人 |
| `MAIL_POLL_INTERVAL_SECONDS`・`MAIL_MAX_ATTEMPTS`・`OUTBOX_RETENTION_DAYS` | 5・5・90 | 上記の通り |

- SMTPの設定はcomposeで`worker`にだけ渡す。`worker`は`mailpit`の起動後に起動する(`depends_on`)
- Tips(外部のサーバーで送る場合): 送信サービスへは587番+STARTTLS(または465番)で接続し、認証情報(SMTP用のユーザー名・パスワード、
  またはAPIキー)は`.env`等の秘密情報として扱う。Fromのドメインは、送信サービスでドメイン認証(SPF・DKIM)を済ませたものにする

### 実装

- `app/models/outbox_email.py`(テーブル)、`migrations/versions/0005_outbox_emails.py`
- `app/services/mail_service.py`: `enqueue_email`(apiから積む。commitは呼び出し元)、`send_pending_emails`(workerから送る。
  送る関数を引数で受け取るので、テストではSMTPに接続しないものに差し替える)
- `app/mail.py`: メールの組み立て(`From`・`To`・`Subject`・`Date`・`Message-ID`)、smtplibでの送信、失敗の振り分け
- `app/worker.py`の`send_mail_job`、`app/services/purge_service.py`の`purge_old_outbox_emails`、`app/cli.py`の`send-test-mail`

### 確認の方法

- pytest: 送信の部分(SMTPに渡す関数)をテスト用のものに差し替えて、SMTPに接続せずに検証する
  - 送信待ちの行が送られ、`status`が`sent`になり本文が消えること / 時刻が来ていない行・送信済み・諦めた行は送らないこと
  - 一時的な失敗で`attempts`が増え`next_attempt_at`が倍の間隔で延びること / 5回目の失敗で諦めること / 恒久的な失敗ですぐ諦めること
  - パージで90日より古い送信済み・諦めた・取り消した行だけが消え、送信待ちは残ること
- 手動(ホスト側): 開発用のコマンド`python -m app.cli send-test-mail <宛先>`でoutboxに1通積み、Mailpitの画面(`http://localhost:8025`)で
  届いたことを確かめる。`docker compose stop mailpit`で止めてから積むと再送の様子(workerのログ・`outbox_emails`の行)を観察でき、
  `start`で戻すと送られる

## メールアドレスの確認コード

メール送信の基盤(上記)の上に載せる。
APIの処理の手順は下記「エンドポイント」。

### 方針

- 確認はリンクではなく6桁のコードの入力。コードはサインアップ時に自動で送り、届かなければ利用者が再送する
- コードはargon2のハッシュで保存する(パスワードと同じ`pwdlib`)。6桁は100万通りしか無いので、DBが漏れればどのハッシュでも
  総当たりで割り出せる。守りの本体は10分の有効期限と入力の失敗の上限で、漏れても使える時間が短いことで許容する
  (サーバーだけが持つ鍵を混ぜるHMACにすればDBの漏洩だけでは割り出せないが、鍵の管理が増えるので使わない)
- 制限は3つ。失敗の回数・送信の回数はリクエストをまたいで数えるので、メモリや端末ではなくDBに持つ
  (端末で数えても、攻撃者はアプリを使わずAPIを直接呼べる)

  | 制限 | 既定 | 防ぎたいこと |
  |---|---|---|
  | 1つのコードで間違えてよい回数 | 5回(再送で0に戻る) | 1つのコードの総当たり |
  | 再送の間隔 | 60秒 | 連打による大量送信 |
  | 24時間あたりの送信回数 | 5回(サインアップ時の送信を含む) | 再送の繰り返しによる総当たり・大量送信 |

  「24時間に5回」が無いと、60秒の間隔だけで1日1,440通送れ、総当たりで1日約7,200回試せ(6桁なら約0.7%)、他人のアドレスに
  大量に送りつけることもできる。メールアドレスは一意なので、確認コードについてはユーザー単位の上限が
  実質的にアドレス単位の上限になる
- 既知の抜け道: アカウントを削除して同じアドレスで作り直すと、制限が数え直しになる。また、多数の他人のアドレスで次々に
  サインアップされると、宛先ごとの上限では全体の量を抑えられない(未対策)

### テーブル`email_codes`(マイグレーション0006)

ユーザーと用途ごとに1行を持ち、送るたびに上書きする(再送のたびに行を足さない。参照先が1つに決まり、同時に届いたリクエストも
その1行のロックで順番に処理できる)。

| 列 | 型 | 制約 | 内容 |
|---|---|---|---|
| `user_id` | UUID | 主キー、FK(`users.id`、ON DELETE CASCADE) | |
| `purpose` | VARCHAR(30) | 主キー、CHECK | 用途。`verify_email`だけ |
| `code_hash` | VARCHAR(255) | null可 | 今のコードのargon2のハッシュ。確認に成功した・失敗の上限に達したらnull |
| `expires_at` | timestamptz | null可 | 今のコードの有効期限(送った10分後)。`code_hash`と同じくnullにする |
| `status` | VARCHAR(20) | NOT NULL、CHECK | `pending`(入力待ち)・`used`(確認に成功)・`locked`(失敗の上限に達した)。**期限切れは状態として保存せず`expires_at`から求める**(時間が経つだけで起き、その瞬間に処理が走らないため) |
| `failed_attempts` | INTEGER | NOT NULL | 今のコードで間違えた回数。送るたびに0に戻す |
| `issued_at` | timestamptz | NOT NULL | 最後に送った日時(再送の間隔の判定) |
| `send_count` | INTEGER | NOT NULL | 数え始めからの送信回数(24時間あたりの上限の判定) |
| `send_window_started_at` | timestamptz | NOT NULL | 送信回数の数え始め。24時間経った後の最初の送信で数え直す |
| `outbox_email_id` | UUID | null可、FK(`outbox_emails.id`、ON DELETE SET NULL) | 今のコードを送ったoutboxの行。再送のとき、まだ送られていなければ取り消す。outboxの行がパージされたらnull |

- インデックス: `outbox_email_id`(outboxのパージでのSET NULL用)
- 同じ0006で、`outbox_emails`に`send_deadline`列と`status`の`cancelled`を足している(上記「メール送信の基盤」)
- 取り消すメールは`email_codes.outbox_email_id`で指す(outboxにメールの種類の列を持たせず、「どう送るか」だけの汎用の形に保つため)

### 流れ

コードの送信(サインアップ時・再送)は同じ処理`issue_code`で行う:
1. `email_codes`の行をロックして読む(無ければ作る)
2. (再送のみ)前回の送信から60秒経っていなければ429。数え始めから24時間経っていれば`send_count`を0・数え始めを今にする。
   `send_count`が5なら429(数え始めから24時間経つまでの秒数を`Retry-After`で返す)
3. 前のコードのoutboxの行がまだ`pending`なら`cancelled`にする(古いコードのメールが後から届いて、入力の失敗の枠を無駄に使うのを防ぐ)
4. 6桁のコードを作り(`secrets.randbelow`)、ハッシュ・有効期限(今+10分)・`status=pending`・`failed_attempts=0`・`issued_at=今`・
   `send_count+1`で上書きする
5. outboxに積む(`send_deadline`はコードの有効期限)。積んだ行のidを`outbox_email_id`に入れる
6. 呼び出し元がcommitする(サインアップではユーザーの作成と同じトランザクション)

確認(コードの入力):
1. 確認済みのユーザー → コードを見ずに200(下記「判断の理由」)
2. `email_codes`の行をロックして読む。行が無い・`status`が`pending`でない・`expires_at`を過ぎた → 400(`verification_code_expired`)
3. コードが違う → `failed_attempts`+1。5に達したら`status=locked`にしてコード・有効期限をnullにする。commitして400(`invalid_verification_code`)
4. コードが合う → `status=used`、コード・有効期限をnull、`users.email_verified_at`=今。commitして200

状態の移り変わり:

```
            送信(60秒・24時間に5回の範囲で)
       ┌───────────────────────────┐
       ▼                           │
  [pending] ──コード一致──> [used](終わり)
    │  │
    │  └──5回間違える──> [locked] ──送信──> [pending]
    └──10分経つ──>(期限切れ。statusはpendingのまま、expires_atで判定)──送信──> [pending]
```

### 判断の理由

- コードの送信はPOST: 新しいコードを作り、メールを送り、回数を数える(状態を変える)操作で、コードはレスポンスではなくメールで届く。
  GETは「状態を変えない・何度呼んでも同じ」約束なので、ブラウザ・プロキシ等が勝手に再送・先読み・キャッシュしうる
- 確認済みでの送信は409、確認済みでの確認は(コードに関係なく)200: 確認に成功したのにレスポンスが届かず(圏外等)端末が再送した場合、
  コードは使用済みで消えているので、照合すると失敗に見えてしまう。確認済みのアカウントに確認を呼んでも何も変わらず何も漏れない
  (呼べるのはログイン中の本人だけ)ので、成功として返す。送信は意味が無いので送らず、409で確認済みを伝える

### 文面

最小限のテキストのみ。件名「【osampo-tracker】メールアドレスの確認コード」、本文はコードと有効期限(10分)と「心当たりが無い場合は破棄してください」。
有効期限の時刻は入れない(サーバーは利用者のタイムゾーンを知らないため)。

### 設定(全て省略可)

`EMAIL_CODE_TTL_MINUTES`(10)、`EMAIL_CODE_MAX_FAILED_ATTEMPTS`(5)、`EMAIL_CODE_RESEND_INTERVAL_SECONDS`(60)、`EMAIL_CODE_DAILY_LIMIT`(5)。
apiが使う(composeでapiに渡す)

### 実装

- `app/models/email_code.py`、`migrations/versions/0006_email_codes.py`(outboxの`send_deadline`・`cancelled`も)
- `app/services/email_verification_service.py`: `issue_verification_code`(送信。サインアップ・再送で共通)、
  `send_verification_code`(再送のendpoint)、`confirm_verification_code`(確認)。サインアップは`auth_service.signup`から呼ぶ
- `app/routers/users.py`の`send_email_verification`・`confirm_email_verification`、`app/security.py`の確認コードの生成・ハッシュ
- `app/services/mail_service.py`の`cancel_pending_email`と、`send_pending_emails`での`send_deadline`の判定
- 行が無いユーザー(サインアップ以外で作られたユーザー: この機能より前のユーザー・seed-devの未確認ユーザー)は、
  送信のときに`INSERT ... ON CONFLICT DO NOTHING`で行を作る(同じユーザーの送信が同時に届いても主キーが衝突しない)

### 確認の方法

- pytest: サインアップでコードの行とoutboxの行が1つのトランザクションでできること、再送(60秒・24時間に5回・数え直し・
  前のメールの取り消し・409)、確認(成功で`email_verified`がtrue・同期APIが使えるようになる、違うコード、5回でlocked、期限切れ、
  確認済みでの200)、outboxの`send_deadline`を過ぎた行を送らないこと。コードはoutboxの行の本文から取り出して使う
- 手動(ホスト側): 未確認のユーザーで再送を呼び、Mailpitに届いたコードで確認する(`curl --cacert "$(mkcert -CAROOT)/rootCA.pem" https://localhost/api/...`で呼ぶ)
- Tips(外部のサーバーで送る場合): 日本の携帯キャリアのアドレスは「指定したドメインからのみ受信」の設定が多く、確認コードが
  届かない問い合わせの典型になる。登録画面での受信設定の案内や、届かないときの問い合わせ先を用意する

### エンドポイント

確認コードは6桁の数字で、有効期限は10分。サインアップ時に自動で送り、届かなければ再送する。

#### POST /users/me/email-verification

1. 確認済み: 409(`email_already_verified`)。送らない
2. 前回の送信から60秒経っていない、または24時間あたりの送信回数(5回)に達している: 429(`too_many_requests`。送れるようになるまでの秒数を
   `Retry-After`で返す)
3. 新しいコードを作って送る。前のコードは使えなくなり、前のコードのメールがまだ送られていなければ取り消す

- レスポンスは202(outboxに積んだだけで、まだ送っていない。workerが数秒以内に送る)。`resend_available_in`は画面の再送ボタンを
  押せるようにするまでの待ち時間に使う
- POSTにする理由は上記「判断の理由」

#### POST /users/me/email-verification/confirm

1. 確認済み: コードを見ずに200
2. 有効なコードが無い(期限切れ・失敗の上限に達した・まだ送っていない): 400(`verification_code_expired`)
3. コードが違う: 400(`invalid_verification_code`)。同じコードで5回間違えると、そのコードは使えなくなる(以降は`verification_code_expired`。
   再送で新しいコードを受け取る)
4. コードが合う: メールアドレスを確認済みにする。以降、同期APIが使える

- 確認済みで200を返す理由は上記「判断の理由」
