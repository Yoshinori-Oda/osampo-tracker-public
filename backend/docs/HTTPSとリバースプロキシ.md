# HTTPSとリバースプロキシの詳細設計

2026-11-09に設計。apiの前にリバースプロキシ(nginx)を置き、TLSを終端してHTTPSで公開する。あわせて、送信元のIP・リクエストIDの扱いと、
流量・大きさ・時間の上限をプロキシに持たせる。概要は`docs/basic-design/security.md`の「通信」、構成は`docs/basic-design/system-overview.md`。

**この構成は開発環境のためのもの**。本番環境はクラウドのサービス(ロードバランサーとマネージドの証明書等)に置き換える想定で、
本番の構成(ドメイン・証明書の発行・TLSを終端する場所)はまだ決めていない。

## 構成

```
アプリ ──HTTPS(127.0.0.1:443)──▶ proxy(nginx) ──HTTP(composeのネットワーク)──▶ api:8080
                                  │ TLSを終端する
                                  │ /api/ だけをapiへ転送する
                                  │ X-Forwarded-For・X-Forwarded-Proto・X-Request-IDを上書きする
                                  └ 流量・bodyの大きさ・時間の上限、セキュリティのヘッダー、アクセスログ
```

| 決めたこと | 内容 | 理由 |
|---|---|---|
| プロキシ | nginx(公式イメージのstable版のalpine。タグはマイナーバージョンまで固定) | 最も広く使われている。証明書・TLS・ヘッダーを自分で設定するので、仕組みが見える(Caddyは証明書の取得等を自動で行う分、設定から挙動を追いにくい) |
| 証明書 | mkcert(手元に作る自分専用のCA)で発行する | 自己署名の証明書と違い、CAをクライアントに信頼させれば本物と同じ検証が通る(検証を無効にする逃げ道を作らない) |
| TLSの終端 | proxy。proxy→apiは平文のHTTP | proxy→apiはcomposeのネットワークの中に閉じている |
| 公開するパス | `/api/`だけ。それ以外(`/docs`・`/openapi.json`・`/health`等)は404 | アプリが使うのは`/api/`だけ。OpenAPIの画面は使わない(APIの仕様は設計書で管理している) |
| ホストに公開するポート | proxyの`127.0.0.1:443`だけ。apiは公開しない。db(5432)・mailpit(8025)は`127.0.0.1`に限る | 外からの通信はproxyだけが受ける。apiを公開すると、proxyを通らずに`X-Forwarded-For`を偽って送れる。実機での確認はしないので、proxyもループバックに限る(Androidエミュレータの`10.0.2.2`はホストのループバックに届く) |
| 80番(HTTP) | 待ち受けない(リダイレクトもしない) | 平文で送られたトークンは送った時点で漏れている。リダイレクトするとPOSTがGETに変わる。下記「80番を待ち受けない」 |
| 開発での使い方 | 開発でも常にproxyを通す(apiへ直接つなぐ経路は残さない) | 本番に近い形で日々動かし、proxyの設定の誤りに早く気づくため |

実装: `backend/proxy/nginx.conf`(nginxの設定)・`backend/proxy/security_headers.conf`(全ての応答に付けるヘッダー)、
`backend/docker-compose.yml`の`proxy`サービス(composeのネットワークのサブネットは`172.31.89.0/24`、proxyは`172.31.89.10`に固定)。

実機で確かめるようになったら、proxyの公開を`0.0.0.0:443`に広げ、証明書にホストのLANのIPを加える。

### 80番を待ち受けない

- アプリは接続先が`API_BASE_URL`で決まっていて、平文のHTTPで送る経路が無い(iOSのATSも既定で平文を拒否する)
- 80番で待ち受けて「平文で届いたトークンを無効にする」こともできる(不特定の開発者が手でURLを書くAPIサービスで行われることがある)。
  待ち受けなければTCPの接続の段階で失敗し、トークンはサーバーに届かない代わりに無効にもできない。経路の途中で盗聴されていれば無効にしても
  送った時点で漏れていて、アクセストークンは15分で切れるので、見送った

## 証明書

### 作成(ホストで1度だけ)

```bash
brew install mkcert
cd backend
mkdir -p secrets/tls
mkcert -cert-file secrets/tls/cert.pem -key-file secrets/tls/key.pem localhost 127.0.0.1 10.0.2.2
```

