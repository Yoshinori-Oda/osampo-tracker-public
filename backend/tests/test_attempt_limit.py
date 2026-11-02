"""ログインと、現在のパスワードによる再確認(パスワードの変更)の試行回数の制限のテスト。

設計はbackend/docs/バックエンド構成.mdの「ログインの試行回数の制限」。失敗は監査ログから数えるので、
多くのテストは監査ログに失敗を直接書いて状況を作る(APIで10回間違えるのはargon2の照合で遅いため、代表の2件だけ)。
"""

import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import AuditEvent, User
from app.models.audit_event import (
    EVENT_LOGIN_FAILED,
    EVENT_LOGIN_LOCKED,
    EVENT_LOGIN_SUCCEEDED,
    EVENT_PASSWORD_CHANGE_FAILED,
    EVENT_PASSWORD_CHANGE_LOCKED,
    EVENT_PASSWORD_CHANGED,
)

PASSWORD = "correct-horse"
NEW_PASSWORD = "battery-staple"
MAX = settings.auth_max_failed_attempts
LOCK_SECONDS = settings.auth_lock_minutes * 60


async def add_events(
    db: AsyncSession,
    event_type: str,
    count: int,
    *,
    minutes_ago: float = 0,
    email: str | None = None,
    user_id: uuid.UUID | None = None,
    reason: str | None = "invalid_credentials",
) -> None:
    """出来事をcount件、minutes_ago分前から1秒ずつ古くして書く。"""
    newest = datetime.now(UTC) - timedelta(minutes=minutes_ago)
    for i in range(count):
        db.add(
            AuditEvent(
                event_type=event_type,
                email=email,
                user_id=user_id,
                reason=reason if event_type == EVENT_LOGIN_FAILED else None,
                occurred_at=newest - timedelta(seconds=i),
            )
        )
    await db.flush()


async def count_events(db: AsyncSession, event_type: str) -> int:
    return await db.scalar(
        select(func.count()).select_from(AuditEvent).where(AuditEvent.event_type == event_type)
    )


async def login(client: AsyncClient, email: str, password: str = PASSWORD):
    return await client.post(
        "/api/auth/login",
        json={"email": email, "password": password, "device_id": str(uuid.uuid4())},
    )


async def change_password(client: AsyncClient, current: str, new: str = NEW_PASSWORD):
    return await client.put(
        "/api/users/me/password", json={"current_password": current, "new_password": new}
    )


def assert_locked(response) -> None:
    assert response.status_code == 429, response.text
    assert response.json()["code"] == "too_many_requests"
    assert 0 < int(response.headers["Retry-After"]) <= LOCK_SECONDS


# ---- ログイン ------------------------------------------------------------------------


