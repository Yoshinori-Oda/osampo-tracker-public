"""メールアドレスの確認コード(/api/users/me/email-verification)のテスト。

仕様はbackend/docs/API設計ドラフト.mdの「メールアドレスの確認のendpoints」、設計はbackend/docs/バックエンド構成.mdの
「メールアドレスの確認コード」。メールはoutboxに積まれるだけで、SMTPには接続しない。
"""

import uuid
from collections.abc import Iterator
from datetime import timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import security
from app.models import EmailCode, OutboxEmail, User
from app.models.email_code import CODE_LOCKED, CODE_PENDING, CODE_USED, PURPOSE_VERIFY_EMAIL
from app.models.outbox_email import OUTBOX_CANCELLED, OUTBOX_PENDING
from app.services.session_service import current_time

SEND_URL = "/api/users/me/email-verification"
CONFIRM_URL = "/api/users/me/email-verification/confirm"


@pytest.fixture
def codes(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """確認コードを111111、222222、…の順に作るようにする(偶然の一致でテストが不安定にならないように)。"""
    sequence = (str(n) * 6 for n in range(1, 10))
    monkeypatch.setattr(security, "new_verification_code", lambda: next(sequence))
    yield


async def code_row(db: AsyncSession, user_id: uuid.UUID) -> EmailCode:
    row = await db.get(EmailCode, (user_id, PURPOSE_VERIFY_EMAIL))
    assert row is not None
    return row


async def pending_emails(db: AsyncSession, user_id: uuid.UUID) -> list[OutboxEmail]:
    return list(
        await db.scalars(
            select(OutboxEmail).where(
                OutboxEmail.recipient_user_id == user_id, OutboxEmail.status == OUTBOX_PENDING
            )
        )
    )


async def unverified(user_factory, client_factory) -> tuple[User, AsyncClient]:
    user = await user_factory(verified=False)
    return user, await client_factory(user)


async def allow_resend(db: AsyncSession, user_id: uuid.UUID) -> None:
    """再送の間隔(60秒)が過ぎたことにする。"""
    row = await code_row(db, user_id)
    row.issued_at -= timedelta(seconds=61)
    await db.flush()


async def confirm(client: AsyncClient, code: str):
    return await client.post(CONFIRM_URL, json={"code": code})


# ---- サインアップ時の送信 ---------------------------------------------------------------


async def test_signup_sends_verification_code(
    anonymous_client: AsyncClient, db_session: AsyncSession, codes
):
    response = await anonymous_client.post(
        "/api/auth/signup",
        json={"email": "taro@example.com", "password": "correct-horse", "device_id": str(uuid.uuid4())},
    )
    assert response.status_code == 201, response.text
    user_id = uuid.UUID(response.json()["user"]["id"])

    row = await code_row(db_session, user_id)
    assert row.status == CODE_PENDING
    assert (row.send_count, row.failed_attempts) == (1, 0)
    # コードそのものは保存しない
    assert row.code_hash and "111111" not in row.code_hash
    [email] = await pending_emails(db_session, user_id)
    assert row.outbox_email_id == email.id
    assert email.to_address == "taro@example.com"
    assert "確認コード: 111111" in email.body
    # 送信が遅れてコードの有効期限を過ぎたら送らない
    assert email.send_deadline == row.expires_at


async def test_confirm_after_signup_enables_sync(
    anonymous_client: AsyncClient, db_session: AsyncSession, codes
):
    signup = await anonymous_client.post(
        "/api/auth/signup",
        json={"email": "hanako@example.com", "password": "correct-horse", "device_id": str(uuid.uuid4())},
    )
    body = signup.json()
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    sessions_url = f"/api/users/{body['user']['id']}/sessions"
    assert (await anonymous_client.get(sessions_url, headers=headers)).status_code == 403

    response = await anonymous_client.post(CONFIRM_URL, json={"code": "111111"}, headers=headers)

    assert response.status_code == 200, response.text
    assert response.json()["email_verified"] is True
    assert (await anonymous_client.get(sessions_url, headers=headers)).status_code == 200
    row = await code_row(db_session, uuid.UUID(body["user"]["id"]))
    assert row.status == CODE_USED
    assert row.code_hash is None


# ---- 送信・再送 -----------------------------------------------------------------------


async def test_send_creates_code_for_user_without_one(user_factory, client_factory, db_session, codes):
    # サインアップ以外で作られたユーザー(この機能より前のユーザー・seed-devの未確認ユーザー等)には行が無い
    user, client = await unverified(user_factory, client_factory)

    response = await client.post(SEND_URL)

    assert response.status_code == 202, response.text
    assert response.json() == {"expires_in": 600, "resend_available_in": 60}
    row = await code_row(db_session, user.id)
    assert (row.status, row.send_count) == (CODE_PENDING, 1)


async def test_resend_within_interval_is_rate_limited(user_factory, client_factory, codes):
    _, client = await unverified(user_factory, client_factory)
    assert (await client.post(SEND_URL)).status_code == 202

    response = await client.post(SEND_URL)

    assert response.status_code == 429
    assert response.json()["code"] == "too_many_requests"
    assert 1 <= int(response.headers["retry-after"]) <= 60


async def test_resend_replaces_code_and_cancels_unsent_mail(
    user_factory, client_factory, db_session: AsyncSession, codes
):
    user, client = await unverified(user_factory, client_factory)
    await client.post(SEND_URL)
    [old_email] = await pending_emails(db_session, user.id)
    await allow_resend(db_session, user.id)

    assert (await client.post(SEND_URL)).status_code == 202

    # 古いコードのメールはまだ送られていなかったので取り消す
    assert old_email.status == OUTBOX_CANCELLED
    [new_email] = await pending_emails(db_session, user.id)
    assert "確認コード: 222222" in new_email.body
    assert (await code_row(db_session, user.id)).send_count == 2
    # 古いコードは使えない
    assert (await confirm(client, "111111")).json()["code"] == "invalid_verification_code"
    assert (await confirm(client, "222222")).status_code == 200


async def test_daily_send_limit(user_factory, client_factory, db_session: AsyncSession, codes):
    user, client = await unverified(user_factory, client_factory)
    await client.post(SEND_URL)
    row = await code_row(db_session, user.id)
    now = await current_time(db_session)
    # 1時間前から数えて5回送った(最後の送信から60秒以上経っている)
    row.send_count = 5
    row.send_window_started_at = now - timedelta(hours=1)
    row.issued_at = now - timedelta(minutes=2)
    await db_session.flush()

    limited = await client.post(SEND_URL)

    assert limited.status_code == 429
    # 数え始めから24時間経つまで(約23時間)待つ
    retry_after = int(limited.headers["retry-after"])
    assert timedelta(hours=22, minutes=59) <= timedelta(seconds=retry_after) <= timedelta(hours=23)

    # 数え始めから24時間経つと数え直す
    row.send_window_started_at = now - timedelta(hours=24, seconds=1)
    await db_session.flush()
    assert (await client.post(SEND_URL)).status_code == 202
    assert row.send_count == 1


async def test_resend_available_in_reflects_daily_limit(
    user_factory, client_factory, db_session: AsyncSession, codes
):
    user, client = await unverified(user_factory, client_factory)
    await client.post(SEND_URL)
    row = await code_row(db_session, user.id)
    row.send_count = 4
    await db_session.flush()
    await allow_resend(db_session, user.id)

    # 5回目を送ったら、次に送れるのは数え始めから24時間後
    response = await client.post(SEND_URL)

    assert response.status_code == 202
    assert response.json()["resend_available_in"] > 23 * 60 * 60


# ---- 確認 -----------------------------------------------------------------------------


async def test_wrong_code_locks_after_max_attempts(
    user_factory, client_factory, db_session: AsyncSession, codes
):
    user, client = await unverified(user_factory, client_factory)
    await client.post(SEND_URL)

    for _ in range(5):
        response = await confirm(client, "999999")
        assert response.status_code == 400
        assert response.json()["code"] == "invalid_verification_code"

    row = await code_row(db_session, user.id)
    assert row.status == CODE_LOCKED
    assert row.code_hash is None
    # 上限に達した後は、正しいコードでも使えない
    assert (await confirm(client, "111111")).json()["code"] == "verification_code_expired"

    # 再送すれば新しいコードで確認できる(失敗の回数も0に戻る)
    await allow_resend(db_session, user.id)
    assert (await client.post(SEND_URL)).status_code == 202
    assert row.failed_attempts == 0
    assert (await confirm(client, "222222")).status_code == 200


async def test_expired_code_is_rejected(user_factory, client_factory, db_session: AsyncSession, codes):
    user, client = await unverified(user_factory, client_factory)
    await client.post(SEND_URL)
    row = await code_row(db_session, user.id)
    row.expires_at = await current_time(db_session) - timedelta(seconds=1)
    await db_session.flush()

    response = await confirm(client, "111111")

    assert response.status_code == 400
    assert response.json()["code"] == "verification_code_expired"


async def test_confirm_without_code_is_expired(user_factory, client_factory):
    _, client = await unverified(user_factory, client_factory)

    response = await confirm(client, "111111")

    assert response.status_code == 400
    assert response.json()["code"] == "verification_code_expired"


async def test_confirm_rejects_malformed_code_without_counting(
    user_factory, client_factory, db_session: AsyncSession, codes
):
    user, client = await unverified(user_factory, client_factory)
    await client.post(SEND_URL)

    for code in ("12345", "1234567", "abcdef", 111111):
        response = await client.post(CONFIRM_URL, json={"code": code})
        assert response.status_code == 422, code
        assert [d["field"] for d in response.json()["details"]] == ["body.code"]

    # 形式が違うものは照合しないので、失敗の回数に数えない
    assert (await code_row(db_session, user.id)).failed_attempts == 0


async def test_already_verified_user(api_client: AsyncClient):
    # 確認済みなら送らない
    sent = await api_client.post(SEND_URL)
    assert sent.status_code == 409
    assert sent.json()["code"] == "email_already_verified"

    # 確認はコードに関係なく200(成功したのにレスポンスが届かず再送された場合のため)
    confirmed = await confirm(api_client, "000000")
    assert confirmed.status_code == 200
    assert confirmed.json()["email_verified"] is True


async def test_deleting_user_deletes_code(user_factory, client_factory, db_session: AsyncSession, codes):
    user, client = await unverified(user_factory, client_factory)
    await client.post(SEND_URL)

    await db_session.delete(user)
    await db_session.flush()

    remaining = await db_session.scalar(
        select(EmailCode.user_id).where(EmailCode.user_id == user.id).limit(1)
    )
    assert remaining is None
