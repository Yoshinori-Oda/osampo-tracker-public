"""DBのロールの権限と、ORMのモデルがマイグレーションで作ったテーブルと合っていることの確認。

テスト用のデータベースに`alembic -x db=test upgrade head`を実行済みの前提。
各テストはトランザクションの中で実行し、最後にロールバックするのでデータは残らない。
"""

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from geoalchemy2 import WKTElement
from sqlalchemy import func, select, text
from sqlalchemy.exc import InvalidRequestError, ProgrammingError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncSession, create_async_engine
from sqlalchemy.orm import selectinload
from sqlalchemy.pool import NullPool

from app.config import settings
from app.db import set_rls_user
from app.models import TrackingSession, TrackPoint, User


@pytest.fixture
async def app_connection() -> AsyncIterator[AsyncConnection]:
    """アプリ用のロールでテスト用のデータベースに接続し、テストの最後にロールバックする。"""
    # テストごとにイベントループが変わるので、接続を使い回さない(NullPool)
    engine = create_async_engine(settings.app_database_url, poolclass=NullPool)
    async with engine.connect() as connection:
        transaction = await connection.begin()
        yield connection
        await transaction.rollback()
    await engine.dispose()


async def test_app_role_cannot_create_table(app_connection: AsyncConnection):
    with pytest.raises(ProgrammingError):
        await app_connection.execute(text("CREATE TABLE should_not_be_created (id integer)"))


async def test_app_role_can_write_and_read_session_with_track_points(
    app_connection: AsyncConnection,
):
    session = AsyncSession(bind=app_connection, join_transaction_mode="create_savepoint")

    user = User(email=f"{uuid.uuid4()}@example.com", display_name="テスト")
    session.add(user)
    await session.flush()
    # sessionsのRLSのため、今のユーザーを渡す
    await set_rls_user(session, user.id)

    started_at = datetime(2026, 10, 1, 8, 0, tzinfo=UTC)
    tracking_session = TrackingSession(
        user_id=user.id,
        name="近所のお散歩",
        started_at=started_at,
        ended_at=datetime(2026, 10, 1, 8, 30, tzinfo=UTC),
        move_method="walk",
        track_points=[
            TrackPoint(
                location=WKTElement("POINTZ(139.767125 35.681236 10.5)", srid=4326),
                recorded_at=started_at,
            ),
        ],
    )
    session.add(tracking_session)
    await session.flush()
    session.expunge_all()

    loaded = (
        await session.execute(
            select(TrackingSession)
            .options(selectinload(TrackingSession.track_points))
            .where(TrackingSession.id == tracking_session.id)
        )
    ).scalar_one()
    # サーバー側の既定値が入っていること
    assert loaded.is_favorite is False
    assert loaded.total_distance == 0.0
    assert loaded.updated_at is not None
    assert loaded.deleted_at is None
    assert len(loaded.track_points) == 1

    location_text = (
        await session.execute(
            select(func.ST_AsText(TrackPoint.location)).where(
                TrackPoint.session_id == tracking_session.id
            )
        )
    ).scalar_one()
    assert location_text == "POINT Z (139.767125 35.681236 10.5)"


async def test_track_points_relationship_is_not_lazy_loaded(app_connection: AsyncConnection):
    # 非同期では暗黙の遅延ロードができないので、読み込み忘れはエラーになる(lazy="raise")
    session = AsyncSession(bind=app_connection, join_transaction_mode="create_savepoint")
    user = User(email=f"{uuid.uuid4()}@example.com", display_name="テスト")
    session.add(user)
    await session.flush()
    # sessionsのRLSのため、今のユーザーを渡す
    await set_rls_user(session, user.id)
    tracking_session = TrackingSession(
        user_id=user.id,
        name="読み込み忘れの確認",
        started_at=datetime(2026, 10, 1, 8, 0, tzinfo=UTC),
        ended_at=datetime(2026, 10, 1, 8, 30, tzinfo=UTC),
        move_method="walk",
    )
    session.add(tracking_session)
    await session.flush()
    session.expunge_all()

    loaded = (
        await session.execute(
            select(TrackingSession).where(TrackingSession.id == tracking_session.id)
        )
    ).scalar_one()
    with pytest.raises(InvalidRequestError, match="lazy"):
        _ = loaded.track_points


# REAL(単精度、有効数字は約7桁)では丸められてしまう値。端末(Dartのdouble)と同じ倍精度なら一致する
ELEVATION_GAIN = 123.456789012345
MAX_ALTITUDE = 45.678901234567
MIN_ALTITUDE = 12.345678901234


async def test_altitude_columns_keep_double_precision(app_connection: AsyncConnection):
    session = AsyncSession(bind=app_connection, join_transaction_mode="create_savepoint")
    user = User(email=f"{uuid.uuid4()}@example.com", display_name="テスト")
    session.add(user)
    await session.flush()
    # sessionsのRLSのため、今のユーザーを渡す
    await set_rls_user(session, user.id)
    tracking_session = TrackingSession(
        user_id=user.id,
        name="精度の確認",
        started_at=datetime(2026, 10, 1, 8, 0, tzinfo=UTC),
        ended_at=datetime(2026, 10, 1, 8, 30, tzinfo=UTC),
        move_method="walk",
        elevation_gain=ELEVATION_GAIN,
        max_altitude=MAX_ALTITUDE,
        min_altitude=MIN_ALTITUDE,
    )
    session.add(tracking_session)
    await session.flush()
    session.expunge_all()

    loaded = await session.get(TrackingSession, tracking_session.id)
    assert loaded is not None
    assert loaded.elevation_gain == ELEVATION_GAIN
    assert loaded.max_altitude == MAX_ALTITUDE
    assert loaded.min_altitude == MIN_ALTITUDE


async def test_postgrest_functions_are_removed(app_connection: AsyncConnection):
    # 0003でPostgREST用のストアドファンクションを削除している
    remaining = (
        await app_connection.execute(
            text(
                "SELECT proname FROM pg_proc WHERE proname IN "
                "('register_session_with_points', 'fetch_remote_sessions')"
            )
        )
    ).all()
    assert remaining == []
