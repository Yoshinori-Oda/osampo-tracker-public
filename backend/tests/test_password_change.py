"""パスワードの変更(PUT /api/users/me/password)のテスト。

仕様はbackend/docs/API設計ドラフト.mdの「認証のendpoints」。
"""

import uuid

from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import OutboxEmail, User
from app.models.outbox_email import OUTBOX_PENDING
from app.services.auth_service import PASSWORD_CHANGED_SUBJECT

PASSWORD = "correct-horse"
NEW_PASSWORD = "battery-staple"
URL = "/api/users/me/password"


async def login(client: AsyncClient, user: User, password: str = PASSWORD):
    return await client.post(
        "/api/auth/login",
        json={"email": user.email, "password": password, "device_id": str(uuid.uuid4())},
    )


async def login_headers(client: AsyncClient, user: User) -> dict[str, str]:
    response = await login(client, user)
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


async def test_change_password(anonymous_client: AsyncClient, user_factory, db_session: AsyncSession):
    user = await user_factory(password=PASSWORD)
    this_device = await login_headers(anonymous_client, user)
    other_device = await login_headers(anonymous_client, user)

    response = await anonymous_client.put(
        URL,
        json={"current_password": PASSWORD, "new_password": NEW_PASSWORD},
        headers=this_device,
    )

    assert response.status_code == 204, response.text
    # 新しいパスワードでだけログインできる
    assert (await login(anonymous_client, user, NEW_PASSWORD)).status_code == 200
    assert (await login(anonymous_client, user, PASSWORD)).status_code == 401
    # 変えた端末はログインしたまま、他の端末のログイン状態は無効になる
    assert (await anonymous_client.get("/api/users/me", headers=this_device)).status_code == 200
    other = await anonymous_client.get("/api/users/me", headers=other_device)
    assert other.status_code == 401
    assert other.json()["code"] == "unauthenticated"
    # 変更を知らせるメールを本人に送る
    [email] = await db_session.scalars(
        select(OutboxEmail).where(
            OutboxEmail.recipient_user_id == user.id, OutboxEmail.status == OUTBOX_PENDING
        )
    )
    assert email.subject == PASSWORD_CHANGED_SUBJECT
    assert email.to_address == user.email


async def test_same_password_is_accepted(anonymous_client: AsyncClient, user_factory):
    user = await user_factory(password=PASSWORD)
    headers = await login_headers(anonymous_client, user)

    response = await anonymous_client.put(
        URL, json={"current_password": PASSWORD, "new_password": PASSWORD}, headers=headers
    )

    assert response.status_code == 204


async def test_wrong_current_password_is_400_and_changes_nothing(
    anonymous_client: AsyncClient, user_factory, db_session: AsyncSession
):
    user = await user_factory(password=PASSWORD)
    this_device = await login_headers(anonymous_client, user)
    other_device = await login_headers(anonymous_client, user)

    response = await anonymous_client.put(
        URL,
        json={"current_password": "wrong-password", "new_password": NEW_PASSWORD},
        headers=this_device,
    )

    # 401にしない(クライアントがログイン状態の無効と区別できなくなるため)
    assert response.status_code == 400
    assert response.json()["code"] == "invalid_current_password"
    assert (await login(anonymous_client, user, PASSWORD)).status_code == 200
    assert (await anonymous_client.get("/api/users/me", headers=other_device)).status_code == 200
    emails = await db_session.scalars(
        select(OutboxEmail).where(OutboxEmail.subject == PASSWORD_CHANGED_SUBJECT)
    )
    assert list(emails) == []


async def test_change_password_validation(anonymous_client: AsyncClient, user_factory):
    user = await user_factory(password=PASSWORD)
    headers = await login_headers(anonymous_client, user)

    cases = {
        "body.new_password": {"current_password": PASSWORD, "new_password": "short"},
        "body.current_password": {"new_password": NEW_PASSWORD},
        "body.extra": {"current_password": PASSWORD, "new_password": NEW_PASSWORD, "extra": 1},
    }
    for field, body in cases.items():
        response = await anonymous_client.put(URL, json=body, headers=headers)
        assert response.status_code == 422, field
        assert [d["field"] for d in response.json()["details"]] == [field]


async def test_change_password_requires_login(anonymous_client: AsyncClient):
    response = await anonymous_client.put(
        URL, json={"current_password": PASSWORD, "new_password": NEW_PASSWORD}
    )

    assert response.status_code == 401
    assert response.json()["code"] == "unauthenticated"