- 初回の実行でmkcertがCA(`$(mkcert -CAROOT)`の`rootCA.pem`・`rootCA-key.pem`)を作り、そのCAで署名したサーバーの証明書を作る
- SAN(証明書に書く名前): `localhost`(アプリの既定の接続先)・`127.0.0.1`・`10.0.2.2`(Androidエミュレータから見たホスト)
- **`mkcert -install`(Macのシステム・ブラウザの信頼ストアにCAを入れる)は実行しない**。信頼させるのはシミュレータだけにして、
  CAが悪用されたときの範囲を小さくする。ホストから`curl`で確かめるときは`--cacert "$(mkcert -CAROOT)/rootCA.pem"`を付ける

### 鍵の置き場所

| ファイル | 置き場所 | 扱い |
|---|---|---|
| サーバーの証明書・秘密鍵 | `backend/secrets/tls/`(`cert.pem`・`key.pem`) | コミットしない(`backend/secrets/`は`.gitignore`済み)。proxyには`secrets/tls/`だけを読み取り専用でマウントする(JWTの署名鍵はproxyから見せない) |
| CAの証明書(`rootCA.pem`) | mkcertのCAROOT(ホストのユーザーのディレクトリ) | 公開してよい。シミュレータに入れる |
| **CAの秘密鍵(`rootCA-key.pem`)** | mkcertのCAROOTから動かさない | **`secrets/`・リポジトリ・コンテナに絶対にコピーしない**。持っている人は、このCAを信頼する端末に対して任意のサイトになりすませる |

### 更新

- mkcertの証明書の有効期限は約2年3か月。自動で更新する仕組みは無く、2年に1度のために作る価値も無いので、手動で行う
- 期限の確認: `openssl x509 -enddate -noout -in backend/secrets/tls/cert.pem`(`run_checks.sh`の`https`のstepでも表示する)
- 更新: 上の`mkcert`のコマンドを再び実行し、`docker compose restart proxy`

### クライアントに信頼させる

- iOSシミュレータ: `xcrun simctl keychain booted add-root-cert "$(mkcert -CAROOT)/rootCA.pem"`。シミュレータを作り直したり、
  初期化したりしたら入れ直す。アプリのHTTP通信(dart:io)がiOSの信頼ストアで証明書を検証すること(keychainに入れれば通ること)は、
  実装後の最初のE2Eで確かめる
- Androidエミュレータ: **今は対応しない**。Android 7以降は、ユーザーが入れたCAをアプリが既定では信頼しない。対応するときは、
  `network_security_config.xml`の`<debug-overrides>`でデバッグビルドだけユーザーのCAを信頼させる(dart:ioがそれに従うかの確認も要る)か、
  デバッグビルドだけ`SecurityContext`に開発用のCAを読み込ませる
- **証明書の検証を無効にしない**(`badCertificateCallback`で全て許す等)。リリースビルドに紛れ込む事故が典型
- 証明書のピン留め(pinning)はしない。証明書を更新したときにアプリがつながらなくなるリスクに見合わないため

## TLSの設定

- MozillaのSSL Configuration Generatorの**intermediate**に従う(多くのクライアントとつながる、一般向けのサーバーの推奨)。
  TLS 1.2・1.3だけを許可し、暗号スイートも生成した設定のとおりにする。DHEの暗号スイートは、DHのパラメータ(`ssl_dhparam`)を
  置かないので使われない(ECDHEで足りる)
- **HTTP/2は有効にしない**。アプリのHTTP通信(Dartの`http`パッケージが使うdart:ioの`HttpClient`)はHTTP/1.1だけを話すので、
  有効にしても使われない。使わない機能は攻撃の対象を増やすだけなので切っておく(HTTP/2は「Rapid Reset」等、HTTP/2に固有のDoSの
  脆弱性が見つかってきた)
- **HSTS**(`Strict-Transport-Security: max-age=63072000`)を付ける。ブラウザに「このホストには今後HTTPSでしかつながない」と覚えさせる
  ヘッダーで、ネイティブのアプリには効かないが、ブラウザで開かれたときと本番に向けて付けておく。開発のホスト名は`localhost`なので、
  ブラウザが覚えると他のポートの開発用のサーバーまでHTTPSを強いられる。今は`mkcert -install`をしない(Macのブラウザがこの証明書を
  信頼しない)ので、ブラウザはHSTSを無視する
