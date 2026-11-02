"""長周期パージ(app/services/purge_service.py)のテスト。"""

import uuid
from datetime import UTC, datetime, timedelta

from geoalchemy2 import WKTElement
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import set_rls_user
from app.models import (
    AuditEvent,
    AuthSession,
    OutboxEmail,
    RefreshToken,
    TrackingSession,
    TrackPoint,
    User,
)
from app.models.outbox_email import OUTBOX_CANCELLED, OUTBOX_FAILED, OUTBOX_PENDING, OUTBOX_SENT
from app.services.mail_service import enqueue_email
from app.services.purge_service import (
    purge_expired_auth,
    purge_expired_tombstones,
    purge_old_audit_events,
    purge_old_outbox_emails,
)

RETENTION_DAYS = 90


async def add_session(
    db: AsyncSession, user: User, name: str, deleted_at: datetime | None
) -> TrackingSession:
    # sessionsのRLSのため、今のユーザーを渡す。パージもこのDBセッション(api用のロール)で実行するので、
    # 見えるのはこのユーザーの行だけになる(worker用のロールでのパージはtest_rls.pyで確認する)
    await set_rls_user(db, user.id)
    started_at = datetime(2026, 6, 1, 8, 0, tzinfo=UTC)
    tracking_session = TrackingSession(
        user_id=user.id,
        name=name,
        started_at=started_at,
        ended_at=started_at + timedelta(minutes=30),
        move_method="walk",
        deleted_at=deleted_at,
        track_points=[
            TrackPoint(
                location=WKTElement("POINTZ(139.767125 35.681236 10.5)", srid=4326),
                recorded_at=started_at,
            ),
        ],
    )
    db.add(tracking_session)
    await db.flush()
    return tracking_session


async def remaining_names(db: AsyncSession) -> set[str]:
    return set(await db.scalars(select(TrackingSession.name)))


async def test_purges_only_tombstones_older_than_retention(db_session: AsyncSession, user: User):
    now = datetime.now(UTC)
    expired = await add_session(
        db_session, user, "パージ期間を過ぎた削除", now - timedelta(days=RETENTION_DAYS + 1)
    )
    await add_session(
        db_session, user, "パージ期間内の削除", now - timedelta(days=RETENTION_DAYS - 1)
    )
    await add_session(db_session, user, "生きている", None)

    purged = await purge_expired_tombstones(db_session, RETENTION_DAYS)

    assert purged == 1
    assert await remaining_names(db_session) == {"パージ期間内の削除", "生きている"}
    # track_pointsもON DELETE CASCADEで一緒に消える
    remaining_points = await db_session.scalar(
        select(func.count()).where(TrackPoint.session_id == expired.id)
    )
    assert remaining_points == 0


async def test_purge_with_nothing_to_delete_returns_zero(db_session: AsyncSession, user: User):
    await add_session(db_session, user, "生きている", None)

    assert await purge_expired_tombstones(db_session, RETENTION_DAYS) == 0


REFRESH_TOKEN_TTL_DAYS = 30


async def add_refresh_token(db: AsyncSession, auth_session: AuthSession, expires_at: datetime) -> None:
    db.add(
        RefreshToken(
            auth_session_id=auth_session.id,
            token_hash=uuid.uuid4().hex + uuid.uuid4().hex,
            expires_at=expires_at,
        )
    )
    await db.flush()


async def test_purges_expired_refresh_tokens_and_old_revoked_logins(
    db_session: AsyncSession, user: User
):
    now = datetime.now(UTC)
    active = AuthSession(user_id=user.id, device_id=uuid.uuid4())
    recently_revoked = AuthSession(user_id=user.id, device_id=uuid.uuid4(), revoked_at=now - timedelta(days=1))
    old_revoked = AuthSession(
        user_id=user.id, device_id=uuid.uuid4(), revoked_at=now - timedelta(days=REFRESH_TOKEN_TTL_DAYS + 1)
    )
    db_session.add_all([active, recently_revoked, old_revoked])
    await db_session.flush()
    await add_refresh_token(db_session, active, now + timedelta(days=10))
    await add_refresh_token(db_session, active, now - timedelta(seconds=1))  # 期限切れ

    tokens, auth_sessions = await purge_expired_auth(db_session, REFRESH_TOKEN_TTL_DAYS)

    assert (tokens, auth_sessions) == (1, 1)
    remaining_sessions = set(await db_session.scalars(select(AuthSession.id).where(AuthSession.user_id == user.id)))
    assert remaining_sessions == {active.id, recently_revoked.id}
    remaining_tokens = await db_session.scalar(
        select(func.count()).select_from(RefreshToken).where(RefreshToken.auth_session_id == active.id)
    )
    assert remaining_tokens == 1


OUTBOX_RETENTION_DAYS = 90


async def add_outbox_email(db: AsyncSession, subject: str, status: str, age_days: int) -> None:
    email = await enqueue_email(db, to_address="taro@example.com", subject=subject, body="本文")
    email.status = status
    email.created_at = datetime.now(UTC) - timedelta(days=age_days)
    await db.flush()


async def test_purges_only_old_completed_outbox_emails(db_session: AsyncSession):
    await add_outbox_email(db_session, "古い送信済み", OUTBOX_SENT, OUTBOX_RETENTION_DAYS + 1)
    await add_outbox_email(db_session, "古い諦めた", OUTBOX_FAILED, OUTBOX_RETENTION_DAYS + 1)
    await add_outbox_email(db_session, "古い取り消した", OUTBOX_CANCELLED, OUTBOX_RETENTION_DAYS + 1)
    await add_outbox_email(db_session, "新しい送信済み", OUTBOX_SENT, OUTBOX_RETENTION_DAYS - 1)
    await add_outbox_email(db_session, "新しい取り消した", OUTBOX_CANCELLED, OUTBOX_RETENTION_DAYS - 1)
    # 送信待ちは古くても消さない
    await add_outbox_email(db_session, "古い送信待ち", OUTBOX_PENDING, OUTBOX_RETENTION_DAYS + 1)

    purged = await purge_old_outbox_emails(db_session, OUTBOX_RETENTION_DAYS)

    assert purged == 3
    remaining = set(await db_session.scalars(select(OutboxEmail.subject)))
    assert remaining == {"新しい送信済み", "新しい取り消した", "古い送信待ち"}


async def test_purges_only_audit_events_older_than_retention(db_session: AsyncSession):
    now = datetime.now(UTC)
    for reason, age_days in [("古い", RETENTION_DAYS + 1), ("新しい", RETENTION_DAYS - 1)]:
        db_session.add(
            AuditEvent(
                event_type="login_failed", reason=reason, occurred_at=now - timedelta(days=age_days)
            )
        )
    await db_session.flush()

    purged = await purge_old_audit_events(db_session, RETENTION_DAYS)

    assert purged == 1
    assert set(await db_session.scalars(select(AuditEvent.reason))) == {"新しい"}
