"""ログ(リクエストID・アクセスログ・アプリのログ・整形)のテスト。設計はbackend/docs/バックエンド構成.mdの「ログ」。"""

import json
import logging
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import request_context
from app.db import set_rls_user
from app.error_handlers import install_error_handling
from app.logging_config import JsonFormatter, TextFormatter
from app.models import AuditEvent, TrackingSession, User
from app.models.audit_event import EVENT_LOGIN_SUCCEEDED

PASSWORD = "correct-horse"


def access_records(caplog: pytest.LogCaptureFixture) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.name == "app.access"]


@pytest.fixture(autouse=True)
def capture_info(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO)


async def add_session(db: AsyncSession, user: User) -> TrackingSession:
    started_at = datetime(2026, 6, 1, 8, 0, tzinfo=UTC)
    tracking_session = TrackingSession(
        user_id=user.id,
        name="テスト",
        started_at=started_at,
        ended_at=started_at + timedelta(minutes=30),
        move_method="walk",
    )
    db.add(tracking_session)
    await db.flush()
    return tracking_session


# ---- リクエストID ------------------------------------------------------------------


async def test_request_id_is_generated_and_returned(anonymous_client: AsyncClient):
    response = await anonymous_client.get("/health")

    uuid.UUID(response.headers["X-Request-ID"])


async def test_request_id_from_client_is_used(anonymous_client: AsyncClient, caplog):
    request_id = str(uuid.uuid4())

    response = await anonymous_client.get("/health", headers={"X-Request-ID": request_id})

    assert response.headers["X-Request-ID"] == request_id
    assert access_records(caplog)[-1].request_id == request_id


async def test_invalid_request_id_from_client_is_replaced(anonymous_client: AsyncClient):
    """任意の文字列をログに書き込ませないよう、形式に合わないものは使わずにサーバーで作る。"""
    response = await anonymous_client.get("/health", headers={"X-Request-ID": "bad id\nINFO forged"})

    assert response.headers["X-Request-ID"] != "bad id\nINFO forged"
    uuid.UUID(response.headers["X-Request-ID"])


# ---- アクセスログ --------------------------------------------------------------------


async def test_access_log_has_path_template_status_and_user(
    api_client: AsyncClient, user: User, caplog
):
    response = await api_client.get(f"/api/users/{user.id}/sessions")
    assert response.status_code == 200

    [record] = access_records(caplog)
    assert record.method == "GET"
    # パスにはuser_idが入るので、実際のパスではなく型を残す
    assert record.path == "/api/users/{user_id}/sessions"
    assert record.status == 200
    assert record.user_id == user.id
    assert record.request_id == response.headers["X-Request-ID"]
    assert record.code is None
    assert record.duration_ms >= 0
    assert record.ip == "127.0.0.1"


async def test_access_log_has_error_code(anonymous_client: AsyncClient, caplog):
    assert (await anonymous_client.get("/api/users/me")).status_code == 401
    assert (await anonymous_client.get("/no-such-path")).status_code == 404

    unauthenticated, not_found = access_records(caplog)
    assert (unauthenticated.status, unauthenticated.code, unauthenticated.user_id) == (
        401,
        "unauthenticated",
        None,
    )
    # どのルートにも当たらないパスは、探られたパスが分かるよう実際のパスを残す
    assert (not_found.path, not_found.status, not_found.code) == ("/no-such-path", 404, "not_found")


async def test_access_log_has_user_after_login(
    anonymous_client: AsyncClient, user_factory, caplog
):
    user = await user_factory(password=PASSWORD)
    response = await anonymous_client.post(
        "/api/auth/login",
        json={"email": user.email, "password": PASSWORD, "device_id": str(uuid.uuid4())},
    )
    assert response.status_code == 200

    [record] = access_records(caplog)
    assert (record.path, record.user_id) == ("/api/auth/login", user.id)


