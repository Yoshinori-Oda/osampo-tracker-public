"""自分のアカウント(/api/users/me)。仕様はbackend/docs/API設計ドラフト.mdの「認証のendpoints」
「メールアドレスの確認のendpoints」。

将来、管理者向けに他ユーザーを操作する機能を作るときは、/api/users/{user_id} のendpointを別に追加する。
"""

from fastapi import APIRouter, Depends, Response, status

from app.dependencies import CurrentAuth, DbSession, require_json_content_type
from app.errors import ErrorCode
from app.schemas.auth import (
    ChangePasswordRequest,
    ConfirmEmailRequest,
    EmailVerificationSentResponse,
    UpdateMeRequest,
    UserResponse,
)
from app.schemas.error import error_responses
from app.services import auth_service, email_verification_service

router = APIRouter(prefix="/api/users/me", tags=["users"])

_AUTH = {401: [ErrorCode.UNAUTHENTICATED, ErrorCode.TOKEN_EXPIRED]}


@router.get(
    "",
    summary="自分の情報",
    response_model=UserResponse,
    responses=error_responses(_AUTH),
)
async def get_me(auth: CurrentAuth) -> UserResponse:
    return auth_service.user_response(auth.user)


@router.patch(
    "",
    summary="自分の情報の変更",
    response_model=UserResponse,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses(
        {
            **_AUTH,
            413: [ErrorCode.PAYLOAD_TOO_LARGE],
            415: [ErrorCode.UNSUPPORTED_MEDIA_TYPE],
            422: [ErrorCode.VALIDATION_ERROR],
        }
    ),
)
async def update_me(body: UpdateMeRequest, auth: CurrentAuth, db: DbSession) -> UserResponse:
    """表示名を変更する(メールアドレス・パスワードの変更は別のendpoint)。"""
    return await auth_service.update_me(db, auth.user, body)


@router.put(
    "/password",
    summary="パスワードの変更",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses(
        {
            400: [ErrorCode.INVALID_CURRENT_PASSWORD],
            **_AUTH,
            413: [ErrorCode.PAYLOAD_TOO_LARGE],
            415: [ErrorCode.UNSUPPORTED_MEDIA_TYPE],
            422: [ErrorCode.VALIDATION_ERROR],
            429: [ErrorCode.TOO_MANY_REQUESTS],
        }
    ),
)
async def change_password(body: ChangePasswordRequest, auth: CurrentAuth, db: DbSession) -> Response:
    """現在のパスワードを確かめてから、新しいパスワードに変える。

    - 現在のパスワードが違えば400(`invalid_current_password`)。401にしないのは、クライアントが401を
      「ログイン状態が無効になった(再ログインが必要)」として扱うため
    - この端末以外のログイン状態は全て無効になる(この端末はログインしたまま)
    - 変更を知らせるメールを本人に送る
    - 現在のパスワードを15分以内に10回間違えると、最後の失敗から15分は照合せずに429(`too_many_requests`。待つ秒数は
      `Retry-After`ヘッダー)。ログインの試行回数とは別に、ユーザーごとに数える
    """
    await auth_service.change_password(db, auth, body)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete(
    "",
    summary="アカウントの削除",
    status_code=status.HTTP_204_NO_CONTENT,
    responses=error_responses(_AUTH),
)
async def delete_me(auth: CurrentAuth, db: DbSession) -> Response:
    """アカウントを物理削除する(セッション・トラックポイント・端末のログイン状態も一緒に消える)。

    アプリの審査で求められる「アプリ内からのアカウントと関連データの削除」に当たる。他の端末は次のリクエストで401になる。
    """
    await auth_service.delete_me(db, auth.user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/email-verification",
    summary="確認コードの送信",
    response_model=EmailVerificationSentResponse,
    status_code=status.HTTP_202_ACCEPTED,
    responses=error_responses(
        {**_AUTH, 409: [ErrorCode.EMAIL_ALREADY_VERIFIED], 429: [ErrorCode.TOO_MANY_REQUESTS]}
    ),
)
async def send_email_verification(auth: CurrentAuth, db: DbSession) -> EmailVerificationSentResponse:
    """メールアドレスの確認コードを(再)送する。前のコードは使えなくなる。

    サインアップ時にも自動で送る。再送は前回から60秒あけ、24時間に5回まで(超えると429。待つ秒数は`Retry-After`ヘッダー)。
    202はメールを送信待ちに積んだという意味で、workerが数秒以内に送る。
    """
    issued = await email_verification_service.send_verification_code(db, auth.user)
    return EmailVerificationSentResponse(
        expires_in=issued.expires_in, resend_available_in=issued.resend_available_in
    )


@router.post(
    "/email-verification/confirm",
    summary="確認コードの確認",
    response_model=UserResponse,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses(
        {
            **_AUTH,
            400: [ErrorCode.INVALID_VERIFICATION_CODE, ErrorCode.VERIFICATION_CODE_EXPIRED],
            413: [ErrorCode.PAYLOAD_TOO_LARGE],
            415: [ErrorCode.UNSUPPORTED_MEDIA_TYPE],
            422: [ErrorCode.VALIDATION_ERROR],
        }
    ),
)
async def confirm_email_verification(
    body: ConfirmEmailRequest, auth: CurrentAuth, db: DbSession
) -> UserResponse:
    """確認コードを照合し、合っていればメールアドレスを確認済みにする(以降、同期APIが使える)。

    同じコードで5回間違えるとそのコードは使えなくなる(以降は`verification_code_expired`。再送する)。
    確認済みなら、コードに関係なく200(確認に成功したのにレスポンスが届かず再送した場合のため)。
    """
    user = await email_verification_service.confirm_verification_code(
        db, auth.user, body.code, device_id=auth.device_id
    )
    return auth_service.user_response(user)
