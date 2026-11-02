"""エラーを共通の形式(`{"code": ..., "message": ..., "details": [...]}`)のJSONレスポンスに変換する仕組み。

install_error_handling(app)で、例外ハンドラーとbodyのサイズの上限を確認するミドルウェアをまとめて登録する。
"""

import logging
from http import HTTPStatus

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app import request_context
from app.errors import AppError, ErrorCode

logger = logging.getLogger("app.errors")

# FastAPI・Starletteが既定で投げるHTTPExceptionのステータスとcodeの対応
_HTTP_STATUS_CODES: dict[int, ErrorCode] = {
    401: ErrorCode.UNAUTHENTICATED,
    403: ErrorCode.FORBIDDEN,
    404: ErrorCode.NOT_FOUND,
    405: ErrorCode.METHOD_NOT_ALLOWED,
    406: ErrorCode.NOT_ACCEPTABLE,
    413: ErrorCode.PAYLOAD_TOO_LARGE,
    415: ErrorCode.UNSUPPORTED_MEDIA_TYPE,
}

_DEFAULT_MESSAGES: dict[ErrorCode, str] = {
    ErrorCode.UNAUTHENTICATED: "認証が必要です",
    ErrorCode.FORBIDDEN: "この操作の権限がありません",
    ErrorCode.NOT_FOUND: "指定されたパスは存在しません",
    ErrorCode.METHOD_NOT_ALLOWED: "このパスでは指定されたメソッドを使えません",
    ErrorCode.NOT_ACCEPTABLE: "レスポンスはapplication/jsonでのみ返せます",
    ErrorCode.PAYLOAD_TOO_LARGE: "リクエストのbodyが大きすぎます",
    ErrorCode.UNSUPPORTED_MEDIA_TYPE: "Content-Typeはapplication/jsonにしてください",
}


def error_response(
    status_code: int,
    code: ErrorCode,
    message: str,
    details: list[dict[str, str]] | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    # アクセスログにcodeを載せる
    request_context.set_error_code(code)
    content: dict[str, object] = {"code": code, "message": message}
    # detailsは422のときだけ入れる(Noneならキー自体を含めない)
    if details is not None:
        content["details"] = details
    return JSONResponse(status_code=status_code, content=content, headers=headers)


async def _handle_app_error(request: Request, exc: AppError) -> JSONResponse:
    return error_response(exc.status_code, exc.code, exc.message, exc.details, exc.headers)


async def _handle_http_exception(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    """存在しないパスへの404・許可されていないメソッドへの405など、FastAPI・Starletteが投げるエラー。"""
    code = _HTTP_STATUS_CODES.get(exc.status_code, ErrorCode.HTTP_ERROR)
    message = _DEFAULT_MESSAGES.get(code)
    if message is None:
        message = exc.detail if isinstance(exc.detail, str) else HTTPStatus(exc.status_code).phrase
    # 405のAllowヘッダーなど、例外が持っているヘッダーはそのまま返す
    return error_response(exc.status_code, code, message, headers=exc.headers)


async def _handle_validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
    """入力チェックの失敗。どの項目がなぜ不正かをdetailsに入れる。"""
    details = [
        {
            # locは("body", "move_method")のような、受け取った場所と項目名の組
            "field": ".".join(str(part) for part in error["loc"]),
            "reason": error["msg"],
        }
        for error in exc.errors()
    ]
    return error_response(422, ErrorCode.VALIDATION_ERROR, "入力が不正です", details)


async def _handle_unexpected_error(request: Request, exc: Exception) -> JSONResponse:
    """想定外のエラー。原因(スタックトレース)はログにだけ出し、レスポンスには含めない。

    ログはapp/request_context.pyのミドルウェアが出す(このハンドラーはミドルウェアの外側で動き、リクエストの情報を
    参照できないため)。リクエストIDはscopeに置かれたものをヘッダーに付ける。
    """
    context = request.scope.get("request_context")
    if context is None:
        # ミドルウェアを入れていないアプリ(テスト用の小さなアプリ等)では、ここでログに出す
        logger.error("Unhandled error: %s %s", request.method, request.url.path, exc_info=exc)
    headers = {request_context.REQUEST_ID_HEADER: context.request_id} if context else None
    return error_response(
        500, ErrorCode.INTERNAL_ERROR, "サーバーで想定外のエラーが発生しました", headers=headers
    )


class BodySizeLimitMiddleware:
    """リクエストのbodyのサイズを制限する(uvicorn・FastAPIには既定の上限が無く、bodyを全てメモリに読み込むため)。

    Content-Lengthが上限を超えていれば読み込む前に413を返す。Content-Lengthが無い(chunked)場合は、
    読み込んだ量が上限を超えた時点で413にする。
    """

    def __init__(self, app: ASGIApp, max_body_bytes: int) -> None:
        self.app = app
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        content_length = dict(scope["headers"]).get(b"content-length")
        if (
            content_length is not None
            and content_length.isdigit()
            and int(content_length) > self.max_body_bytes
        ):
            response = error_response(
                413,
                ErrorCode.PAYLOAD_TOO_LARGE,
                _DEFAULT_MESSAGES[ErrorCode.PAYLOAD_TOO_LARGE],
            )
            await response(scope, receive, send)
            return

        received = 0

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_body_bytes:
                    # FastAPIはbodyの読み込み中の例外を400にしてしまうが、HTTPExceptionはそのまま投げ直すので、
                    # HTTPExceptionにして_handle_http_exceptionで413のレスポンスにする
                    raise HTTPException(status_code=413)
            return message

        await self.app(scope, limited_receive, send)


def install_error_handling(app: FastAPI, max_body_bytes: int) -> None:
    """例外ハンドラーとbodyのサイズの上限をアプリに登録する。"""
    app.add_exception_handler(AppError, _handle_app_error)
    app.add_exception_handler(StarletteHTTPException, _handle_http_exception)
    app.add_exception_handler(RequestValidationError, _handle_validation_error)
    app.add_exception_handler(Exception, _handle_unexpected_error)
    app.add_middleware(BodySizeLimitMiddleware, max_body_bytes=max_body_bytes)
