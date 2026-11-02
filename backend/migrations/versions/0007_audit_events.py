"""監査ログ(audit_events)

設計はbackend/docs/バックエンド構成.mdの「監査ログ」。
- 認証・アカウント・権限の出来事を1件1行で残す(追記のみ)
- user_idには外部キーを付けない(アカウントの削除の記録を、ユーザーを消した後も残すため)
- event_typeにはCHECK制約を付けない(出来事の種類を増やすたびにマイグレーションが要らないように)

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-23

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import INET, UUID

# revision identifiers, used by Alembic.
revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "audit_events",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), primary_key=True),
        sa.Column(
            "occurred_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("clock_timestamp()"),
            nullable=False,
        ),
        sa.Column("event_type", sa.String(50), nullable=False),
        sa.Column("reason", sa.String(50), nullable=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=True),
        sa.Column("email", sa.String(255), nullable=True),
        sa.Column("device_id", UUID(as_uuid=True), nullable=True),
        sa.Column("ip", INET(), nullable=True),
        sa.Column("target_user_id", UUID(as_uuid=True), nullable=True),
    )
    op.create_index("idx_audit_events_user_id", "audit_events", ["user_id", "occurred_at"])
    op.create_index("idx_audit_events_email", "audit_events", ["email", "occurred_at"])
    op.create_index("idx_audit_events_occurred_at", "audit_events", ["occurred_at"])


def downgrade() -> None:
    op.drop_table("audit_events")
