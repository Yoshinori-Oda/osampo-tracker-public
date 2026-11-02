"""監査ログ(audit_events)のテスト。どの操作で何を残すか(と、残さないもの)を確かめる。

設計はbackend/docs/バックエンド構成.mdの「監査ログ」。
"""

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import security
from app.models import AuditEvent, User
from app.models.audit_event import (
    EVENT_ACCESS_DENIED,
    EVENT_ACCOUNT_DELETED,
    EVENT_ACCOUNT_DISABLED,
    EVENT_ACCOUNT_ENABLED,
    EVENT_ADMIN_USER_ACCESS,
    EVENT_EMAIL_VERIFIED,
    EVENT_LOGIN_FAILED,
    EVENT_LOGIN_SUCCEEDED,
    EVENT_LOGOUT,
    EVENT_PASSWORD_CHANGE_FAILED,
    EVENT_PASSWORD_CHANGED,
    EVENT_REFRESH_TOKEN_REUSED,
    EVENT_SIGNUP,
)
from app.services import auth_service

PASSWORD = "correct-horse"
# テストのクライアント(httpxのASGITransport)の送信元
CLIENT_IP = "127.0.0.1"


async def events(db: AsyncSession, **filters) -> list[AuditEvent]:
    query = select(AuditEvent).order_by(AuditEvent.id)
    for name, value in filters.items():
        query = query.where(getattr(AuditEvent, name) == value)
    return list(await db.scalars(query))


async def login(client: AsyncClient, email: str, password: str = PASSWORD, device_id=None):
    return await client.post(
        "/api/auth/login",
        json={"email": email, "password": password, "device_id": str(device_id or uuid.uuid4())},
    )


