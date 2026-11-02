"""認証(/api/auth)・自分のアカウント(/api/users/me)と、同期APIの認証のテスト。

仕様はbackend/docs/API設計ドラフト.mdの「認証と権限」「認証のendpoints」。
"""

import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import security
from app.db import set_rls_user
from app.models import AuthSession, TrackingSession, User
from app.services import auth_service

PASSWORD = "correct-horse"


def sessions_url(user_id: uuid.UUID) -> str:
    return f"/api/users/{user_id}/sessions"


def bearer(access_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {access_token}"}


async def login(
    client: AsyncClient, user: User, *, device_id: uuid.UUID | None = None, password: str = PASSWORD
):
    return await client.post(
        "/api/auth/login",
        json={"email": user.email, "password": password, "device_id": str(device_id or uuid.uuid4())},
    )


async def login_tokens(client: AsyncClient, user: User, **kwargs) -> dict:
    response = await login(client, user, **kwargs)
    assert response.status_code == 200, response.text
    return response.json()


async def user_with_password(user_factory, **kwargs) -> User:
    return await user_factory(password=PASSWORD, **kwargs)


# ---- signup ----------------------------------------------------------------------


async def test_signup_creates_unverified_user_and_returns_tokens(anonymous_client: AsyncClient):
    response = await anonymous_client.post(
        "/api/auth/signup",
        json={"email": "Taro@Example.com", "password": PASSWORD, "device_id": str(uuid.uuid4())},
    )

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["token_type"] == "Bearer"
    assert body["expires_in"] == 15 * 60
    assert body["refresh_token"]
    # メールアドレスは小文字で保存し、表示名の既定は@より前
    assert body["user"]["email"] == "taro@example.com"
    assert body["user"]["display_name"] == "taro"
    assert body["user"]["email_verified"] is False

    # ログインはできるが、メールアドレスが未確認なので同期はできない
    headers = bearer(body["access_token"])
    me = await anonymous_client.get("/api/users/me", headers=headers)
    assert me.status_code == 200
    sync = await anonymous_client.get(sessions_url(body["user"]["id"]), headers=headers)
    assert sync.status_code == 403
    assert sync.json()["code"] == "email_not_verified"


async def test_signup_with_registered_email_is_conflict(anonymous_client: AsyncClient, user: User):
    existing = user

    response = await anonymous_client.post(
        "/api/auth/signup",
        # 大文字小文字を区別せずに一意
        json={"email": existing.email.upper(), "password": PASSWORD, "device_id": str(uuid.uuid4())},
    )

    assert response.status_code == 409
    assert response.json()["code"] == "email_already_registered"


async def test_signup_validation(anonymous_client: AsyncClient):
    cases = {
        "body.password": {"email": "a@example.com", "password": "short", "device_id": str(uuid.uuid4())},
        "body.email": {"email": "not-an-email", "password": PASSWORD, "device_id": str(uuid.uuid4())},
        "body.device_id": {"email": "a@example.com", "password": PASSWORD},
    }
    for field, payload in cases.items():
        response = await anonymous_client.post("/api/auth/signup", json=payload)
        assert response.status_code == 422, field
        assert field in [d["field"] for d in response.json()["details"]], field


# ---- login -----------------------------------------------------------------------


async def test_login_returns_tokens_that_work(anonymous_client: AsyncClient, db_session: AsyncSession, user_factory):
    user = await user_with_password(user_factory)

    tokens = await login_tokens(anonymous_client, user)

    me = await anonymous_client.get("/api/users/me", headers=bearer(tokens["access_token"]))
    assert me.status_code == 200
    assert me.json()["id"] == str(user.id)


async def test_login_failures_do_not_reveal_whether_email_exists(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_with_password(user_factory)

    wrong_password = await login(anonymous_client, user, password="wrong-password")
    unknown_email = await anonymous_client.post(
        "/api/auth/login",
        json={"email": "nobody@example.com", "password": PASSWORD, "device_id": str(uuid.uuid4())},
    )

    for response in (wrong_password, unknown_email):
        assert response.status_code == 401
        assert response.json()["code"] == "invalid_credentials"


async def test_disabled_account_cannot_login(anonymous_client: AsyncClient, db_session: AsyncSession, user_factory):
    user = await user_with_password(user_factory)
    await auth_service.set_user_disabled(db_session, user.email, disabled=True)

    response = await login(anonymous_client, user)
    assert response.status_code == 403
    assert response.json()["code"] == "account_disabled"
    # パスワードが違う場合は、停止中かどうかを明かさない
    wrong = await login(anonymous_client, user, password="wrong-password")
    assert wrong.json()["code"] == "invalid_credentials"


async def test_login_again_on_same_device_revokes_previous_login(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_with_password(user_factory)
    device_id = uuid.uuid4()
    first = await login_tokens(anonymous_client, user, device_id=device_id)

    await login_tokens(anonymous_client, user, device_id=device_id)

    response = await anonymous_client.get("/api/users/me", headers=bearer(first["access_token"]))
    assert response.status_code == 401
    assert response.json()["code"] == "unauthenticated"


# ---- refresh ---------------------------------------------------------------------


async def test_refresh_rotates_tokens(anonymous_client: AsyncClient, db_session: AsyncSession, user_factory):
    user = await user_with_password(user_factory)
    tokens = await login_tokens(anonymous_client, user)

    response = await anonymous_client.post(
        "/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )

    assert response.status_code == 200
    refreshed = response.json()
    assert refreshed["refresh_token"] != tokens["refresh_token"]
    me = await anonymous_client.get("/api/users/me", headers=bearer(refreshed["access_token"]))
    assert me.status_code == 200


async def test_reused_refresh_token_revokes_the_device_login(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_with_password(user_factory)
    first = await login_tokens(anonymous_client, user)
    second = (
        await anonymous_client.post("/api/auth/refresh", json={"refresh_token": first["refresh_token"]})
    ).json()

    # 使用済みのリフレッシュトークンを再び使うと、その端末のログイン状態が無効になる
    reused = await anonymous_client.post(
        "/api/auth/refresh", json={"refresh_token": first["refresh_token"]}
    )
    assert reused.status_code == 401
    assert reused.json()["code"] == "invalid_refresh_token"

    # 同じ端末の最新のトークンも使えなくなる(アカウント自体はロックしない)
    latest = await anonymous_client.post(
        "/api/auth/refresh", json={"refresh_token": second["refresh_token"]}
    )
    assert latest.json()["code"] == "invalid_refresh_token"
    me = await anonymous_client.get("/api/users/me", headers=bearer(second["access_token"]))
    assert me.json()["code"] == "unauthenticated"
    assert (await login(anonymous_client, user)).status_code == 200


async def test_unknown_refresh_token_is_rejected(anonymous_client: AsyncClient):
    response = await anonymous_client.post("/api/auth/refresh", json={"refresh_token": "unknown"})

    assert response.status_code == 401
    assert response.json()["code"] == "invalid_refresh_token"


# ---- logout ----------------------------------------------------------------------


async def test_logout_revokes_access_and_refresh_tokens(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_with_password(user_factory)
    tokens = await login_tokens(anonymous_client, user)
    headers = bearer(tokens["access_token"])

    response = await anonymous_client.post("/api/auth/logout", headers=headers)

    assert response.status_code == 204
    # 有効期限内のアクセストークンも、DBで突き合わせるのですぐに使えなくなる
    assert (await anonymous_client.get("/api/users/me", headers=headers)).status_code == 401
    refresh = await anonymous_client.post(
        "/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert refresh.json()["code"] == "invalid_refresh_token"


# ---- アクセストークンの検証 --------------------------------------------------------


async def test_missing_or_invalid_token_is_unauthenticated(
    anonymous_client: AsyncClient, api_client: AsyncClient, user: User
):
    missing = await anonymous_client.get(sessions_url(user.id))
    tampered = await anonymous_client.get(
        sessions_url(user.id),
        headers={"Authorization": api_client.headers["Authorization"][:-2] + "xx"},
    )

    for response in (missing, tampered):
        assert response.status_code == 401
        assert response.json()["code"] == "unauthenticated"


async def test_expired_token_returns_token_expired(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory, user: User
):
    auth_session = AuthSession(user_id=user.id, device_id=uuid.uuid4())
    db_session.add(auth_session)
    await db_session.flush()
    expired = security.create_access_token(
        user.id, auth_session.id, now=datetime.now(UTC) - timedelta(hours=1)
    )

    response = await anonymous_client.get(sessions_url(user.id), headers=bearer(expired))

    assert response.status_code == 401
    assert response.json()["code"] == "token_expired"


async def test_disabling_account_revokes_existing_logins(
    api_client: AsyncClient, db_session: AsyncSession, user: User
):
    assert (await api_client.get("/api/users/me")).status_code == 200

    await auth_service.set_user_disabled(db_session, user.email, disabled=True)
    assert (await api_client.get("/api/users/me")).status_code == 401

    # 停止を解除しても、前のトークンは使えない(ログインし直す)
    await auth_service.set_user_disabled(db_session, user.email, disabled=False)
    assert (await api_client.get("/api/users/me")).status_code == 401


# ---- /users/me --------------------------------------------------------------------


async def test_update_me_changes_display_name(api_client: AsyncClient):
    response = await api_client.patch("/api/users/me", json={"display_name": " たろう "})

    assert response.status_code == 200
    assert response.json()["display_name"] == "たろう"


async def test_update_me_rejects_other_fields(api_client: AsyncClient):
    response = await api_client.patch(
        "/api/users/me", json={"display_name": "たろう", "email": "x@example.com"}
    )

    assert response.status_code == 422
    assert [d["field"] for d in response.json()["details"]] == ["body.email"]


async def test_delete_me_deletes_user_and_related_data(
    api_client: AsyncClient, db_session: AsyncSession, user: User, admin_user: User
):
    register = await api_client.post(
        sessions_url(user.id),
        json={
            "id": str(uuid.uuid4()),
            "name": "削除されるセッション",
            "started_at": "2026-10-01T08:00:00Z",
            "ended_at": "2026-10-01T08:30:00Z",
            "is_favorite": False,
            "move_method": "walk",
            "total_distance": 1.0,
            "duration_seconds": 1800,
            "elevation_gain": 0.0,
            "max_altitude": None,
            "min_altitude": None,
            "track_points": [],
        },
    )
    assert register.status_code == 201

    response = await api_client.delete("/api/users/me")

    assert response.status_code == 204
    assert await db_session.get(User, user.id) is None
    # RLSで他ユーザーの行は見えないので、全ての行が見える管理者として数える
    await set_rls_user(db_session, admin_user.id)
    remaining = await db_session.scalar(
        select(func.count()).select_from(TrackingSession).where(TrackingSession.user_id == user.id)
    )
    assert remaining == 0
    # 他の端末(同じトークン)は次のリクエストで401になる
    assert (await api_client.get("/api/users/me")).status_code == 401


async def test_sync_api_requires_verified_email(client_factory, user_factory):
    unverified = await user_factory(verified=False)
    client = await client_factory(unverified)

    response = await client.get(sessions_url(unverified.id))

    assert response.status_code == 403
    assert response.json()["code"] == "email_not_verified"
