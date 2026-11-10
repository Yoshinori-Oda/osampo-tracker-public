# 同期・削除の設計

関連: `frontend/lib/repositories/tracking_repository.dart`・`backend/app/services/session_service.py`・
`backend/app/services/purge_service.py`。APIの処理は`backend/docs/同期API.md`、同期を行う条件(ログイン・メールアドレスの確認)は
`frontend/docs/フロントエンド概要.md`の「認証とアカウント」。

このアプリは「複数端末・同一ユーザーでの同時操作は想定しない」前提で、シンプルな
pull型差分同期(`updated_at`ベース)を採用している。設計の要点:

- **時刻はサーバー時刻を正とする**。`updated_at`・`deleted_at`はサーバーが付け、差分取得(GET)のレスポンスの
  `synced_at`(検索を始める前のサーバー時刻)を、端末は次回の`last_synced_at`としてそのまま送る。端末の時計は使わない
- **同期の順番**: push(未同期のセッションを状態ごとにPOST/PATCH/DELETE)→ 削除と編集の競合の解決 → pull(GET)
  - `ended`(未登録)→ 登録のPOST。同じidの再送はサーバーが200で受け流す(可変の項目が変わっていれば反映する)。
    409 `id_conflicted`なら端末でidを振り直し、次回の同期で登録し直す
  - `updated`(同期済みの後に編集)→ PATCH(可変の3項目を毎回全て送る。レスポンスが返らない間にローカルで編集が増えても、
    次のPATCHで最新の値が送られる)
  - POST・PATCH・restoreのレスポンスの`updated_at`は、そのセッションの`updated_at`として保存する。`last_synced_at`には使わない
    (`last_synced_at`はGETの`synced_at`からだけ更新する)
  - `deletedUnsynced` → DELETE。204でも404 `session_not_found`(パージ済み・未登録)でも削除完了としてローカルの行を消す。
    `ended`の行を削除した場合もDELETEを送る(POSTのレスポンスだけが届かず、サーバーには登録済みの場合があるため)
  - push・pullの結果はステータスコードとレスポンスbodyの`code`で判定する。`user_not_found`や`code`の無い404は
    想定外として同期を中断し、ローカルのデータには触れない
- **削除は物理削除ではなくtombstone方式**。サーバーは`sessions.deleted_at`に削除した日時を入れ、`updated_at`も同時に
  更新することで、他端末が通常の差分pullの中で「削除された」(`id`と`deleted_at`だけの要素)ことを検知できるようにしている。
  ローカルの`deletedUnsynced`の行は、DELETEの成功が確認できた時点でそのまま物理削除してよい
- **リモートのtombstone行は長周期パージ**する(`worker`、24時間ごと)。他端末が確実にtombstoneを受け取れるよう、
  削除してから90日経ったものだけを物理削除する。90日より前に同期したきりの端末にはGETが`request_existence_check`を
  返すので、端末は同期済みのセッションのidで突き合わせ(existence-check)を行い、サーバーに無いものを消す。
  突き合わせが成功するまで`last_synced_at`は更新しない(途中で失敗しても、次回のGETで再び突き合わせが行われるように)
  - 送るIDは、同期済み(`synced`)のセッションのidから、今回のGETのレスポンスに含まれていたidを除いたもの。未同期のセッションは送らない
    (サーバーにまだ無いセッションを、削除済みと誤って判定してしまうため)
  - レスポンスの`missing_session_ids`のセッションは、確かめずにローカルから消す(通常のtombstoneの受信と同じ扱い)
- **削除と編集の競合**: 他端末で削除済みのセッションをローカルで編集していた場合、PATCH(または編集を含む登録の再送)が
  409 `deleted`(パージ前)か404 `session_not_found`(パージ済み)になり、これを競合として検出する。検出時はダイアログで
  「削除を受け入れる/編集内容を残して復活させる」を選ばせる。復活させる場合、パージ前ならrestore(削除の取り消しと
  編集内容の反映を1回で行う)、パージ済みなら登録のPOSTで作り直す
- 同期のトリガーは「ローカルでの書き込み操作の直後」に加えて、通知offでも変更を取り込めるよう
  アプリ起動時・フォアグラウンド復帰時(`WidgetsBindingObserver`)にも呼んでいる。失敗したら5分後に再試行する
- 本格的なリアルタイムpush(サーバー起動のpush通知等)は、複数端末同時操作を想定しない
  今回の規模では投資対効果が薄いと判断し採用していない
