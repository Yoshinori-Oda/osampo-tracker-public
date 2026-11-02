"""OpenAPI(実装から自動生成されるAPI仕様)の内容の確認。DBには接続しない。"""

from typing import Any

import pytest

from app.main import app

SESSIONS = "/api/users/{user_id}/sessions"
SESSION = f"{SESSIONS}/{{session_id}}"

# (パス, メソッド) → operationId(関数名)
OPERATIONS = {
    (SESSIONS, "get"): "fetch_sessions",
    (SESSIONS, "post"): "register_session",
    (f"{SESSIONS}/existence-check", "post"): "check_existence",
    (SESSION, "patch"): "edit_session",
    (SESSION, "delete"): "delete_session",
    (f"{SESSION}/restore", "post"): "restore_session",
}


@pytest.fixture(scope="module")
def openapi() -> dict[str, Any]:
    return app.openapi()


def operation(openapi: dict[str, Any], path: str, method: str) -> dict[str, Any]:
    return openapi["paths"][path][method]


def test_operation_ids_are_function_names(openapi: dict[str, Any]):
    for (path, method), operation_id in OPERATIONS.items():
        assert operation(openapi, path, method)["operationId"] == operation_id


def test_every_operation_has_summary(openapi: dict[str, Any]):
    for path, method in OPERATIONS:
        assert operation(openapi, path, method).get("summary"), (path, method)


def test_validation_errors_use_common_error_schema(openapi: dict[str, Any]):
    # FastAPI既定の422(HTTPValidationError)ではなく、共通の形式(ErrorResponse)で載っていること
    assert "HTTPValidationError" not in openapi["components"]["schemas"]
    for path, method in OPERATIONS:
        response = operation(openapi, path, method)["responses"]["422"]
        schema = response["content"]["application/json"]["schema"]
        assert schema["$ref"] == "#/components/schemas/ErrorResponse", (path, method)
        assert "`validation_error`" in response["description"]


def test_error_codes_are_listed_in_descriptions(openapi: dict[str, Any]):
    register = operation(openapi, SESSIONS, "post")["responses"]
    assert "`id_conflicted`" in register["409"]["description"]
    assert "`deleted`" in register["409"]["description"]
    edit = operation(openapi, SESSION, "patch")["responses"]
    assert "`user_not_found`" in edit["404"]["description"]
    assert "`session_not_found`" in edit["404"]["description"]
    fetch = operation(openapi, SESSIONS, "get")["responses"]
    assert "`not_acceptable`" in fetch["406"]["description"]


def test_body_operations_document_413_and_415(openapi: dict[str, Any]):
    for path, method in OPERATIONS:
        if method in {"get", "delete"}:
            continue
        responses = operation(openapi, path, method)["responses"]
        assert {"413", "415"} <= set(responses), (path, method)


def test_register_documents_both_201_and_200(openapi: dict[str, Any]):
    responses = operation(openapi, SESSIONS, "post")["responses"]
    assert {"200", "201"} <= set(responses)


def test_delete_returns_204(openapi: dict[str, Any]):
    assert "204" in operation(openapi, SESSION, "delete")["responses"]


def test_request_bodies_have_examples(openapi: dict[str, Any]):
    schemas = openapi["components"]["schemas"]
    for name in ("SessionCreate", "SessionEdit", "ExistenceCheckRequest", "SyncResponse", "ErrorResponse"):
        assert schemas[name].get("examples"), name
