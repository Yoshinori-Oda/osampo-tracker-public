"""sessions・track_pointsに行レベルセキュリティ(RLS)をかけ、worker用のロールに権限を付ける

設計はbackend/docs/バックエンド構成.mdの「行レベルセキュリティ(RLS)」。
- apiはトランザクションごとに今のユーザーのIDをset_config('app.user_id', ..., true)で渡す(app/db.py)。
  ポリシーは本人の行(管理者は全ての行)だけを許し、渡されていなければ何も見えない
- worker用のロール(初回起動時のスクリプトで作る)には、ジョブで使うテーブル・操作だけを付け、sessionsはパージのポリシーで全行を許す
- テーブルの所有者(マイグレーション用のロール)はFORCE ROW LEVEL SECURITYを付けないので対象外のまま

ポリシーの対象のロール名は設定(APP_DB_USER・WORKER_DB_USER)から読む。

Revision ID: 0009
Revises: 0008
Create Date: 2026-10-26

"""
from collections.abc import Sequence

from alembic import op

from app.config import settings

# revision identifiers, used by Alembic.
revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# workerのジョブで使うテーブルと操作(最小権限)。workerが新しいテーブルを使うときは、そのマイグレーションで足す
WORKER_GRANTS = {
    "sessions": "SELECT, DELETE",
    "refresh_tokens": "SELECT, DELETE",
    "auth_sessions": "SELECT, DELETE",
    "outbox_emails": "SELECT, UPDATE, DELETE",
    "audit_events": "SELECT, DELETE",
}


def _role(name: str | None, env_name: str) -> str:
    if name is None:
        raise RuntimeError(f"{env_name} が設定されていません(ポリシーの対象のロール名に使う)")
    return op.get_bind().dialect.identifier_preparer.quote(name)


def upgrade() -> None:
    app_role = _role(settings.app_db_user, "APP_DB_USER")
    worker_role = _role(settings.worker_db_user, "WORKER_DB_USER")

    for table, privileges in WORKER_GRANTS.items():
        op.execute(f"GRANT {privileges} ON {table} TO {worker_role}")

    # 今のユーザー(未設定ならNULL)。一度set_configした接続では、トランザクションの終了後に''へ戻ることがあるのでNULLIFで受ける
    op.execute(
        """
        CREATE FUNCTION app_current_user_id() RETURNS uuid
            LANGUAGE sql STABLE
            AS $$ SELECT NULLIF(current_setting('app.user_id', true), '')::uuid $$
        """
    )
    # 今のユーザーが管理者か。管理者かどうかの根拠はusers.roleだけにする(apiから別の値を渡さない)
    op.execute(
        """
        CREATE FUNCTION app_current_user_is_admin() RETURNS boolean
            LANGUAGE sql STABLE
            AS $$ SELECT EXISTS (SELECT 1 FROM users WHERE id = app_current_user_id() AND role = 'admin') $$
        """
    )

    op.execute("ALTER TABLE sessions ENABLE ROW LEVEL SECURITY")
    op.execute("ALTER TABLE track_points ENABLE ROW LEVEL SECURITY")

    # 関数は(SELECT ...)で囲む。行に依存しないサブクエリになり、1回の検索につき1回だけ実行される
    # 一般ユーザー: 自分の行だけを読み書きでき、自分のuser_idでしか書けない
    op.execute(
        f"""
        CREATE POLICY sessions_owner ON sessions FOR ALL TO {app_role}
            USING (user_id = (SELECT app_current_user_id()))
            WITH CHECK (user_id = (SELECT app_current_user_id()))
        """
    )
    # 管理者: 全ての行を読み書きできる
    op.execute(
        f"""
        CREATE POLICY sessions_admin ON sessions FOR ALL TO {app_role}
            USING ((SELECT app_current_user_is_admin()))
            WITH CHECK ((SELECT app_current_user_is_admin()))
        """
    )
    # worker: tombstoneのパージ(条件で列を読むのでSELECTも要る)。track_pointsはON DELETE CASCADEで消える
    op.execute(f"CREATE POLICY sessions_worker_select ON sessions FOR SELECT TO {worker_role} USING (true)")
    op.execute(f"CREATE POLICY sessions_worker_delete ON sessions FOR DELETE TO {worker_role} USING (true)")

    # track_pointsはuser_idを持たないので、session_id経由でsessionsのuser_idと比べる。
    # INSERTの検査にも使い、他人のsessionにtrack_pointを足せないようにする
    op.execute(
        f"""
        CREATE POLICY track_points_owner ON track_points FOR ALL TO {app_role}
            USING (EXISTS (
                SELECT 1 FROM sessions s
                WHERE s.id = track_points.session_id AND s.user_id = (SELECT app_current_user_id())
            ))
            WITH CHECK (EXISTS (
                SELECT 1 FROM sessions s
                WHERE s.id = track_points.session_id AND s.user_id = (SELECT app_current_user_id())
            ))
        """
    )
    op.execute(
        f"""
        CREATE POLICY track_points_admin ON track_points FOR ALL TO {app_role}
            USING ((SELECT app_current_user_is_admin()))
            WITH CHECK ((SELECT app_current_user_is_admin()))
        """
    )


def downgrade() -> None:
    worker_role = _role(settings.worker_db_user, "WORKER_DB_USER")

    op.execute("DROP POLICY track_points_admin ON track_points")
    op.execute("DROP POLICY track_points_owner ON track_points")
    op.execute("DROP POLICY sessions_worker_delete ON sessions")
    op.execute("DROP POLICY sessions_worker_select ON sessions")
    op.execute("DROP POLICY sessions_admin ON sessions")
    op.execute("DROP POLICY sessions_owner ON sessions")
    op.execute("ALTER TABLE track_points DISABLE ROW LEVEL SECURITY")
    op.execute("ALTER TABLE sessions DISABLE ROW LEVEL SECURITY")
    op.execute("DROP FUNCTION app_current_user_is_admin()")
    op.execute("DROP FUNCTION app_current_user_id()")

    for table, privileges in WORKER_GRANTS.items():
        op.execute(f"REVOKE {privileges} ON {table} FROM {worker_role}")
