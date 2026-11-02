import uuid
from datetime import datetime

from geoalchemy2 import Geography, WKBElement
from sqlalchemy import BigInteger, DateTime, ForeignKey, Index
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class TrackPoint(Base):
    __tablename__ = "track_points"
    __table_args__ = (Index("idx_track_points_session_id", "session_id"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("sessions.id", ondelete="CASCADE", name="track_points_session_id_fkey"),
    )
    # 経度・緯度・高度(POINTZ)。現行スキーマには空間インデックスが無いので作らない
    location: Mapped[WKBElement] = mapped_column(
        Geography(geometry_type="POINTZ", srid=4326, spatial_index=False)
    )
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