def bearer(access_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {access_token}"}


# ---- 認証 --------------------------------------------------------------------------


async def test_signup_is_recorded(anonymous_client: AsyncClient, db_session: AsyncSession):
    device_id = uuid.uuid4()
    response = await anonymous_client.post(
        "/api/auth/signup",
        json={"email": "New.User@Example.com", "password": PASSWORD, "device_id": str(device_id)},
    )
    assert response.status_code == 201, response.text

    [event] = await events(db_session, event_type=EVENT_SIGNUP)
    assert event.user_id == uuid.UUID(response.json()["user"]["id"])
    assert event.email == "new.user@example.com"
    assert event.device_id == device_id
    assert str(event.ip) == CLIENT_IP
    assert event.occurred_at is not None


async def test_login_success_is_recorded(anonymous_client: AsyncClient, db_session, user_factory):
    user = await user_factory(password=PASSWORD)
    device_id = uuid.uuid4()

    assert (await login(anonymous_client, user.email.upper(), device_id=device_id)).status_code == 200

    [event] = await events(db_session, event_type=EVENT_LOGIN_SUCCEEDED)
    assert (event.user_id, event.email, event.device_id) == (user.id, user.email, device_id)
    assert str(event.ip) == CLIENT_IP


async def test_login_failures_are_recorded_with_reason(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    disabled = await user_factory(password=PASSWORD)
    await auth_service.set_user_disabled(db_session, disabled.email, disabled=True)

    assert (await login(anonymous_client, user.email, "wrong-password")).status_code == 401
    assert (await login(anonymous_client, "Nobody@Example.com")).status_code == 401
    assert (await login(anonymous_client, disabled.email)).status_code == 403

    failed = await events(db_session, event_type=EVENT_LOGIN_FAILED)
    assert [(e.user_id, e.email, e.reason) for e in failed] == [
        (user.id, user.email, "invalid_credentials"),
        # 存在しないメールアドレスも、入力されたアドレス(小文字にそろえる)で残す
        (None, "nobody@example.com", "invalid_credentials"),
        (disabled.id, disabled.email, "account_disabled"),
    ]
    assert await events(db_session, event_type=EVENT_LOGIN_SUCCEEDED) == []


async def test_logout_is_recorded(anonymous_client: AsyncClient, db_session, user_factory):
    user = await user_factory(password=PASSWORD)
    device_id = uuid.uuid4()
    tokens = (await login(anonymous_client, user.email, device_id=device_id)).json()

    response = await anonymous_client.post(
        "/api/auth/logout", headers=bearer(tokens["access_token"])
    )
    assert response.status_code == 204

    [event] = await events(db_session, event_type=EVENT_LOGOUT)
    assert (event.user_id, event.device_id) == (user.id, device_id)


async def test_reused_refresh_token_is_recorded(
    anonymous_client: AsyncClient, db_session, user_factory
):
    user = await user_factory(password=PASSWORD)
    device_id = uuid.uuid4()
    tokens = (await login(anonymous_client, user.email, device_id=device_id)).json()
    body = {"refresh_token": tokens["refresh_token"]}
    assert (await anonymous_client.post("/api/auth/refresh", json=body)).status_code == 200

    # 2回目は使用済みのトークン。2回とも記録する(既にログイン状態が無効になっていても)
    assert (await anonymous_client.post("/api/auth/refresh", json=body)).status_code == 401
    assert (await anonymous_client.post("/api/auth/refresh", json=body)).status_code == 401

    reused = await events(db_session, event_type=EVENT_REFRESH_TOKEN_REUSED)
    assert [(e.user_id, e.device_id) for e in reused] == [(user.id, device_id)] * 2


# ---- アカウント ----------------------------------------------------------------------


async def test_password_change_success_and_failure_are_recorded(
    anonymous_client: AsyncClient, db_session, user_factory
):
    user = await user_factory(password=PASSWORD)
    device_id = uuid.uuid4()
    headers = bearer((await login(anonymous_client, user.email, device_id=device_id)).json()["access_token"])

    wrong = await anonymous_client.put(
        "/api/users/me/password",
        json={"current_password": "wrong-password", "new_password": "battery-staple"},
        headers=headers,
    )
    assert wrong.status_code == 400
    ok = await anonymous_client.put(
        "/api/users/me/password",
        json={"current_password": PASSWORD, "new_password": "battery-staple"},
        headers=headers,
    )
    assert ok.status_code == 204

    recorded = await events(db_session, user_id=user.id)
    assert [e.event_type for e in recorded] == [
        EVENT_LOGIN_SUCCEEDED,
        EVENT_PASSWORD_CHANGE_FAILED,
        EVENT_PASSWORD_CHANGED,
    ]
    assert {e.device_id for e in recorded} == {device_id}


async def test_email_verification_is_recorded(
    client_factory, user_factory, db_session: AsyncSession, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr(security, "new_verification_code", lambda: "123456")
    user = await user_factory(verified=False)
    client = await client_factory(user)
    assert (await client.post("/api/users/me/email-verification")).status_code == 202

    response = await client.post(
        "/api/users/me/email-verification/confirm", json={"code": "123456"}
    )
    assert response.status_code == 200, response.text

    [event] = await events(db_session, event_type=EVENT_EMAIL_VERIFIED)
    assert (event.user_id, event.email) == (user.id, user.email)
    assert event.device_id is not None


async def test_account_deletion_keeps_only_the_deletion_record(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    other = await user_factory(password=PASSWORD)
    headers = bearer((await login(anonymous_client, user.email)).json()["access_token"])
    assert (await login(anonymous_client, other.email)).status_code == 200

    assert (await anonymous_client.delete("/api/users/me", headers=headers)).status_code == 204

    # 削除したユーザーの記録は消え、削除の記録(日時とuser_idだけ)が残る。他のユーザーの記録はそのまま
    [deleted] = await events(db_session, user_id=user.id)
    assert deleted.event_type == EVENT_ACCOUNT_DELETED
    assert (deleted.email, deleted.ip, deleted.device_id) == (None, None, None)
    assert deleted.occurred_at is not None
    assert [e.event_type for e in await events(db_session, user_id=other.id)] == [
        EVENT_LOGIN_SUCCEEDED
    ]


async def test_disabling_and_enabling_account_are_recorded(db_session: AsyncSession, user: User):
    await auth_service.set_user_disabled(db_session, user.email, disabled=True)
    await auth_service.set_user_disabled(db_session, user.email, disabled=False)

    recorded = await events(db_session, user_id=user.id)
    assert [e.event_type for e in recorded] == [EVENT_ACCOUNT_DISABLED, EVENT_ACCOUNT_ENABLED]
    # 管理用のコマンドからの操作なので、送信元は無い
    assert {e.ip for e in recorded} == {None}


# ---- 権限 --------------------------------------------------------------------------


async def test_access_to_other_users_data_is_recorded(
    api_client: AsyncClient, db_session: AsyncSession, user: User, other_user: User
):
    response = await api_client.get(f"/api/users/{other_user.id}/sessions")
    assert response.status_code == 403
    assert response.json()["code"] == "forbidden"

    [event] = await events(db_session, event_type=EVENT_ACCESS_DENIED)
    assert (event.user_id, event.target_user_id) == (user.id, other_user.id)
    assert event.device_id is not None


async def test_normal_failures_are_not_recorded(
    client_factory, user_factory, db_session: AsyncSession
):
    """正常な流れでも起きる失敗(メールアドレスが未確認の403・トークンが無い401)は残さない(アクセスログの役割)。"""
    unverified = await user_factory(verified=False)
    client = await client_factory(unverified)
    assert (await client.get(f"/api/users/{unverified.id}/sessions")).status_code == 403
    anonymous = await client_factory(None)
    assert (await anonymous.get("/api/users/me")).status_code == 401

    assert await events(db_session) == []


async def test_admin_access_to_other_users_data_is_recorded(
    client_factory, admin_user: User, user: User, db_session: AsyncSession
):
    admin_client = await client_factory(admin_user)

    assert (await admin_client.get(f"/api/users/{user.id}/sessions")).status_code == 200
    # 自分のデータへのアクセスは残さない
    assert (await admin_client.get(f"/api/users/{admin_user.id}/sessions")).status_code == 200

    [event] = await events(db_session, event_type=EVENT_ADMIN_USER_ACCESS)
    assert (event.user_id, event.target_user_id) == (admin_user.id, user.id)
    assert await events(db_session, event_type=EVENT_ACCESS_DENIED) == []
