import uuid
from datetime import datetime

from sqlalchemy import CHAR, DateTime, ForeignKey, Index, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class RefreshToken(Base):
    """リフレッシュトークン(更新のたびに1行)。トークンそのものは保存せず、SHA-256のハッシュだけを持つ。

    使用済み(used_at)の行は、再使用(盗まれた可能性)の検知のために有効期限まで残し、その後workerがパージする。
    """

    __tablename__ = "refresh_tokens"
    __table_args__ = (
        UniqueConstraint("token_hash", name="refresh_tokens_token_hash_key"),
        Index("idx_refresh_tokens_auth_session_id", "auth_session_id"),
        Index("idx_refresh_tokens_expires_at", "expires_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    auth_session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(
            "auth_sessions.id", ondelete="CASCADE", name="refresh_tokens_auth_session_id_fkey"
        ),
    )
    # トークンのSHA-256(16進数で64文字)
    token_hash: Mapped[str] = mapped_column(CHAR(64))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # 更新に使った日時。nullなら未使用(今使っているトークン)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )
