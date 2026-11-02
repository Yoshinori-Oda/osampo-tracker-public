"""行レベルセキュリティ(RLS)とworker用のロールの権限のテスト。設計はbackend/docs/バックエンド構成.mdの「行レベルセキュリティ(RLS)」。

APIを通したテスト(test_sync_api.py等)はconftestのdb_sessionの外側のトランザクションの中で動き、commitがセーブポイントの確定になる。
set_config(..., true)は外側のトランザクションが続く限り残るので、「commitの後に今のユーザーを渡し直す」ことはここで、
本物のトランザクションで確認する。workerのロールのテストは、別の接続から見えるようにマイグレーション用のロールでデータを
commitし、最後に消す。
"""

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import pytest
from geoalchemy2 import WKTElement
from sqlalchemy import URL, delete, func, insert, select, text, update
from sqlalchemy.exc import ProgrammingError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, AsyncSession, create_async_engine
from sqlalchemy.pool import NullPool

from app.config import settings
from app.db import DB_CONNECT_ARGS, set_rls_user
from app.models import TrackingSession, TrackPoint, User
from app.models.user import ROLE_ADMIN, ROLE_USER
from app.services.mail_service import send_pending_emails
from app.services.purge_service import (
    purge_expired_auth,
    purge_expired_tombstones,
    purge_old_audit_events,
    purge_old_outbox_emails,
)

STARTED_AT = datetime(2026, 10, 1, 8, 0, tzinfo=UTC)
RETENTION_DAYS = 90


async def _engine(url: URL) -> AsyncIterator[AsyncEngine]:
    # テストごとにイベントループが変わるので、接続を使い回さない(NullPool)
    engine = create_async_engine(url, poolclass=NullPool, connect_args=DB_CONNECT_ARGS)
    yield engine
    await engine.dispose()


@pytest.fixture
async def app_engine() -> AsyncIterator[AsyncEngine]:
    async for engine in _engine(settings.app_database_url):
        yield engine


@pytest.fixture
async def worker_engine() -> AsyncIterator[AsyncEngine]:
    async for engine in _engine(settings.worker_database_url):
        yield engine


@pytest.fixture
async def migrator_engine() -> AsyncIterator[AsyncEngine]:
    async for engine in _engine(settings.migrator_database_url(settings.postgres_db)):
        yield engine


@pytest.fixture
async def app_connection(app_engine: AsyncEngine) -> AsyncIterator[AsyncConnection]:
    """api用のロールの接続。テストの最後にロールバックする。"""
    async with app_engine.connect() as connection:
        transaction = await connection.begin()
        yield connection
        await transaction.rollback()


async def as_user(conn: AsyncConnection, user_id: uuid.UUID | None) -> None:
    """RLSの今のユーザーを切り替える(Noneなら渡していない状態)。"""
    value = "" if user_id is None else str(user_id)
    await conn.execute(text("SELECT set_config('app.user_id', :v, true)"), {"v": value})


async def add_user(conn: AsyncConnection, role: str = ROLE_USER) -> uuid.UUID:
    return await conn.scalar(
        insert(User)
        .values(email=f"{uuid.uuid4()}@example.com", display_name="テスト", role=role)
        .returning(User.id)
    )


async def add_session(
    conn: AsyncConnection, user_id: uuid.UUID, deleted_at: datetime | None = None
) -> uuid.UUID:
    """sessionとtrack_pointを1つずつ作る(RLSでは今のユーザーがuser_idと同じか、管理者である必要がある)。"""
    session_id = await conn.scalar(
        insert(TrackingSession)
        .values(
            user_id=user_id,
            name="RLSの確認",
            started_at=STARTED_AT,
            ended_at=STARTED_AT + timedelta(minutes=30),
            move_method="walk",
            deleted_at=deleted_at,
        )
        .returning(TrackingSession.id)
    )
    await add_track_point(conn, session_id)
    return session_id


async def add_track_point(conn: AsyncConnection, session_id: uuid.UUID) -> None:
    await conn.execute(
        insert(TrackPoint).values(
            session_id=session_id,
            location=WKTElement("POINTZ(139.767125 35.681236 10.5)", srid=4326),
            recorded_at=STARTED_AT,
        )
    )


