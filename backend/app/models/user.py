import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, String, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base

ROLE_USER = "user"
ROLE_ADMIN = "admin"


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("email", name="users_email_key"),
        # メールアドレスは小文字で保存する(大文字小文字を区別せずに一意にするため)
        CheckConstraint("email = lower(email)", name="users_email_lowercase_check"),
        CheckConstraint("role IN ('user', 'admin')", name="users_role_check"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    email: Mapped[str] = mapped_column(String(255))
    # argon2のハッシュ。nullならパスワードでログインできない(0004以前からあるユーザー等)
    password_hash: Mapped[str | None] = mapped_column(String(255))
    display_name: Mapped[str] = mapped_column(String(50))
    role: Mapped[str] = mapped_column(String(20), server_default=text("'user'"))
    # メールアドレスの確認が済んだ日時。nullなら未確認(ログインはできるが同期はできない)
    email_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # アカウントを停止した日時(管理者が止める)。削除のtombstoneではない(削除は物理削除)
    disabled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )

    @property
    def is_admin(self) -> bool:
        return self.role == ROLE_ADMIN

    @property
    def email_verified(self) -> bool:
        return self.email_verified_at is not None
