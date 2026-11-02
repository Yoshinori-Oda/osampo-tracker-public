"""メールアドレスの確認コード(email_codes)と、outboxの送信期限・取り消し

設計はbackend/docs/バックエンド構成.mdの「メールアドレスの確認コード」。
- email_codes: ユーザーと用途ごとに1行の確認コード(送るたびに上書きする)
- outbox_emails: send_deadline(この日時を過ぎたら送らない)と、statusのcancelled(古いコードのメールの取り消し)

Revision ID: 0006
Revises: 0005
Create Date: 2026-10-14

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# revision identifiers, used by Alembic.
revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ---- outbox_emails ----
    op.add_column(
        "outbox_emails", sa.Column("send_deadline", sa.DateTime(timezone=True), nullable=True)
    )
    op.drop_constraint("outbox_emails_status_check", "outbox_emails", type_="check")
    op.create_check_constraint(
        "outbox_emails_status_check",
        "outbox_emails",
        "status IN ('pending', 'sent', 'failed', 'cancelled')",
    )

    # ---- email_codes ----
    op.create_table(
        "email_codes",
        sa.Column(
            "user_id",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE", name="email_codes_user_id_fkey"),
            primary_key=True,
        ),
        sa.Column("purpose", sa.String(30), primary_key=True),
        sa.Column("code_hash", sa.String(255), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("failed_attempts", sa.Integer(), nullable=False),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("send_count", sa.Integer(), nullable=False),
        sa.Column("send_window_started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "outbox_email_id",
            UUID(as_uuid=True),
            sa.ForeignKey(
                "outbox_emails.id", ondelete="SET NULL", name="email_codes_outbox_email_id_fkey"
            ),
            nullable=True,
        ),
        sa.CheckConstraint("purpose IN ('verify_email')", name="email_codes_purpose_check"),
        sa.CheckConstraint(
            "status IN ('pending', 'used', 'locked')", name="email_codes_status_check"
        ),
    )
    op.create_index("idx_email_codes_outbox_email_id", "email_codes", ["outbox_email_id"])


def downgrade() -> None:
    op.drop_table("email_codes")
    # 取り消した行は、元の状態の中では「諦めた」に当たる
    op.execute("UPDATE outbox_emails SET status = 'failed' WHERE status = 'cancelled'")
    op.drop_constraint("outbox_emails_status_check", "outbox_emails", type_="check")
    op.create_check_constraint(
        "outbox_emails_status_check", "outbox_emails", "status IN ('pending', 'sent', 'failed')"
    )
    op.drop_column("outbox_emails", "send_deadline")