async def test_unexpected_error_is_logged_with_request_id(caplog):
    """500のスタックトレースはリクエストIDを付けてログに出し、レスポンスにもリクエストIDを付ける。"""
    test_app = FastAPI()
    install_error_handling(test_app, max_body_bytes=100)
    test_app.add_middleware(request_context.RequestContextMiddleware)

    @test_app.get("/boom")
    async def boom() -> None:
        raise RuntimeError("boom")

    transport = ASGITransport(app=test_app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/boom")

    assert response.status_code == 500
    request_id = response.headers["X-Request-ID"]
    [error] = [r for r in caplog.records if r.name == "app.errors"]
    assert error.levelno == logging.ERROR
    assert error.exc_info is not None
    # ログを出した時点はリクエストの中なので、リクエストIDが付く
    assert error.request_id == request_id
    [access] = access_records(caplog)
    assert (access.status, access.code, access.path, access.request_id) == (
        500,
        "internal_error",
        "/boom",
        request_id,
    )


# ---- アプリのログ: 404の理由 -----------------------------------------------------------


def not_found_reasons(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [r.reason for r in caplog.records if r.getMessage() == "session not found"]


async def test_delete_not_found_reason_is_logged(
    api_client: AsyncClient, db_session: AsyncSession, user: User, other_user: User, caplog
):
    """404の理由は、RLSで他ユーザーの行が見えないので、無い・他ユーザーのものを区別しない。"""
    await set_rls_user(db_session, other_user.id)
    others = await add_session(db_session, other_user)

    missing = await api_client.delete(f"/api/users/{user.id}/sessions/{uuid.uuid4()}")
    not_mine = await api_client.delete(f"/api/users/{user.id}/sessions/{others.id}")

    assert [missing.json()["code"], not_mine.json()["code"]] == ["session_not_found"] * 2
    assert not_found_reasons(caplog) == ["not_found_or_not_visible"] * 2
    # 他ユーザーのuser_idはログに出さない
    assert all(str(other_user.id) not in r.getMessage() for r in caplog.records)
    assert all(getattr(r, "user_id", None) != other_user.id for r in caplog.records)


# ---- 監査ログのリクエストID ------------------------------------------------------------


async def test_audit_event_has_request_id(
    anonymous_client: AsyncClient, db_session: AsyncSession, user_factory
):
    user = await user_factory(password=PASSWORD)
    response = await anonymous_client.post(
        "/api/auth/login",
        json={"email": user.email, "password": PASSWORD, "device_id": str(uuid.uuid4())},
    )

    event = await db_session.scalar(
        select(AuditEvent).where(AuditEvent.event_type == EVENT_LOGIN_SUCCEEDED)
    )
    assert event.request_id == response.headers["X-Request-ID"]


# ---- 整形 ---------------------------------------------------------------------------


def make_record(message: str = "purged", **extra) -> logging.LogRecord:
    record = logging.LogRecord("app.worker", logging.INFO, __file__, 1, message, None, None)
    for key, value in extra.items():
        setattr(record, key, value)
    return record


def test_text_format_is_key_value():
    record = make_record(tombstones=3, reason="has space", empty=None)

    line = TextFormatter().format(record)

    # 時刻 レベル ロガー名 メッセージ key=value(Noneの項目は省き、空白を含む値は引用符で囲む)
    timestamp, rest = line.split(" ", 1)
    assert timestamp.endswith("Z")
    assert rest == 'INFO app.worker purged tombstones=3 reason="has space"'


def test_json_format_is_one_json_per_line():
    record = make_record(tombstones=3, session_id=uuid.UUID(int=1))

    line = JsonFormatter().format(record)

    assert "\n" not in line
    payload = json.loads(line)
    assert payload["level"] == "INFO"
    assert payload["logger"] == "app.worker"
    assert payload["message"] == "purged"
    assert payload["tombstones"] == 3
    assert payload["session_id"] == str(uuid.UUID(int=1))


def test_logs_in_a_request_get_request_id_and_user_id_first():
    user_id = uuid.uuid4()
    context = request_context.RequestContext(request_id="req-12345678", ip=None, user_id=user_id)
    token = request_context._current.set(context)
    try:
        record = logging.getLogger("app.worker").makeRecord(
            "app.worker", logging.INFO, __file__, 1, "purged", None, None, extra={"tombstones": 3}
        )
    finally:
        request_context._current.reset(token)

    line = TextFormatter().format(record)
    assert line.endswith(f"purged request_id=req-12345678 user_id={user_id} tombstones=3")
