"""PostgRESTの削除に伴い、ストアドファンクションを削除し、deleted_atを「削除した日時」に統一する

frontendの同期を新しいAPI(FastAPI)へ切り替えたので、PostgRESTが使っていたものを片付ける。
- ストアドファンクション(register_session_with_points / fetch_remote_sessions)を削除する
- PostgREST時代のtombstoneは、deleted_atに「パージ予定日時(削除の90日後)」が入っている。新しいAPIでは
  deleted_atは「削除した日時」なので、パージ予定日時(未来の日時)が入っている行を90日前に戻して揃える。
  新しいAPIで削除した行は過去の日時が入っているので、この条件には当たらない
- PostgREST用のロール(web_anon)に付けていた権限を外す。ロール自体の削除はスーパーユーザーの権限が必要なので
  ここでは行わない(初回起動時のスクリプトからは作成をやめたので、ボリュームを作り直せば作られない)

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-06

"""
import importlib.util
from collections.abc import Sequence
from pathlib import Path

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# PostgREST時代のパージ期間(frontendがdeleted_atに「削除の90日後」を入れていた)
LEGACY_RETENTION = "90 days"

# web_anonが存在する場合だけ権限を外す(初回起動時のスクリプトで作らなくなった環境には存在しない)
REVOKE_WEB_ANON = """
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_anon') THEN
        REVOKE ALL ON ALL TABLES IN SCHEMA public FROM web_anon;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM web_anon;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM web_anon;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM web_anon;
    END IF;
END
$$;
"""


def upgrade() -> None:
    op.execute("DROP FUNCTION IF EXISTS public.fetch_remote_sessions(uuid, timestamptz, timestamptz)")
    op.execute("DROP FUNCTION IF EXISTS public.register_session_with_points(jsonb, jsonb)")
    op.execute(
        f"UPDATE sessions SET deleted_at = deleted_at - interval '{LEGACY_RETENTION}' "
        "WHERE deleted_at > clock_timestamp()"
    )
    op.execute(REVOKE_WEB_ANON)


def downgrade() -> None:
    # ストアドファンクションは0002の時点の定義(高度関連の3列をdouble precisionで保存する版)で作り直す。
    # 定義を写すと食い違うおそれがあるので、0001・0002のファイルから読み込む
    initial = _load_revision("0001_initial_schema.py")
    altitude = _load_revision("0002_altitude_columns_to_double_precision.py")
    op.execute(altitude._register_session_with_points("double precision"))
    op.execute(initial.FETCH_REMOTE_SESSIONS)
    # 全てのtombstoneのdeleted_atをパージ予定日時に戻す(PostgREST・cronが扱う形式)
    op.execute(
        f"UPDATE sessions SET deleted_at = deleted_at + interval '{LEGACY_RETENTION}' "
        "WHERE deleted_at IS NOT NULL"
    )
    # web_anonの権限は戻さない(PostgRESTを使う場合は初回起動時のスクリプトの旧版で設定し直す)


def _load_revision(filename: str):
    path = Path(__file__).parent / filename
    spec = importlib.util.spec_from_file_location(f"_revision_{path.stem}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