- **OCSPステープリングは使わない**。OCSPは証明書が失効していないかをCAに問い合わせる仕組みで、ステープリングはその応答をサーバーが
  代わりに取ってTLSのやりとりに添えるもの。mkcertの証明書にはOCSPの問い合わせ先が無い(本番の候補のLet's EncryptもOCSPの提供を
  やめている)ので、使う場面が無い

## プロキシとapiの間

### 送信元の情報(`X-Forwarded-For`・`X-Forwarded-Proto`)

- proxyは、apiへ転送するときに次のヘッダーを**上書き**する(クライアントが送ってきた値は捨てる)

  | ヘッダー | 値 | 意味 |
  |---|---|---|
  | `X-Forwarded-For` | proxyに接続してきた送信元のIP(`$remote_addr`)だけ | apiから見た接続元はproxyなので、本当の送信元を伝える。クライアントの値に追記する(`$proxy_add_x_forwarded_for`)と、偽の値が先頭に残る |
  | `X-Forwarded-Proto` | `https` | クライアントとproxyの間がHTTPSだったことを伝える |
  | `Host` | クライアントが送った`Host` | apiが組み立てるURLのホスト名を、クライアントが接続したものにする |
  | `X-Request-ID` | proxyが作ったID(下記「リクエストID」) | |

- apiは、**proxyから届いたときだけ**これらのヘッダーを信用する。uvicornの`--forwarded-allow-ips`にproxyのIPだけを指定する
  (uvicornは指定したIPからの接続でだけ、`X-Forwarded-For`・`X-Forwarded-Proto`で送信元のIP・スキームを置き換える)。
  composeのネットワークのサブネットを固定し、proxyに固定のIPを割り当てて、そのIPを指定する
  - apiのアプリ(`app/request_context.py`)は今までどおり接続の送信元(`scope["client"]`)を使う。uvicornが置き換えた後の値なので、
    アプリの変更は要らない
- `X-Forwarded-Proto`が要る理由: apiが自分のURLを組み立てるとき(FastAPIが末尾の`/`を補うリダイレクトの`Location`等)、
  apiから見た接続はHTTPなので`http://...`になる。アプリがそれに従うと、待ち受けていない80番へつなぎに行って失敗する。
  `X-Forwarded-Proto: https`を信用させると、`https://...`で組み立てる
- 将来、proxyの前にクラウドのロードバランサーが入ると、proxyに接続してくるのはロードバランサーになる。そのときは、proxyで
  ロードバランサーのIPを信頼し(nginxの`set_real_ip_from`・`real_ip_header`)、`X-Forwarded-For`の右から信頼できるプロキシの数だけ
  飛ばした値を送信元とする
- 開発環境(Docker Desktop)では、ホストから公開したポートへの接続の送信元は、Dockerのゲートウェイ等のIPになり、全てのクライアントが
  同じIPに見える。送信元のIPに関わる挙動(ログのIP・流量の制限)は、開発環境では本番と同じにならない

### リクエストID

- **proxyがリクエストごとにIDを作る**(nginxの`$request_id`。32桁の16進数)。クライアントが送った`X-Request-ID`は無視し、apiへ転送する
  ときに上書きする。apiのアプリは、届いた`X-Request-ID`を今までどおり使う(形式は英数字と`-`の8〜64文字なので、proxyのIDは通る。
  apiに直接つなげるのはcomposeのネットワークの中だけ)
- proxyのアクセスログ・apiのアクセスログ・アプリのログ・監査ログが同じIDになり、proxyで止めたリクエスト(429・413等。apiに届かない)も
  proxyのログでIDが分かる
- レスポンスの`X-Request-ID`はproxyが付ける(apiが付けたものと同じ値だが、二重にならないようapiのものは隠す)。proxyが自分で返すエラーにも付ける
- **端末はリクエストIDを送らず、応答の`X-Request-ID`を端末のログに出す**(`frontend/lib/auth/request_id_client.dart`)。送る前と
  通信できなかったときには、時刻(UTC)を付けて出す(`[http] GET /api/users/me at=2026-11-09T01:02:03.456Z`)。
  以前は端末がUUIDを作って送り、応答が届かなかった(タイムアウト)ときにも端末のログのIDでサーバーのログを探せるようにしていたが、
  サーバーのログに残るIDをサーバーが作ったものだけにする(端末がIDを重複させる等で、調査を混乱させられないようにする)ことを優先した。
  応答が届かなかったリクエストは、端末のログの時刻・送信元のIP・パスでproxyのログを探す
