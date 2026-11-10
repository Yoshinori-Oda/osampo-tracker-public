# フロントエンド概要

frontend(Flutterのモバイルアプリ)の、認証とアカウントの端末側の設計と、frontend全体に関わる実装上の注意(落とし穴)。
2026-11-10時点のmainの実装を正とする。画面の一覧は`docs/basic-design/screens.md`、各画面の仕様は`frontend/docs/screens.md`、
端末のデータ(テーブル・secure storageのキー)は`docs/basic-design/data.md`、テストの書き方は`frontend/docs/e2e.md`。
以下のパスは`frontend/lib/`から。

## 認証とアカウント

サーバー側の処理は`backend/docs/auth.md`・`backend/docs/mail.md`。実装は`auth/`(`auth_service.dart`・`auth_storage.dart`・
`authorized_client.dart`)と`providers/auth_providers.dart`。

### 同期を行う条件

- `AuthState.canSync`(`signedIn && !isLocal && emailVerified && !needsRelogin`)のときだけ同期する。同期の可否はすべてこれで決まる
- 起動時・フォアグラウンド復帰時にGET /users/meで確認状態を取り込んでから同期する。`MainPage`は`canSync`がfalseからtrueに変わると
  同期を始めるので、再ログイン・メールアドレスの確認で同期できる状態に戻ると、止まっていた同期が再開する

### 起動とユーザーの切り替え

- 起動時の画面は`main.dart`のAuthGate(ログイン状態の復元中はスプラッシュ)。復元(`AuthService.restore`)は次のとおり:
  - `current_user_id`が無く、端末の`users`に行が1つも無い(初回起動、または最後のユーザーを消した後): ローカルアカウント(表示名「ローカル」)を作って入る
  - `current_user_id`が無く、`users`に行がある(通常のアカウントでログアウトした後など): ログイン画面
  - `current_user_id`があり、その行が`is_local`: ローカルアカウントとして入る
  - `current_user_id`があり、`is_local`でなくトークンが無い、または行が無い: `current_user_id`を消してログイン画面
- メイン画面はユーザーIDをkeyにしてユーザーごとに作り直し、`repositoryProvider`等もログイン中のユーザーIDから作る
- ユーザーIDが変わる操作(ログアウト・アカウントの削除・ローカルアカウントの切り替え・通常のアカウントにする)は、収録中はできない
  (`MainPage`が作り直されて収録が途切れるため。設定タブで止める)
- ログアウト・アカウントの削除・ローカルアカウントの削除の後は、次のユーザーの画面を収録タブから始める(`bottomNavIndexProvider`を0にする)

### ログイン・ログアウト・アカウントの削除

- 新規登録・ログインが成功したら、そのユーザーで同期を走らせる。新規登録の直後はメールアドレスが未確認なので、記録・閲覧はできるが同期はしない
- ログアウト: 先に同期(`syncDiff`)を試み、成否に関係なくログアウトを進める。同期できなかったら、スナックバーで
  「同期できなかった記録はこの端末に残り、次にログインした時に同期されます」と出す。サーバーのログイン状態を無効にし(POST /auth/logoutを
  他のAPIと同じく`AuthorizedClient`経由で送る。トークンの更新も拒否されたら、サーバーのログイン状態は既に無効なので送り直さない)、
  secure storageの`current_user_id`・トークンを消す。ローカルのデータはそのユーザーのものとして残す
- アカウントの削除(DELETE /users/me): 成功したら、そのユーザーのローカルのデータ(`users`の行を含む)も消す。401(トークンの更新も
  拒否された場合を含む)も削除済みとみなして同じように消す(前回の削除がサーバーでは済んだのに結果が届かなかった場合、押し直すと401になり、
  ユーザーも消えているのでログインし直せず、端末のデータを消す手段が無くなるため)。別の理由の401(他の端末でのパスワードの変更・
  アカウントの停止)で端末のデータだけが消えることは許容する
- 通信のタイムアウトは、認証のAPIが5秒、アカウントの削除だけ30秒(サーバーでの削除に時間がかかりうるため)、同期のAPIが3秒
- 同期が止まっている理由は`widgets/auth_banner_view.dart`のバナーで出す(ローカルアカウントでは出さない)

### トークンとエラー

