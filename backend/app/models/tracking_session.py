import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Integer, String, text
from sqlalchemy.dialects.postgresql import DOUBLE_PRECISION, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base
from app.models.track_point import TrackPoint


class TrackingSession(Base):
    """記録したセッション(テーブル名はsessions)。

    SQLAlchemyのSession(DBセッション)と紛らわしいので、クラス名はTrackingSessionにしている。
    """

    __tablename__ = "sessions"
    __table_args__ = (
        Index("idx_sessions_user_id", "user_id"),
        Index("idx_sessions_updated_at", "updated_at"),
        # パージ処理の対象抽出用。tombstone行は少数のはずなので部分インデックスにする
        Index(
            "idx_sessions_deleted_at",
            "deleted_at",
            postgresql_where=text("deleted_at IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE", name="sessions_user_id_fkey"),
    )
    name: Mapped[str] = mapped_column(String(100))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    is_favorite: Mapped[bool] = mapped_column(Boolean, server_default=text("false"))
    updated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    move_method: Mapped[str] = mapped_column(String(50))
    total_distance: Mapped[float] = mapped_column(DOUBLE_PRECISION, server_default=text("0.0"))
    duration_seconds: Mapped[int] = mapped_column(Integer, server_default=text("0"))
    # 端末(Dartのdouble)と同じ倍精度にする(0002でREALから変更。POSTの再送判定で値を比較するため)
    elevation_gain: Mapped[float] = mapped_column(DOUBLE_PRECISION, server_default=text("0.0"))
    max_altitude: Mapped[float | None] = mapped_column(DOUBLE_PRECISION)
    min_altitude: Mapped[float | None] = mapped_column(DOUBLE_PRECISION)

    # 非同期では関連の遅延ロード(アクセスした時に暗黙にSELECTする)ができないので、lazy="raise"で
    # 読み込み忘れをエラーにする。読み込むときはselectinload(TrackingSession.track_points)を指定する
    track_points: Mapped[list[TrackPoint]] = relationship(
        lazy="raise",
        cascade="all, delete-orphan",
        passive_deletes=True,
        order_by=TrackPoint.recorded_at,
    )
