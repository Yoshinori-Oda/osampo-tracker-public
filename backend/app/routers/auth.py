"""認証(/api/auth)。仕様はbackend/docs/API設計ドラフト.mdの「認証のendpoints」。"""

from fastapi import APIRouter, Depends, Response, status

from app.dependencies import CurrentAuth, DbSession, require_json_content_type
from app.errors import ErrorCode
from app.schemas.auth import LoginRequest, RefreshRequest, SignupRequest, TokenResponse
from app.schemas.error import error_responses
from app.services import auth_service

router = APIRouter(prefix="/api/auth", tags=["auth"])

_BODY = {
    413: [ErrorCode.PAYLOAD_TOO_LARGE],
    415: [ErrorCode.UNSUPPORTED_MEDIA_TYPE],
    422: [ErrorCode.VALIDATION_ERROR],
}


@router.post(
    "/signup",
    summary="新規登録",
    response_model=TokenResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses({409: [ErrorCode.EMAIL_ALREADY_REGISTERED], **_BODY}),
)
async def signup(body: SignupRequest, db: DbSession) -> TokenResponse:
    """アカウントを作り、そのままログインした状態のトークンを返す。

    作成直後はメールアドレスが未確認(`email_verified`がfalse)なので、ログインはできるが同期APIは403(`email_not_verified`)。
    確認コードのメールを自動で送る(`POST /api/users/me/email-verification/confirm`で確認する)。
    """
    return await auth_service.signup(db, body)


@router.post(
    "/login",
    summary="ログイン",
    response_model=TokenResponse,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses(
        {
            401: [ErrorCode.INVALID_CREDENTIALS],
            403: [ErrorCode.ACCOUNT_DISABLED],
            **_BODY,
            429: [ErrorCode.TOO_MANY_REQUESTS],
        }
    ),
)
async def login(body: LoginRequest, db: DbSession) -> TokenResponse:
    """メールアドレスとパスワードでログインし、トークンを返す。

    - メールアドレスが無い・パスワードが違うは区別せず401(`invalid_credentials`)
    - 停止中のアカウントは、パスワードが合っていた場合のみ403(`account_disabled`)
    - 同じ端末(`device_id`)の古いログイン状態は無効にする
    - 同じメールアドレスで15分以内に10回失敗すると、最後の失敗から15分はパスワードを照合せずに429(`too_many_requests`。
      待つ秒数は`Retry-After`ヘッダー)。存在しないメールアドレスも同じように数える
    """
    return await auth_service.login(db, body)


@router.post(
    "/refresh",
    summary="トークンの更新",
    response_model=TokenResponse,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses({401: [ErrorCode.INVALID_REFRESH_TOKEN], **_BODY}),
)
async def refresh(body: RefreshRequest, db: DbSession) -> TokenResponse:
    """リフレッシュトークンで新しいアクセストークンとリフレッシュトークンを発行する(ローテーション)。

    Authorizationヘッダーは不要(アクセストークンが期限切れでも使えるようにするため)。使用済みのリフレッシュトークンが
    再び使われた場合は、盗まれた可能性があるのでその端末のログイン状態を無効にして401(`invalid_refresh_token`)。
    """
    return await auth_service.refresh(db, body.refresh_token)


@router.post(
    "/logout",
    summary="ログアウト",
    status_code=status.HTTP_204_NO_CONTENT,
    responses=error_responses({401: [ErrorCode.UNAUTHENTICATED, ErrorCode.TOKEN_EXPIRED]}),
)
async def logout(auth: CurrentAuth, db: DbSession) -> Response:
    """その端末のログイン状態を無効にする。その端末のアクセストークン・リフレッシュトークンはすぐに使えなくなる。"""
    await auth_service.logout(db, auth)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