async def test_login_is_locked_after_max_failures(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    for _ in range(MAX):
        assert (await login(anonymous_client, user.email, "wrong-password")).status_code == 401

    # ロック中は、正しいパスワードでも照合せずに429にする
    locked = await login(anonymous_client, user.email)

    assert_locked(locked)
    assert await count_events(db_session, EVENT_LOGIN_LOCKED) == 1
    # ロック中の拒否は失敗に数えない
    assert await count_events(db_session, EVENT_LOGIN_FAILED) == MAX
    assert await count_events(db_session, EVENT_LOGIN_SUCCEEDED) == 0


async def test_fewer_failures_than_max_do_not_lock(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    await add_events(db_session, EVENT_LOGIN_FAILED, MAX - 1, email=user.email)

    assert (await login(anonymous_client, user.email)).status_code == 200


async def test_unknown_email_is_locked_the_same_way(
    anonymous_client: AsyncClient, db_session: AsyncSession
):
    """存在しないメールアドレスも同じように数え、同じ応答にする(ロックの有無で登録の有無が分からないように)。"""
    await add_events(db_session, EVENT_LOGIN_FAILED, MAX, email="nobody@example.com")

    # メールアドレスは大文字小文字を区別しない
    assert_locked(await login(anonymous_client, "Nobody@Example.com"))
    [event] = await db_session.scalars(
        select(AuditEvent).where(AuditEvent.event_type == EVENT_LOGIN_LOCKED)
    )
    assert (event.email, event.user_id) == ("nobody@example.com", None)


async def test_lock_is_per_email(anonymous_client: AsyncClient, db_session, user_factory):
    user = await user_factory(password=PASSWORD)
    other = await user_factory(password=PASSWORD)
    await add_events(db_session, EVENT_LOGIN_FAILED, MAX, email=other.email)

    assert (await login(anonymous_client, user.email)).status_code == 200
    assert_locked(await login(anonymous_client, other.email))


async def test_lock_expires_after_lock_minutes(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    await add_events(
        db_session, EVENT_LOGIN_FAILED, MAX, email=user.email, minutes_ago=settings.auth_lock_minutes + 1
    )

    assert (await login(anonymous_client, user.email)).status_code == 200


async def test_failures_spread_beyond_the_window_do_not_lock(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    half = MAX // 2
    await add_events(
        db_session,
        EVENT_LOGIN_FAILED,
        MAX - half,
        email=user.email,
        minutes_ago=settings.auth_failure_window_minutes + 5,
    )
    await add_events(db_session, EVENT_LOGIN_FAILED, half, email=user.email)

    assert (await login(anonymous_client, user.email)).status_code == 200


async def test_success_resets_the_count(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    await add_events(db_session, EVENT_LOGIN_FAILED, MAX - 1, email=user.email, minutes_ago=3)
    await add_events(db_session, EVENT_LOGIN_SUCCEEDED, 1, email=user.email, minutes_ago=2)
    await add_events(db_session, EVENT_LOGIN_FAILED, MAX - 1, email=user.email, minutes_ago=1)

    assert (await login(anonymous_client, user.email)).status_code == 200


async def test_failures_on_disabled_account_are_not_counted(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    """停止中のアカウントでの失敗はパスワードが合っていた(推測ではない)ので数えない。"""
    user = await user_factory(password=PASSWORD)
    await add_events(
        db_session, EVENT_LOGIN_FAILED, MAX, email=user.email, reason="account_disabled"
    )

    assert (await login(anonymous_client, user.email)).status_code == 200


# ---- 現在のパスワードによる再確認(パスワードの変更) ------------------------------------


async def test_password_change_is_locked_after_max_failures(
    client_factory, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    client = await client_factory(user)
    for _ in range(MAX):
        assert (await change_password(client, "wrong-password")).status_code == 400

    locked = await change_password(client, PASSWORD)

    assert_locked(locked)
    assert await count_events(db_session, EVENT_PASSWORD_CHANGE_LOCKED) == 1
    assert await count_events(db_session, EVENT_PASSWORD_CHANGE_FAILED) == MAX
    # パスワードは変わっていない。ログインは別に数えるので、ロックされない
    anonymous = await client_factory(None)
    assert (await login(anonymous, user.email)).status_code == 200


async def test_login_lock_does_not_block_password_change(
    client_factory, db_session: AsyncSession, user_factory
):
    """ログインの推測を続けられても、ログイン中の本人はパスワードを変えられる(別に数える)。"""
    user = await user_factory(password=PASSWORD)
    await add_events(db_session, EVENT_LOGIN_FAILED, MAX, email=user.email)
    client = await client_factory(user)

    assert (await change_password(client, PASSWORD)).status_code == 204


async def test_password_change_lock_is_per_user_and_resets_on_success(
    client_factory, db_session: AsyncSession, user_factory
):
    user: User = await user_factory(password=PASSWORD)
    await add_events(db_session, EVENT_PASSWORD_CHANGE_FAILED, MAX - 1, user_id=user.id, minutes_ago=3)
    await add_events(db_session, EVENT_PASSWORD_CHANGED, 1, user_id=user.id, minutes_ago=2)
    await add_events(db_session, EVENT_PASSWORD_CHANGE_FAILED, MAX - 1, user_id=user.id, minutes_ago=1)
    # 他のユーザーの失敗は数えない
    other = await user_factory(password=PASSWORD)
    await add_events(db_session, EVENT_PASSWORD_CHANGE_FAILED, MAX, user_id=other.id)
    client = await client_factory(user)

    assert (await change_password(client, PASSWORD)).status_code == 204
