"""監査ログ(audit_events)にリクエストIDを加える

設計はbackend/docs/バックエンド構成.mdの「ログ」。監査ログの出来事から、同じリクエストのアクセスログ・アプリのログを
たどれるようにする。既存の行はnullのまま。

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-23

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("audit_events", sa.Column("request_id", sa.String(64), nullable=True))


def downgrade() -> None:
    op.drop_column("audit_events", "request_id")
