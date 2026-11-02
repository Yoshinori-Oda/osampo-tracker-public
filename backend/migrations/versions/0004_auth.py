"""認証: usersの拡張と、端末ごとのログイン状態(auth_sessions)・リフレッシュトークン(refresh_tokens)

設計はbackend/docs/バックエンド構成.mdの「認証」、仕様はbackend/docs/API設計ドラフト.mdの「認証のendpoints」。
既存のユーザーはpassword_hashがnull(パスワードでログインできない)のままにし、開発用はシード(app.cli seed-dev)で設定する。

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-08

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# revision identifiers, used by Alembic.
revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ---- usersの拡張 ----
    op.add_column("users", sa.Column("password_hash", sa.String(255), nullable=True))
    # 既存の行はメールアドレスの@より前を表示名にしてから、NOT NULLにする
    op.add_column("users", sa.Column("display_name", sa.String(50), nullable=True))
    op.execute("UPDATE users SET display_name = left(split_part(email, '@', 1), 50)")
    op.alter_column("users", "display_name", nullable=False)
    op.add_column(
        "users",
        sa.Column("role", sa.String(20), nullable=False, server_default=sa.text("'user'")),
    )
    op.add_column("users", sa.Column("email_verified_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("users", sa.Column("disabled_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column(
        "users",
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
    )
    # メールアドレスは小文字で保存する(大文字小文字を区別せずに一意にするため)
    op.execute("UPDATE users SET email = lower(email)")
    op.create_check_constraint("users_email_lowercase_check", "users", "email = lower(email)")
    op.create_check_constraint("users_role_check", "users", "role IN ('user', 'admin')")

    # ---- 端末ごとのログイン状態 ----
    op.create_table(
        "auth_sessions",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")
        ),
        sa.Column(
            "user_id",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE", name="auth_sessions_user_id_fkey"),
            nullable=False,
        ),
        sa.Column("device_id", UUID(as_uuid=True), nullable=False),
        sa.Column("device_name", sa.String(100), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column(
            "last_used_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("idx_auth_sessions_user_id", "auth_sessions", ["user_id"])
    # 同じユーザー・同じ端末の有効なログイン状態は1つだけ
    op.create_index(
        "uq_auth_sessions_active_device",
        "auth_sessions",
        ["user_id", "device_id"],
        unique=True,
        postgresql_where=sa.text("revoked_at IS NULL"),
    )
    op.create_index(
        "idx_auth_sessions_revoked_at",
        "auth_sessions",
        ["revoked_at"],
        postgresql_where=sa.text("revoked_at IS NOT NULL"),
    )

    # ---- リフレッシュトークン ----
    op.create_table(
        "refresh_tokens",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")
        ),
        sa.Column(
            "auth_session_id",
            UUID(as_uuid=True),
            sa.ForeignKey(
                "auth_sessions.id",
                ondelete="CASCADE",
                name="refresh_tokens_auth_session_id_fkey",
            ),
            nullable=False,
        ),
        sa.Column("token_hash", sa.CHAR(64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.UniqueConstraint("token_hash", name="refresh_tokens_token_hash_key"),
    )
    op.create_index("idx_refresh_tokens_auth_session_id", "refresh_tokens", ["auth_session_id"])
    op.create_index("idx_refresh_tokens_expires_at", "refresh_tokens", ["expires_at"])


def downgrade() -> None:
    op.drop_table("refresh_tokens")
    op.drop_table("auth_sessions")
    op.drop_constraint("users_role_check", "users", type_="check")
    op.drop_constraint("users_email_lowercase_check", "users", type_="check")
    for column in (
        "updated_at",
        "disabled_at",
        "email_verified_at",
        "role",
        "display_name",
        "password_hash",
    ):
        op.drop_column("users", column)