- `current_user_id`はトークンと分けて扱う(ローカルアカウントでは`current_user_id`だけを保存する)。トークンを保存・削除するときは
  `current_user_id`と組で扱う。`device_id`は初回起動時にUUIDを作り、ログアウトしても消さない(同じ端末として扱い続けるため)。
  `device_name`は送っていない
- 401(`token_expired`): リフレッシュトークンで更新し、元のリクエストを1回だけやり直す。同時に複数のリクエストが401になっても、
  更新は1回にまとめる(使用済みのリフレッシュトークンを再び送ると、サーバーがその端末のログイン状態を無効にしてしまうため)。
  更新が通信の失敗・サーバーのエラーでできなかった場合は、401を返さずに通信の失敗(`http.ClientException`)として投げる。
  呼び出し元に401が返るのは、サーバーがログイン状態を認めなかった場合だけにする
- それ以外の401と、トークンの更新の拒否: 同期を止め(`markNeedsRelogin`)、再ログインを促すバナーを出す。ローカルのユーザー・データは
  そのままにし、記録・閲覧は続けられる
- 403(`email_not_verified`): 同期を止め、メールアドレスの確認を促すバナーを出す。端末の`users.email_verified`がtrueのままサーバーが
  403を返した場合(確認状態が古かった)は、falseに書き換える

### メールアドレスの確認

画面の入口・表示は`frontend/docs/screens.md`の`auth/email_verification_page.dart`。

- コードの再発行は「コードを再発行」ボタンで送る(画面を開いただけでは送らない)。ボタンを押せるようになるまでの秒数は、202の
  `resend_available_in`、429の`Retry-After`から取る。端末で止めるのは使いやすさのためで、制限はサーバーが429で守る
- 6桁の数字でなければ送らない(サーバーも422にする。端末を信用しない)
- 確認に成功したら、レスポンスのユーザー情報で端末の`users`を更新し(`upsertUser`)、`AuthState.emailVerified`をtrueにする
- 再発行で409(確認済み)が返ったら、GET /users/me(`refreshProfile`)で確認状態を取り込み直して閉じる

### パスワード・表示名の変更

- パスワードの変更で現在のパスワードが違うとき、サーバーは401ではなく400(`invalid_current_password`)を返すので、`AuthorizedClient`は
  ログイン状態を無効にしない。成功すると、他の端末は次のリクエストで401(`unauthenticated`)になり、再ログインのバナーが出る
- 表示名の変更が成功したら、レスポンスで端末の`users`を更新する(`currentUserProvider`を見ている設定タブに反映される)

### ローカルアカウント

同期しないアカウント。メールアドレスの登録・確認は不要で、複数作れる。パスワードが無いので保護しない(個人の端末で使う前提。端末のロックに任せる)。
画面(選択画面・設定タブの項目)は`frontend/docs/screens.md`。

- 端末はトークンの組を1つしか持たないので、通常のアカウントからローカルアカウントへの切り替えは、ログアウトしてからログイン画面の
  「ローカルアカウントで使う」で行う
- ローカルアカウントの削除: そのユーザーのデータを端末から消す(`deleteUserData`)。今のユーザーなら`current_user_id`を消してログイン画面に戻る
- 記録の削除(`deleteSession`)は、ローカルアカウントでは`deletedUnsynced`にせず物理削除する(DELETEを送る先が無いため)

#### ローカル → 通常(新規登録・ログインで記録を移す)

設定タブの「通常のアカウントにする」から、新規登録・ログインの画面を「記録を移す」モード(`mergeLocal`)で開く。ログインのときは、送る前に
「(メールアドレス) のアカウントに、このローカルアカウントの記録を移します。元に戻せません。」と確かめる(共用の端末で他人のアカウントに入ると、
そちらに記録が混ざるため)。

1. 新規登録/ログインのAPIを呼ぶ(この時点ではトークン・`current_user_id`を保存しない)
2. 端末のDBで1つのトランザクションとして(`AppDatabase.saveServerUser`):
   1. 移る先のIDが端末の別のローカルアカウントのIDと重なっていたら(UUIDなので実際には起きない)、そのローカルアカウントのIDを新しいUUIDに変える
      (`sessions.user_id`はON UPDATE CASCADEで追随する)
   2. 移る先のユーザー(サーバーのID)の行を作る/更新する
   3. ローカルアカウントの記録をサーバーに未登録の状態にする(削除待ちの`deletedUnsynced`は物理削除し、`inProgress`以外は`ended`にする)
   4. ローカルアカウントの記録の`user_id`を移る先に付け替え、ローカルアカウントの行を消す