- 端末にIDが残らないのは次の2つの場合。どちらも、端末のログの時刻・パスと、proxyのログ(時刻・送信元のIP・パスの型・ステータス)で突き合わせる

  | 場合 | 例 | サーバー側 | 端末側 |
  |---|---|---|---|
  | proxyがリクエストを受け取れなかった | 圏外・接続の拒否・TLSの失敗(証明書のエラー等) | IDもログも無い(TLSの失敗はinfoのレベルでしかエラーログに出ず、warnにしているので残らない) | IDは無い |
  | サーバーは処理したが、応答が端末に届かなかった | 端末の3秒のタイムアウト・帰りの通信が切れた | **IDがあり、ログにも残っている**(処理が済んでいることがある) | IDを受け取れていない |
- リクエストIDは、ログでの振り返りのためだけに使う(処理はステートレスで、IDで処理を変えない)

### アクセスログ

proxyとapiの両方で取る。役割を分ける。

| | proxyのアクセスログ | apiのアクセスログ(`バックエンド構成.md`の「ログ」) |
|---|---|---|
| 説明すること | 通信として何が来て、proxyがどう応えたか(apiに届かなかったものも含む) | apiがリクエストをどう処理したか |
| 主な項目 | 時刻・`request_id`・送信元のIP・メソッド・パスの型・ステータス・apiのステータス・受信/送信のバイト数・全体の時間・apiの応答時間・TLSのバージョン | `request_id`・`user_id`・IP・メソッド・パスの型・ステータス・`code`・時間 |

- 形式は、apiのログと同じkey=valueの1行(nginxの`log_format`で組む)
- **パスは「パスの型」に置き換えて残し、クエリ文字列は残さない**(apiのアクセスログと同じ方針。パスには`user_id`・`session_id`が、
  クエリには同期の日時が入るため)。nginxの`map`で、`user_id`・`session_id`を含むパスを`/api/users/{user_id}/sessions/{session_id}`の
  ような型に置き換える。型に当てはまらないパスはそのまま残す(`/api/`の外を探られた等が分かるように)
- リクエストのbody・`Authorization`等のヘッダーは残さない
- 保持: IPは個人関連情報として扱い、**90日**とする(tombstone・監査ログと同じ)。開発環境では、Dockerのjson-fileのログ
  (サービスごとに10MB×3ファイル。composeの`x-logging`)のまま。日数での保持は、本番でログを集める先(CloudWatch Logs等)で設定する

## 上限・保護

### 流量の制限(送信元のIP単位)

**DoS(大量のリクエストでサーバーを止める攻撃)を弾くためだけ**に置き、普段の利用で引っかからない値にする。ログインの推測などの
業務の意味がある回数の制限は、今までどおりapiが行う(メールアドレス・ユーザー単位)。

| 対象 | 上限(IPごと) | 考え方 |
|---|---|---|
| `/api/`全体 | 平均20回/秒、瞬間的に100回まで(`limit_req rate=20r/s burst=100 nodelay`) | 同期は未同期のセッションごとに1回の登録・更新・削除と1回の取得を順に送る。圏外から復帰して多くのセッションを一度に送っても、1台は順番に送るので応答の速さ(数十ms〜)で頭打ちになり、瞬間の100回に収まる。モバイル回線では多くの端末が1つのIPを共有する(CGNAT)が、1台の通信は同期のときだけで平均すると少ない |
| パスワード・確認コードを照合・ハッシュする操作(`POST /api/auth/signup`・`POST /api/auth/login`・`PUT /api/users/me/password`・`POST /api/users/me/email-verification`・`POST /api/users/me/email-verification/confirm`) | 平均1回/秒、瞬間的に10回まで(上と別に数える) | argon2は1回に64MiBのメモリと数十msのCPUを使うので、少ない回数でもサーバーを重くできる。これらは1台が頻繁に行う操作ではない |
| 同時接続 | IPごとに100本まで(`limit_conn`) | 1台の同時接続は数本で、CGNATの分の余裕を持たせる |

