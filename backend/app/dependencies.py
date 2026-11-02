"""複数のエンドポイントで共通して使う依存関係(FastAPIのDepends用)。"""

import uuid
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app import request_context
from app.db import get_session, set_rls_user
from app.errors import AppError, ErrorCode
from app.models.audit_event import EVENT_ACCESS_DENIED, EVENT_ADMIN_USER_ACCESS
from app.services import audit_service, auth_service, session_service
from app.services.auth_service import AuthContext

DbSession = Annotated[AsyncSession, Depends(get_session)]


async def require_json_content_type(request: Request) -> None:
    """bodyを受け取るエンドポイント(POST・PATCH)で、Content-Typeがapplication/jsonであることを確認する。

    依存関係はbodyの入力チェックより先に実行されるので、JSON以外のbodyは422ではなく415になる。
    """
    content_type = request.headers.get("content-type", "")
    # "application/json; charset=utf-8"のようなパラメーター付きも受け付ける
    if content_type.split(";")[0].strip().lower() != "application/json":
        raise AppError(
            415,
            ErrorCode.UNSUPPORTED_MEDIA_TYPE,
            "Content-Typeはapplication/jsonにしてください",
        )


async def require_json_accept(request: Request) -> None:
    """Acceptでapplication/jsonを受け付けていなければ406にする(Acceptが無ければ何でも受け付けるとみなす)。"""
    accept = request.headers.get("accept")
    if accept is None:
        return
    media_ranges = {part.split(";")[0].strip().lower() for part in accept.split(",")}
    if media_ranges.isdisjoint({"application/json", "application/*", "*/*"}):
        raise AppError(406, ErrorCode.NOT_ACCEPTABLE, "レスポンスはapplication/jsonでのみ返せます")


# auto_error=False: ヘッダーが無い場合もFastAPI既定の403ではなく、共通の形式の401(unauthenticated)を返すため。
# OpenAPIの画面の「Authorize」ボタンでアクセストークンを設定できるようにもなる
_bearer = HTTPBearer(auto_error=False, description="アクセストークン(POST /api/auth/login等で取得)")


async def get_auth_context(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
    db: DbSession,
) -> AuthContext:
    """Authorization: Bearer のアクセストークンを検証し、認証されたユーザーを返す(できなければ401)。"""
    if credentials is None:
        raise AppError(401, ErrorCode.UNAUTHENTICATED, "認証が必要です")
    auth = await auth_service.authenticate(db, credentials.credentials)
    # アクセスログ・アプリのログに載せる
    request_context.set_user_id(auth.user.id)
    # RLSのポリシーに今のユーザーを渡す(以降のトランザクションでも渡し直す)
    await set_rls_user(db, auth.user.id)
    return auth


CurrentAuth = Annotated[AuthContext, Depends(get_auth_context)]


async def verify_user_access(user_id: uuid.UUID, auth: CurrentAuth, db: DbSession) -> uuid.UUID:
    """同期APIで、パスパラメーターのuser_idのユーザーを操作してよいかを確認し、user_idを返す。

    API設計書の「認証と権限」の順に判定する: 401(get_auth_context) → 403(forbidden) → 403(email_not_verified)
    → 404(user_not_found)。一般ユーザーは自分以外のuser_idを指定すると403で止まるので、他ユーザーの有無は分からない。
    他人のデータへのアクセスの拒否と、管理者による他のユーザーのデータへのアクセスは監査ログに残す(GETはcommitしないので、
    ここでcommitする)。
    """
    me = auth.user
    if not me.is_admin and me.id != user_id:
        audit_service.record(
            db, EVENT_ACCESS_DENIED, user_id=me.id, device_id=auth.device_id, target_user_id=user_id
        )
        await db.commit()
        raise AppError(403, ErrorCode.FORBIDDEN, "この操作の権限がありません")
    if not me.email_verified:
        raise AppError(403, ErrorCode.EMAIL_NOT_VERIFIED, "メールアドレスを確認すると同期できます")
    if me.id != user_id:
        # 管理者が他ユーザーを指定した場合だけ、そのユーザーの存在を確認する
        await session_service.ensure_user_exists(db, user_id)
        audit_service.record(
            db, EVENT_ADMIN_USER_ACCESS, user_id=me.id, device_id=auth.device_id, target_user_id=user_id
        )
        await db.commit()
    return user_id


TargetUserId = Annotated[uuid.UUID, Depends(verify_user_access)]
