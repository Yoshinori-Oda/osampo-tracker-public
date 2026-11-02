import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class AuthSession(Base):
    """端末ごとのログイン状態(1回のログインに1行)。idはアクセストークンの`sid`。

    リフレッシュトークンの系列はこの行に属する。無効にする(revoked_at)と、その端末のアクセストークンも
    リフレッシュトークンもすぐに使えなくなる。
    """

    __tablename__ = "auth_sessions"
    __table_args__ = (
        Index("idx_auth_sessions_user_id", "user_id"),
        # 同じユーザー・同じ端末の有効なログイン状態は1つだけ
        Index(
            "uq_auth_sessions_active_device",
            "user_id",
            "device_id",
            unique=True,
            postgresql_where=text("revoked_at IS NULL"),
        ),
        # パージ(無効にしてから一定期間経ったものの削除)用
        Index(
            "idx_auth_sessions_revoked_at",
            "revoked_at",
            postgresql_where=text("revoked_at IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE", name="auth_sessions_user_id_fkey"),
    )
    # 端末が初回起動時に生成したUUID(ハードウェアの情報はOSが提供しないため)
    device_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    # 端末の表示名。今のfrontendは送らない(端末の一覧の画面を作るときに送る)
    device_name: Mapped[str | None] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )
    # 最後にトークンを更新した日時(毎リクエストの書き込みを避けるため、トークンの更新時だけ書き換える)
    last_used_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )
    # 無効にした日時(ログアウト・同じ端末での再ログイン・使用済みのトークンの再使用・アカウントの停止)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