3. トークン・`current_user_id`を保存し、`AuthState`を切り替える。以降は通常の同期で記録がPOSTされる(新規登録の直後は、
   メールアドレスの確認が済むまで同期しない)

- `users.id`を書き換えるのではなく記録を付け替えるのは、移る先(既存の通常のアカウント)の行が端末に既にあると主キーが衝突して
  書き換えられず、合流に使えないため。付け替えなら新規登録とログインを同じ処理にできる
- 記録のIDがサーバーで他のユーザーのものと衝突した場合は、409(`id_conflicted`)→`reassignSessionId`で振り直される
- 途中で失敗した場合: 1が成功して2の前に落ちても、端末はローカルアカウントのまま(サーバーに使われないログイン状態が残るが、
  リフレッシュトークンの期限で無効になる)。ただし新規登録はサーバーにアカウントができているので、やり直すと登録済みのエラーになる。
  その場合はログインで記録を移すよう、エラーの文言で案内する

#### 通常 → ローカル

確認ダイアログで「サーバーのアカウントと記録を削除する・他の端末ではこのアカウントを使えなくなる・以降は同期しない・この端末の記録は残る」
ことを伝える。他の端末で記録してまだ取り込んでいないものは消えるので、先に同期を試み、失敗したら続けるかを確かめる。
収録中もできる(ユーザーIDが変わらず、`MainPage`は作り直されないため。収録中の記録は`inProgress`のまま残る)。

1. DELETE /users/me(タイムアウト30秒)。204に加え401も削除済みとみなす(アカウントの削除と同じ理由)
2. 端末のDBで1つのトランザクションとして(`AppDatabase.convertToLocalUser`)、`users`の行を`is_local`=true・`email`=''・
   `email_verified`=false・`last_synced_at`=nullにし、記録をサーバーに未登録の状態にする(上の2-3と同じ)
3. トークンを消し(`current_user_id`は残す)、`AuthState`をローカルにする

- 1の最中に走っていた同期が401を受けて`markNeedsRelogin`が呼ばれても、ローカルアカウントでは無視する

### ローカルDBの移行

`database/app_database.dart`の`MigrationStrategy`で行っていること(スキーマは`docs/basic-design/data.md`):

- 1 → 2(ユーザーごとのデータ): `users`テーブルを作り、既存の記録の`user_id`ごとに`users`の行を作ってから、`sessions.user_id`に
  外部キーを付ける(SQLiteは既存の列に外部キーを足せないので、`TableMigration`で`sessions`を作り直す)。持ち主のいない`track_points`を消す
  (バージョン1では外部キーが効いておらず、`sessions`の削除で残っていたため)
- 2 → 3(ローカルアカウント): `users`に`is_local`(既定はfalse)を加える。1からの移行では、`users`を今の定義で作るので列の追加は要らない
- 接続を開くときに`PRAGMA foreign_keys = ON`にする(SQLiteは既定で外部キーが無効)

## 実装上の注意

### 同期

同期の仕組みは`docs/design/sync.md`。

- `last_synced_at`は、GETのレスポンスの`synced_at`(サーバー時刻の文字列)をそのまま保存・送信する。端末で日時を組み立て直さない
  (端末のタイムゾーンのまま送ると、UTC以外の端末ではその分だけ未来の時刻としてサーバーに解釈され、他の端末の更新が差分から漏れ続ける。
  実際に起きた不具合)
- `TrackingRepository`のコンストラクタが毎回`last_synced_at`を消している(`_clearLastSyncedAtForTest`)。開発用の暫定の処理で、条件は無く
  全てのビルドで動く。ユーザーが変わるとproviderが作り直されるので、同期は常に全件の取得になる。差分取得の動作を確かめるときは外す
- 404は`code`が`session_not_found`のときだけ「サーバーにそのセッションが無い」として扱う(接続先の設定ミス等による`code`の無い404で、
  ローカルのデータを消したり再登録したりしないため)