async def visible_counts(conn: AsyncConnection, session_id: uuid.UUID) -> tuple[int, int]:
    """(見えるsessionの数, 見えるtrack_pointの数)。"""
    sessions = await conn.scalar(
        select(func.count()).select_from(TrackingSession).where(TrackingSession.id == session_id)
    )
    points = await conn.scalar(
        select(func.count()).select_from(TrackPoint).where(TrackPoint.session_id == session_id)
    )
    return sessions, points


# ---- 設定の確認 ------------------------------------------------------------------------


async def test_rls_is_enabled_and_app_role_is_not_table_owner(app_connection: AsyncConnection):
    # apiを誤ってテーブルの所有者(マイグレーション用のロール)で動かすと、RLSが黙って無効になるため
    rows = (
        await app_connection.execute(
            text(
                "SELECT relname, relrowsecurity, relforcerowsecurity, pg_get_userbyid(relowner) AS owner"
                " FROM pg_class WHERE relname IN ('sessions', 'track_points') AND relkind = 'r'"
            )
        )
    ).all()
    assert {r.relname for r in rows} == {"sessions", "track_points"}
    for row in rows:
        assert row.relrowsecurity is True
        assert row.relforcerowsecurity is False
        assert row.owner != settings.app_db_user
    assert await app_connection.scalar(text("SELECT current_user")) == settings.app_db_user


# ---- 一般ユーザー -------------------------------------------------------------------------


async def test_nothing_is_visible_without_current_user(app_connection: AsyncConnection):
    user_id = await add_user(app_connection)
    await as_user(app_connection, user_id)
    session_id = await add_session(app_connection, user_id)

    await as_user(app_connection, None)

    assert await visible_counts(app_connection, session_id) == (0, 0)
    with pytest.raises(ProgrammingError, match="row-level security"):
        async with app_connection.begin_nested():
            await add_session(app_connection, user_id)


async def test_other_users_rows_are_invisible_and_cannot_be_changed(
    app_connection: AsyncConnection,
):
    owner_id = await add_user(app_connection)
    other_id = await add_user(app_connection)
    await as_user(app_connection, owner_id)
    session_id = await add_session(app_connection, owner_id)
    assert await visible_counts(app_connection, session_id) == (1, 1)

    await as_user(app_connection, other_id)

    assert await visible_counts(app_connection, session_id) == (0, 0)
    # 見えない行は更新・削除の対象にならない
    updated = await app_connection.execute(
        update(TrackingSession).where(TrackingSession.id == session_id).values(name="書き換え")
    )
    deleted = await app_connection.execute(
        delete(TrackPoint).where(TrackPoint.session_id == session_id)
    )
    assert (updated.rowcount, deleted.rowcount) == (0, 0)
    # 他ユーザーのuser_idでは書けず、他ユーザーのsessionにtrack_pointを足すこともできない
    with pytest.raises(ProgrammingError, match="row-level security"):
        async with app_connection.begin_nested():
            await add_session(app_connection, owner_id)
    with pytest.raises(ProgrammingError, match="row-level security"):
        async with app_connection.begin_nested():
            await add_track_point(app_connection, session_id)
    # 自分の行を他ユーザーのものに書き換えることもできない
    own_session_id = await add_session(app_connection, other_id)
    with pytest.raises(ProgrammingError, match="row-level security"):
        async with app_connection.begin_nested():
            await app_connection.execute(
                update(TrackingSession)
                .where(TrackingSession.id == own_session_id)
                .values(user_id=owner_id)
            )

    await as_user(app_connection, owner_id)
    assert await visible_counts(app_connection, session_id) == (1, 1)


# ---- 管理者 ------------------------------------------------------------------------------


async def test_admin_can_read_and_write_all_rows(app_connection: AsyncConnection):
    owner_id = await add_user(app_connection)
    admin_id = await add_user(app_connection, role=ROLE_ADMIN)
    await as_user(app_connection, owner_id)
    session_id = await add_session(app_connection, owner_id)

    await as_user(app_connection, admin_id)

    assert await visible_counts(app_connection, session_id) == (1, 1)
    await add_track_point(app_connection, session_id)
    other_session_id = await add_session(app_connection, owner_id)
    assert await visible_counts(app_connection, other_session_id) == (1, 1)


