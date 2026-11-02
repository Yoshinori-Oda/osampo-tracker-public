"""エラーが共通の形式({"code", "message", "details"})で返ることの確認。

同期APIのエンドポイントはまだ無いので、テスト用の小さなアプリにinstall_error_handlingを登録して確認する。
存在しないパス・許可されていないメソッドは本物のアプリ(app.main.app)で確認する。
"""

from collections.abc import AsyncIterator

import pytest
from fastapi import Depends, FastAPI, HTTPException
from httpx import ASGITransport, AsyncClient
from pydantic import BaseModel, ConfigDict, Field

from app.dependencies import require_json_content_type
from app.error_handlers import install_error_handling
from app.errors import AppError, ErrorCode
from app.main import app as main_app

# テスト用アプリのbodyのサイズの上限(バイト)
MAX_BODY_BYTES = 100


class Item(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1)


def build_test_app() -> FastAPI:
    test_app = FastAPI()
    install_error_handling(test_app, max_body_bytes=MAX_BODY_BYTES)

    @test_app.get("/app-error")
    async def raise_app_error() -> None:
        raise AppError(404, ErrorCode.SESSION_NOT_FOUND, "セッションが見つかりません")

    @test_app.get("/unexpected-error")
    async def raise_unexpected_error() -> None:
        raise RuntimeError("内部の詳細(レスポンスに出てはいけない)")

    @test_app.get("/unauthenticated")
    async def raise_unauthenticated() -> None:
        raise HTTPException(status_code=401)

    @test_app.post("/items", dependencies=[Depends(require_json_content_type)])
    async def create_item(item: Item) -> dict[str, str]:
        return {"name": item.name}

    return test_app


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    # raise_app_exceptions=False: 想定外の例外でも、テストに例外を投げずに500のレスポンスを受け取る
    transport = ASGITransport(app=build_test_app(), raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as test_client:
        yield test_client


@pytest.fixture
async def main_client() -> AsyncIterator[AsyncClient]:
    async with AsyncClient(transport=ASGITransport(app=main_app), base_url="http://test") as test_client:
        yield test_client


async def test_app_error_is_returned_with_code_and_message(client: AsyncClient):
    response = await client.get("/app-error")

    assert response.status_code == 404
    # detailsは422以外では含めない
    assert response.json() == {"code": "session_not_found", "message": "セッションが見つかりません"}


async def test_unknown_path_returns_not_found(main_client: AsyncClient):
    response = await main_client.get("/no-such-path")

    assert response.status_code == 404
    assert response.json()["code"] == "not_found"


async def test_method_not_allowed_keeps_allow_header(main_client: AsyncClient):
    response = await main_client.post("/health")

    assert response.status_code == 405
    assert response.json()["code"] == "method_not_allowed"
    assert "GET" in response.headers["allow"]


async def test_http_exception_401_returns_unauthenticated(client: AsyncClient):
    response = await client.get("/unauthenticated")

    assert response.status_code == 401
    assert response.json()["code"] == "unauthenticated"


async def test_validation_error_returns_details(client: AsyncClient):
    response = await client.post("/items", json={"name": ""})

    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "validation_error"
    assert [detail["field"] for detail in body["details"]] == ["body.name"]
    assert body["details"][0]["reason"]


async def test_unknown_field_is_validation_error(client: AsyncClient):
    # extra="forbid"のモデルに知らない項目を送ると422になる(PATCHで不変の項目を拒否するのに使う)
    response = await client.post("/items", json={"name": "a", "started_at": "2026-10-01T00:00:00Z"})

    assert response.status_code == 422
    assert [detail["field"] for detail in response.json()["details"]] == ["body.started_at"]


async def test_non_json_content_type_returns_unsupported_media_type(client: AsyncClient):
    response = await client.post(
        "/items", content="name=a", headers={"Content-Type": "text/plain"}
    )

    assert response.status_code == 415
    assert response.json()["code"] == "unsupported_media_type"


async def test_json_content_type_with_charset_is_accepted(client: AsyncClient):
    response = await client.post(
        "/items",
        content='{"name": "a"}',
        headers={"Content-Type": "application/json; charset=utf-8"},
    )

    assert response.status_code == 200


async def test_body_over_limit_by_content_length_returns_payload_too_large(client: AsyncClient):
    response = await client.post("/items", json={"name": "a" * MAX_BODY_BYTES})

    assert response.status_code == 413
    assert response.json()["code"] == "payload_too_large"


async def test_chunked_body_over_limit_returns_payload_too_large(client: AsyncClient):
    # Content-Lengthの無い(chunked)bodyでも、読み込んだ量が上限を超えた時点で413にする
    async def chunks() -> AsyncIterator[bytes]:
        yield b'{"name": "'
        for _ in range(MAX_BODY_BYTES):
            yield b"a"
        yield b'"}'

    response = await client.post(
        "/items", content=chunks(), headers={"Content-Type": "application/json"}
    )

    assert "content-length" not in response.request.headers
    assert response.status_code == 413
    assert response.json()["code"] == "payload_too_large"


async def test_unexpected_error_returns_internal_error_without_details(client: AsyncClient):
    response = await client.get("/unexpected-error")

    assert response.status_code == 500
    body = response.json()
    assert body["code"] == "internal_error"
    assert "内部の詳細" not in response.text
    assert "details" not in body