- `TrackingRepository`のPATCHを送るメソッドは`updateSession()`。ローカルの名前・移動手段を編集するメソッドは、名前が重ならないよう
  `updateSessionInfo()`にしている(同名にすると`duplicate_definition`)

### 位置情報 (geolocator)

- `Geolocator.getCurrentPosition`の呼び出しを重ねない。iOSのgeolocator_apple(2.4.3より前。このアプリが使っている2.3.14も該当する)は
  結果の受け取り先を1つしか持たず、先の呼び出しが終わる前に次を呼ぶと受け取り先が上書きされ、先の呼び出しは`timeLimit`まで返らずに
  `TimeoutException`になる(Dart側の`timeLimit`で諦めてもネイティブ側の要求は残るので、時間切れになった呼び出しの後に呼ぶ場合も同じ)。
  位置情報ストリームの購読の停止・開始は影響しない
- そのため、収録の停止時の終了地点は`getCurrentPosition`で取らず、停止後に受信した位置から取る(`frontend/docs/location-tracking.md`)。
  `getCurrentPosition`で取ると、停止による購読の切り替え(`_startPositionStream`の初期位置の取得)と重なり、終了地点がほぼ毎回取れなかった
- `getCurrentPosition`は必ず`LocationSettings(timeLimit: ...)`付きで呼ぶ(無期限だとハングする)

### 地図 (flutter_map)

- 初期表示時にboundsへフィットさせるときは、`build()`の後に`MapController.fitCamera()`/`move()`を呼ばず、`MapOptions.initialCameraFit`を使う。
  `TileLayer`が最初の`initialZoom`向けにタイルを読み始めた後にカメラを変えると、タイルだけグレーのまま表示されなくなることがある
  (エラーは出ない。`PolylineLayer`・`MarkerLayer`は毎フレーム`MapCamera`を参照して描くので正常に出て、タイルだけ症状が出るのが見分け方)。
  実例: `views/session_detail_view.dart`の`_DetailMapView`
- `CameraFit.bounds`には`maxZoom`を付ける。トラックポイントが1点だけ(停止がすぐだった・終了地点が取れなかった等)だと`LatLngBounds`の
  幅・高さが0になり、ズームの計算が`Infinity`になって同じグレーの画面になる
- 地図の`TileLayer`は`utils/map_tiles.dart`の定数を使う。`userAgentPackageName`を`com.example.*`のような汎用の値にしたり省略したりすると、
  OpenStreetMapのタイルサーバーに拒否されて地図が表示されない
- 地図のクレジットは`widgets/osm_attribution.dart`の`OsmAttribution`を使う(flutter_mapの`SimpleAttributionWidget`を直接置くと、
  内部の`SafeArea`で画面下端の安全領域の分だけ浮く)

### レイアウト

- 画面上部に条件付きで出し入れするバナーと、その下の`AppBar`で、ステータスバーの余白が二重にならないようにする。`SafeArea`の`removeTop`は
  自分の子孫にしか伝わらないので、バナーと兄弟の関係にある`AppBar`は自分でもステータスバーの分の余白を取り、バナーを出している間だけ
  上部に二重の空白ができる。複数の箇所で同じ上端の余白を扱うときは、`MediaQuery.removePadding`でどこまで消費済みにするかを揃える
  (このアプリでの対処は`frontend/docs/location-tracking.md`の「バナーの表示」)

### Drift・依存パッケージ

- Driftのクエリで条件を`&`・`|`で結合するファイルでは、`package:drift/drift.dart`をimportする(`BooleanExpressionOperators`の拡張。
  無いと`flutter analyze`で`undefined_operator`)。生成された`app_database.dart`をimportするだけでは足りない。Flutterの`Column`等と
  名前がぶつかる場合は`show BooleanExpressionOperators`で絞る
- `flutter_secure_storage`は11系を使う(9系はwin32 ^5に依存し、`geolocator`の依存のwin32 ^6と衝突して依存を解決できない)
- プラグインを追加・更新するときは、`run_checks.sh <run_id> pubget`の結果を先に確かめ、`pubspec.lock`とプラットフォームごとの
  プラグイン登録ファイル(`linux/flutter/`・`windows/flutter/`の`generated_plugin*`、`macos/Flutter/GeneratedPluginRegistrant.swift`)の
  差分を一緒にcommitする