async def test_admin_check_uses_users_role(app_connection: AsyncConnection):
    # 管理者かどうかはusers.roleだけで決まる(管理者でなくなれば他ユーザーの行は見えない)
    owner_id = await add_user(app_connection)
    admin_id = await add_user(app_connection, role=ROLE_ADMIN)
    await as_user(app_connection, owner_id)
    session_id = await add_session(app_connection, owner_id)

    await app_connection.execute(update(User).where(User.id == admin_id).values(role=ROLE_USER))
    await as_user(app_connection, admin_id)

    assert await visible_counts(app_connection, session_id) == (0, 0)


# ---- 今のユーザーの渡し方(app/db.py) ---------------------------------------------------------


async def test_current_user_is_passed_again_after_commit(app_engine: AsyncEngine):
    user_id = uuid.uuid4()
    current = text("SELECT app_current_user_id()")
    async with AsyncSession(app_engine) as db:
        # トランザクションの途中で渡した場合は、その場で渡す
        assert await db.scalar(current) is None
        await set_rls_user(db, user_id)
        assert await db.scalar(current) == user_id
        await db.commit()
        # commitで消えたSET LOCALを、次のトランザクションの開始時に渡し直す
        assert await db.scalar(current) == user_id
        await db.rollback()
        assert await db.scalar(current) == user_id


async def test_current_user_is_null_after_transaction_ends(app_engine: AsyncEngine):
    # 一度SET LOCALした接続では、トランザクションの終了後にcurrent_settingが''を返す(NULLIFでNULLにする)
    async with app_engine.connect() as conn:
        async with conn.begin():
            await as_user(conn, uuid.uuid4())
        async with conn.begin():
            assert await conn.scalar(text("SELECT current_setting('app.user_id', true)")) in ("", None)
            assert await conn.scalar(text("SELECT app_current_user_id()")) is None


# ---- worker用のロール ---------------------------------------------------------------------


async def test_worker_purges_tombstones_of_all_users(
    migrator_engine: AsyncEngine, worker_engine: AsyncEngine
):
    old = datetime.now(UTC) - timedelta(days=RETENTION_DAYS + 1)
    # マイグレーション用のロール(テーブルの所有者)はRLSの対象外なので、複数のユーザーのデータを用意できる
    async with migrator_engine.begin() as conn:
        user_ids = [await add_user(conn), await add_user(conn)]
        expired = [await add_session(conn, user_id, deleted_at=old) for user_id in user_ids]
        alive = await add_session(conn, user_ids[0])
    try:
        async with AsyncSession(worker_engine) as db:
            assert await purge_expired_tombstones(db, RETENTION_DAYS) >= len(expired)

        async with migrator_engine.connect() as conn:
            for session_id in expired:
                # track_pointsもON DELETE CASCADEで消える(workerにtrack_pointsの権限は無い)
                assert await visible_counts(conn, session_id) == (0, 0)
            assert await visible_counts(conn, alive) == (1, 1)
    finally:
        async with migrator_engine.begin() as conn:
            await conn.execute(delete(User).where(User.id.in_(user_ids)))


async def test_worker_jobs_run_with_worker_role(worker_engine: AsyncEngine):
    # ジョブで使う操作の権限があること(消す対象が無くても、条件で列を読む・行をロックするには権限が要る)
    async def send(_message) -> None:
        raise AssertionError("送信待ちのメールは無い前提")

    async with AsyncSession(worker_engine) as db:
        await purge_expired_tombstones(db, RETENTION_DAYS)
        await purge_expired_auth(db, 30)
        await purge_old_outbox_emails(db, 90)
        await purge_old_audit_events(db, 90)
        await send_pending_emails(db, send, max_attempts=5)


@pytest.mark.parametrize(
    "statement",
    [
        "SELECT count(*) FROM users",
        "SELECT count(*) FROM track_points",
        (
            "INSERT INTO sessions (user_id, name, started_at, ended_at, move_method)"
            " VALUES (gen_random_uuid(), 'x', now(), now(), 'walk')"
        ),
        "UPDATE sessions SET name = 'x'",
        "INSERT INTO audit_events (event_type) VALUES ('x')",
    ],
)
async def test_worker_cannot_use_tables_outside_its_jobs(worker_engine: AsyncEngine, statement: str):
    async with worker_engine.connect() as conn:
        with pytest.raises(ProgrammingError, match="permission denied"):
            await conn.execute(text(statement))