- 上限を超えたら429を返す(nginxの既定は503なので`limit_req_status 429`を指定する)。bodyはAPIのエラーの形式で`code`は
  `too_many_requests`、`Retry-After: 1`を付ける(アプリの既存の429の扱いがそのまま使える)
- 超えた分は待たせずに断る(`nodelay`)。待たせると接続を持ち続けるので、DoSのときにproxyの資源を使われる
- 値は目安で、負荷試験(Issue #12)の結果で見直す

### bodyの大きさ

- `client_max_body_size 10m`(10MiB)。apiの上限(`max_request_body_bytes`、10MiB)と揃える。超えたら413(`payload_too_large`)
- apiの上限(`BodySizeLimitMiddleware`)も残す(proxyの設定を誤ったとき・proxyを通らないテストのため)

### タイムアウト

proxyは2本の接続の間に立ち、それぞれに別のタイムアウトを持つ(nginxでは端末側を「クライアント」、api側を「upstream」(`proxy_*`)と呼ぶ)。

```
端末 ──①端末⇔proxy(HTTPS)──▶ proxy ──②proxy⇔api(HTTP)──▶ api
     ◀──────────────────────        ◀──────────────────────
```

**① 端末⇔proxy**: proxyが端末の遅さ・居座りに付き合う時間の上限。

| 設定 | 向き | 何を測るか | 値 |
|---|---|---|---|
| `client_header_timeout` | 端末→proxy | 接続(TLSのハンドシェイクの後)からリクエストのヘッダーを全部受け取るまでの**全体の時間** | 10秒 |
| `client_body_timeout` | 端末→proxy | bodyを受け取るときの、**データが届く間隔**(全体の時間ではない。10MiBを1分かけて送っても、途切れずに届いていれば切らない) | 10秒 |
| `send_timeout` | proxy→端末 | 応答を送るときの、**端末が受け取る間隔**(端末が受け取りを止めたら切る) | 10秒 |
| `keepalive_timeout` | 端末⇔proxy | 応答を返し終えた後、次のリクエストのために接続を開けておく時間。同期の連続したリクエストで、TLSのハンドシェイクをやり直さずに済む | 30秒 |

- `client_header_timeout`・`client_body_timeout`は、わざと少しずつ送って接続を占有する攻撃(slowloris)を切るのが主な狙い

**② proxy⇔api**: apiが詰まったときに、proxyがいつまで待つか。時間切れになると、proxyは端末に504(`service_unavailable`)を返す。

| 設定 | 向き | 何を測るか | 値 |
|---|---|---|---|
| `proxy_connect_timeout` | proxy→api | apiへのTCPの接続ができるまで。同じホストの中なので、つながらなければapiが落ちている | 5秒 |
| `proxy_send_timeout` | proxy→api | リクエストを転送するときの、**apiが受け取る間隔** | 10秒 |
| `proxy_read_timeout` | api→proxy | apiの応答が届く間隔。apiは処理を終えてから応答をまとめて返すので、実質は**apiの処理時間の上限** | 30秒 |

- `proxy_read_timeout`: apiの処理は1件ずつ短く終わる設計で、普段は1秒もかからない。ただし、proxyが待つのをやめてもapiの処理は止まらない
  (commitまで進む)ので、短くしすぎると「apiではcommitされたのに、端末には失敗に見える」が増える。10MiBのbodyの登録にも余裕を持たせて30秒にする

**端末自身のタイムアウト(proxyの外)**: アプリの同期は、送ってから応答を受け取るまでを3秒で打ち切る(`tracking_repository.dart`の
`_timeoutDuration`)。①②より短いので、普段の利用で先に諦めるのは端末になる。①②は、アプリ以外のクライアントや異常なときに、
proxyとapiの資源を守るためのもの。

### proxyが自分で返すエラー

apiに届く前・届かなかったときのエラーも、APIのエラーの形式(`{"code", "message"}`)のJSONで返す(nginxの`error_page`)。
アプリが`code`で処理を分けられるようにするため。

| ステータス | code | いつ |
|---|---|---|
| 404 | `not_found` | `/api/`の外のパス |
| 413 | `payload_too_large` | bodyが10MiBを超えた |
| 429 | `too_many_requests` | 流量の制限を超えた(`Retry-After: 1`) |
| 502・504 | `service_unavailable` | apiにつながらない・apiの応答が`proxy_read_timeout`までに来ない |
| その他(400等) | `http_error` | 壊れたリクエスト等 |

`service_unavailable`はAPI設計書の「codeの一覧」に加える。アプリは他の5xxと同じく、同期を後で再試行する。

### 応答のヘッダー

| ヘッダー | 扱い | 理由 |
|---|---|---|
| `Server` | nginxのバージョンを出さない(`server_tokens off`)。uvicornの`server: uvicorn`はnginxが既定で転送しない | 使っているソフトウェアのバージョンを教えない(既知の脆弱性を探す手がかりにさせない) |
| `Strict-Transport-Security` | 付ける(上記「TLSの設定」) | |
| `X-Content-Type-Options: nosniff` | 付ける | ブラウザに、`Content-Type`と違う種類(HTMLやスクリプト)として解釈させない |
| `Cache-Control: no-store` | 付ける | 応答にはトークン・位置情報が入る。途中のキャッシュや端末のHTTPキャッシュに残さない |

- CORS(ブラウザが別のサイトからAPIを呼ぶのを許すかどうか)は設定しない。ブラウザから使うクライアントは無いので、許可するヘッダーを
  返さない(=ブラウザからの別サイトの呼び出しは拒否される)のが正しい

## アプリ(frontend)

- 接続先の既定値を`https://localhost/api`にする(`frontend/lib/repositories/tracking_repository.dart`の`API_BASE_URL`)
- iOSシミュレータにmkcertのCAを入れる手順を`docs/development.md`に書く(上記「クライアントに信頼させる」)
- Androidエミュレータ(`https://10.0.2.2/api`)と実機は、CAを信頼させる対応をするまで使えない(上記)
- リクエストIDは送らず、応答の`X-Request-ID`を端末のログに出す(上記「リクエストID」)

## ヘルスチェック

- apiは今までどおり、apiのコンテナの中から`http://localhost:8080/health`を確かめる(proxyを通さない)
- proxyは、コンテナの中のループバックだけで待ち受ける確認用の口(`127.0.0.1:8081`の`/healthz`。204を返すだけ)を設け、composeの
  `healthcheck`でコンテナの中から確かめる。ホストには公開しない
- proxyは`depends_on`でapiの`healthcheck`が通ってから起動する(起動直後の502を避ける)
- nginxは設定に誤りがあれば起動しない(`nginx -t`と同じ検査が起動時に行われる)

## テスト・確認の方法

- **ホスト側**: `backend/scripts/run_checks.sh`に`https`のstepを加える(サービスが起動済みの前提)。`curl`で次を確かめ、結果を`SUMMARY.md`に出す
  - mkcertのCAで証明書を検証して、`https://localhost/api/`につながる(apiのエラーの形式の応答が返る)。`127.0.0.1`でもつながる
  - TLS 1.1以下ではつながらない。80番・8080番にはつながらない
  - `/docs`・`/health`は404(`not_found`)
  - 応答に`X-Request-ID`・HSTS・`nosniff`・`no-store`が付き、`Server`にバージョンが無い
  - クライアントが送った`X-Request-ID`が使われない
  - `X-Forwarded-For`を偽って送っても、apiのアクセスログのIPは偽の値にならない(`docker compose logs api`をリクエストIDで探す)
  - 10MiBを超えるbodyは413(`payload_too_large`)
  - 証明書の有効期限を表示する
  - 流量の制限(429)は、他の確かめるべきことに影響しないよう、最後に確かめる
- **pytest**: apiのアプリは変えないので、新しいテストは無い。リクエストIDの既存のテストは、proxyが作ったIDを受け取る場合として残る
- **CI**: proxy・証明書を使う確認は、CIでのDockerイメージのビルドと起動の確認(Issue #22)と一緒に検討する。今はホストの`https`のstepで確かめる
- **アプリ**: iOSシミュレータでのE2E(`run_checks.sh <run_id> e2e`)で、HTTPS越しのログイン・同期が通ることを確かめる

## 後で行うこと

- Androidエミュレータ・実機での接続(CAを信頼させる対応。上記「クライアントに信頼させる」)
- 本番の構成(ドメイン・証明書・TLSを終端する場所・ロードバランサーの後ろでの送信元のIP)
- 業務の意味がある送信元のIP単位の制限(多くのアカウントを少しずつ推測する攻撃への対策)。CGNATで無関係な利用者を巻き込むので、
  本番の構成と送信元のIPの取り方が決まってから検討する
