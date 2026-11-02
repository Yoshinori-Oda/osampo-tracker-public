"""リクエストの情報(リクエストID・送信元のIP・認証したユーザー・エラーのcode)と、アクセスログ。

設計はbackend/docs/バックエンド構成.mdの「ログ」。ASGIのミドルウェアがリクエストごとにRequestContextを作ってcontextvarに入れ、
サービスの処理・ログの整形・監査ログ(app/services/audit_service.py)から参照する(引数で渡して回らずに済むように)。
リクエストの処理の途中で分かること(認証したユーザー・エラーのcode)は、このオブジェクトの属性を書き換えて伝える
(contextvarに入れ直すと、処理が別のタスクで動いた場合にミドルウェアから見えないため)。
リバースプロキシを置いたら、X-Forwarded-For等をどこまで信用するかを決めて、送信元のIPの取り方を見直す。
"""

import ipaddress
import logging
import re
import time
import uuid
from contextvars import ContextVar
from dataclasses import dataclass

from starlette.types import ASGIApp, Message, Receive, Scope, Send

REQUEST_ID_HEADER = "X-Request-ID"
# 端末が送るリクエストIDとして受け付ける形式(端末はUUIDを送る)。それ以外は使わずにサーバーで作る
# (ログに任意の文字列を書き込ませないため)
_VALID_REQUEST_ID = re.compile(r"^[0-9A-Za-z-]{8,64}$")

access_logger = logging.getLogger("app.access")


@dataclass
class RequestContext:
    request_id: str
    ip: str | None
    user_id: uuid.UUID | None = None
    # エラーのレスポンスのcode(app/error_handlers.pyのerror_responseが入れる)
    error_code: str | None = None


_current: ContextVar[RequestContext | None] = ContextVar("request_context", default=None)


def current() -> RequestContext | None:
    """今のリクエストの情報(リクエストの外ではNone)。"""
    return _current.get()


def client_ip() -> str | None:
    """今のリクエストの送信元のIP(リクエストの外・取れない場合はNone)。"""
    context = current()
    return context.ip if context else None


def request_id() -> str | None:
    context = current()
    return context.request_id if context else None


def set_user_id(user_id: uuid.UUID) -> None:
    """認証できたユーザーを、アクセスログ・アプリのログに載せる。"""
    context = current()
    if context is not None:
        context.user_id = user_id


def set_error_code(code: str) -> None:
    context = current()
    if context is not None:
        context.error_code = code


class RequestContextMiddleware:
    """リクエストごとにRequestContextを作り、レスポンスにX-Request-IDを付け、終わったらアクセスログを1行出す。

    想定外の例外は、ここでスタックトレースをログに出してから投げ直す(500のレスポンスを作るStarletteの
    ServerErrorMiddlewareはこれより外側で動き、そこではリクエストの情報を参照できないため)。
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        context = RequestContext(request_id=_request_id_from(scope), ip=_parse_ip(scope.get("client")))
        # 外側(ServerErrorMiddleware)の500のレスポンスにもX-Request-IDを付けられるよう、scopeにも置く
        scope["request_context"] = context
        token = _current.set(context)
        started = time.perf_counter()
        status: int | None = None

        async def send_with_request_id(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                headers = list(message.get("headers", []))
                headers.append((REQUEST_ID_HEADER.lower().encode(), context.request_id.encode()))
                message = {**message, "headers": headers}
            await send(message)

        try:
            await self.app(scope, receive, send_with_request_id)
        except Exception:
            status = 500
            context.error_code = "internal_error"
            logging.getLogger("app.errors").exception(
                "Unhandled error: %s %s", scope["method"], _path_template(scope)
            )
            raise
        finally:
            _log_access(scope, context, status, time.perf_counter() - started)
            _current.reset(token)


def _log_access(scope: Scope, context: RequestContext, status: int | None, elapsed: float) -> None:
    """アクセスログを1行出す。bodyとクエリ文字列は残さない(位置情報・パスワード等が入るため)。"""
    access_logger.info(
        "request",
        # リクエストIDとuser_idは、ログの設定(app/logging_config.py)がリクエストの情報から付ける
        extra={
            "ip": context.ip,
            "method": scope["method"],
            "path": _path_template(scope),
            # レスポンスを返す前に接続が切れた等で、ステータスが無いこともある
            "status": status,
            "code": context.error_code,
            "duration_ms": round(elapsed * 1000, 1),
        },
    )


def _path_template(scope: Scope) -> str:
    """パスの型(/api/users/{user_id}/sessions)。パスにはuser_id等が入るので、実際のパスは残さない。

    どのルートにも当たらなかった(404 not_found)場合は、探られたパスが分かるよう実際のパスを残す(長さは切り詰める)。
    """
    route = scope.get("route")
    path = getattr(route, "path", None)
    return path if path is not None else scope["path"][:200]


def _request_id_from(scope: Scope) -> str:
    for name, value in scope.get("headers", []):
        if name == REQUEST_ID_HEADER.lower().encode():
            candidate = value.decode("latin-1")
            if _VALID_REQUEST_ID.match(candidate):
                return candidate
            break
    return str(uuid.uuid4())


def _parse_ip(client: tuple[str, int] | None) -> str | None:
    # IPアドレスとして読めないもの(テスト用のクライアントの"testclient"等)は残さない(DBの型がINETのため)
    if client is None:
        return None
    try:
        return str(ipaddress.ip_address(client[0]))
    except ValueError:
        return None
