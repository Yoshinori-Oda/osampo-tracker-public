"""メール送信の基盤: 送信待ちのメールと送信の記録(outbox_emails)

設計はbackend/docs/バックエンド構成.mdの「メール送信の基盤」。apiが積み、workerが送る。

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-14

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# revision identifiers, used by Alembic.
revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "outbox_emails",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")
        ),
        sa.Column(
            "recipient_user_id",
            UUID(as_uuid=True),
            sa.ForeignKey(
                "users.id", ondelete="CASCADE", name="outbox_emails_recipient_user_id_fkey"
            ),
            nullable=True,
        ),
        sa.Column("to_address", sa.String(255), nullable=False),
        sa.Column("subject", sa.String(200), nullable=False),
        sa.Column("body", sa.Text(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default=sa.text("'pending'")),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column(
            "next_attempt_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'sent', 'failed')", name="outbox_emails_status_check"
        ),
    )
    # workerが送信待ちの行を探す用
    op.create_index(
        "idx_outbox_emails_next_attempt_at",
        "outbox_emails",
        ["next_attempt_at"],
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.create_index("idx_outbox_emails_recipient_user_id", "outbox_emails", ["recipient_user_id"])
    # パージ用
    op.create_index("idx_outbox_emails_created_at", "outbox_emails", ["created_at"])


def downgrade() -> None:
    op.drop_table("outbox_emails")
