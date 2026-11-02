"""認証の業務ルール(サインアップ・ログイン・トークンの更新・ログアウト・アクセストークンの検証・アカウントの操作)。

設計はbackend/docs/バックエンド構成.mdの「認証」、仕様はbackend/docs/API設計ドラフト.mdの「認証のendpoints」。
時刻はDBのclock_timestamp()を正とする(同期APIと同じ)。
"""

import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app import request_context, security
from app.errors import AppError, ErrorCode
from app.models import AuthSession, RefreshToken, User
from app.models.audit_event import (
    EVENT_ACCOUNT_DISABLED,
    EVENT_ACCOUNT_ENABLED,
    EVENT_LOGIN_FAILED,
    EVENT_LOGIN_LOCKED,
    EVENT_LOGIN_SUCCEEDED,
    EVENT_LOGOUT,
    EVENT_PASSWORD_CHANGE_FAILED,
    EVENT_PASSWORD_CHANGE_LOCKED,
    EVENT_PASSWORD_CHANGED,
    EVENT_REFRESH_TOKEN_REUSED,
    EVENT_SIGNUP,
)
from app.schemas.auth import (
    ChangePasswordRequest,
    LoginRequest,
    SignupRequest,
    TokenResponse,
    UpdateMeRequest,
    UserResponse,
)
from app.services import attempt_limit_service, audit_service, mail_service
from app.services.email_verification_service import issue_verification_code
from app.services.session_service import current_time


@dataclass(frozen=True)
class AuthContext:
    """アクセストークンで認証されたユーザーと、その端末のログイン状態のID(sid)・端末ID。"""

    user: User
    auth_session_id: uuid.UUID
    device_id: uuid.UUID


def _unauthenticated() -> AppError:
    return AppError(401, ErrorCode.UNAUTHENTICATED, "認証が必要です")


def _invalid_refresh_token() -> AppError:
    return AppError(401, ErrorCode.INVALID_REFRESH_TOKEN, "再ログインしてください")


def user_response(user: User) -> UserResponse:
    return UserResponse(
        id=user.id,
        email=user.email,
        display_name=user.display_name,
        email_verified=user.email_verified,
        role=user.role,
        created_at=user.created_at,
    )


# ---- サインアップ・ログイン ---------------------------------------------------------


async def signup(db: AsyncSession, body: SignupRequest) -> TokenResponse:
    email = body.email.lower()
    if await db.scalar(select(User.id).where(User.email == email)) is not None:
        raise _email_already_registered()

    user = User(
        email=email,
        password_hash=security.hash_password(body.password),
        display_name=body.display_name or email.split("@")[0][:50],
    )
    db.add(user)
    try:
        await db.flush()
    except IntegrityError as exc:
        # 同じメールアドレスのサインアップが同時に届いた場合
        raise _email_already_registered() from exc

    # メールアドレスの確認コードを、ユーザーの作成と同じトランザクションで送る(outboxに積む)
    await issue_verification_code(db, user)
    tokens = await _start_auth_session(db, user, body.device_id, body.device_name)
    audit_service.record(db, EVENT_SIGNUP, user_id=user.id, email=email, device_id=body.device_id)
    await db.commit()
    return tokens


def _email_already_registered() -> AppError:
    return AppError(409, ErrorCode.EMAIL_ALREADY_REGISTERED, "このメールアドレスは登録済みです")


async def login(db: AsyncSession, body: LoginRequest) -> TokenResponse:
    email = body.email.lower()
    # 試行回数の上限でロック中なら、パスワードを照合せずに429にする(存在しないメールアドレスも同じに扱う)
    retry_after = await attempt_limit_service.login_retry_after(db, email)
    user = await db.scalar(select(User).where(User.email == email))
    if retry_after is not None:
        audit_service.record(
            db,
            EVENT_LOGIN_LOCKED,
            user_id=user.id if user else None,
            email=email,
            device_id=body.device_id,
        )
        await db.commit()
        raise attempt_limit_service.too_many_attempts(retry_after)
    # ユーザーが無い場合もダミーのハッシュで検証する(応答時間でユーザーの有無を区別できないようにする)
    password_ok = security.verify_password(body.password, user.password_hash if user else None)
    if user is None or not password_ok:
        await _record_login_failed(db, body, user, ErrorCode.INVALID_CREDENTIALS)
        raise AppError(401, ErrorCode.INVALID_CREDENTIALS, "メールアドレスまたはパスワードが違います")
    if user.disabled_at is not None:
        await _record_login_failed(db, body, user, ErrorCode.ACCOUNT_DISABLED)
        raise AppError(403, ErrorCode.ACCOUNT_DISABLED, "アカウントが停止されています")

    tokens = await _start_auth_session(db, user, body.device_id, body.device_name)
    audit_service.record(
        db, EVENT_LOGIN_SUCCEEDED, user_id=user.id, email=email, device_id=body.device_id
    )
    await db.commit()
    return tokens


async def _record_login_failed(
    db: AsyncSession, body: LoginRequest, user: User | None, reason: ErrorCode
) -> None:
    """ログインの失敗を監査ログに残してcommitする(この後にエラーを投げるとロールバックされるため)。"""
    audit_service.record(
        db,
        EVENT_LOGIN_FAILED,
        user_id=user.id if user else None,
        email=body.email,
        device_id=body.device_id,
        reason=reason,
    )
    await db.commit()


async def _start_auth_session(
    db: AsyncSession, user: User, device_id: uuid.UUID, device_name: str | None
) -> TokenResponse:
    """端末のログイン状態を作り、最初のリフレッシュトークンとアクセストークンを発行する(commitは呼び出し元)。"""
    request_context.set_user_id(user.id)
    now = await current_time(db)
    # 同じユーザー・同じ端末の有効なログイン状態があれば無効にする(有効なものは端末ごとに1つだけ)
    await db.execute(
        update(AuthSession)
        .where(
            AuthSession.user_id == user.id,
            AuthSession.device_id == device_id,
            AuthSession.revoked_at.is_(None),
        )
        .values(revoked_at=now)
    )
    auth_session = AuthSession(
        user_id=user.id,
        device_id=device_id,
        device_name=device_name,
        created_at=now,
        last_used_at=now,
    )
    db.add(auth_session)
    await db.flush()
    return _issue_tokens(db, user, auth_session, now)


def _issue_tokens(
    db: AsyncSession, user: User, auth_session: AuthSession, now: datetime
) -> TokenResponse:
    refresh_token = security.new_refresh_token()
    db.add(
        RefreshToken(
            auth_session_id=auth_session.id,
            token_hash=security.hash_refresh_token(refresh_token),
            expires_at=now + security.refresh_token_ttl(),
            created_at=now,
        )
    )
    return TokenResponse(
        access_token=security.create_access_token(user.id, auth_session.id),
        refresh_token=refresh_token,
        expires_in=int(security.access_token_ttl().total_seconds()),
        user=user_response(user),
    )


# ---- トークンの更新・ログアウト ------------------------------------------------------


async def refresh(db: AsyncSession, refresh_token: str) -> TokenResponse:
    """リフレッシュトークンを使って新しいトークンを発行する(ローテーション)。"""
    now = await current_time(db)
    # 同時に届いた更新が両方とも「未使用」と判定しないよう、行ロックをかける
    token = await db.scalar(
        select(RefreshToken)
        .where(RefreshToken.token_hash == security.hash_refresh_token(refresh_token))
        .with_for_update()
    )
    if token is None:
        raise _invalid_refresh_token()
    auth_session = await db.scalar(
        select(AuthSession).where(AuthSession.id == token.auth_session_id).with_for_update()
    )

    if token.used_at is not None:
        # 使用済みのトークンが再び使われた: 盗まれた可能性があるので、その端末のログイン状態を無効にする
        # (アカウントはロックしない。圏外でレスポンスが届かずに再試行した正しい利用者でも起きるため)
        if auth_session.revoked_at is None:
            auth_session.revoked_at = now
        audit_service.record(
            db,
            EVENT_REFRESH_TOKEN_REUSED,
            user_id=auth_session.user_id,
            device_id=auth_session.device_id,
        )
        await db.commit()
        raise _invalid_refresh_token()

    if token.expires_at <= now or auth_session.revoked_at is not None:
        raise _invalid_refresh_token()
    user = await db.get(User, auth_session.user_id)
    if user is None or user.disabled_at is not None:
        raise _invalid_refresh_token()

    token.used_at = now
    auth_session.last_used_at = now
    request_context.set_user_id(user.id)
    tokens = _issue_tokens(db, user, auth_session, now)
    await db.commit()
    return tokens


async def logout(db: AsyncSession, auth: AuthContext) -> None:
    """その端末のログイン状態を無効にする(アクセストークン・リフレッシュトークンともすぐに使えなくなる)。"""
    now = await current_time(db)
    await db.execute(
        update(AuthSession)
        .where(AuthSession.id == auth.auth_session_id, AuthSession.revoked_at.is_(None))
        .values(revoked_at=now)
    )
    audit_service.record(db, EVENT_LOGOUT, user_id=auth.user.id, device_id=auth.device_id)
    await db.commit()


# ---- アクセストークンの検証 --------------------------------------------------------


async def authenticate(db: AsyncSession, access_token: str) -> AuthContext:
    """アクセストークンを検証し、ユーザーと端末のログイン状態をDBで確認する。

    署名・有効期限に加えて、毎回DBで「ユーザーが存在し停止されていない」「端末のログイン状態が無効でない」ことを
    確かめる(ログアウト・削除・停止をすぐに反映するため)。
    """
    try:
        payload = security.decode_access_token(access_token)
    except security.AccessTokenExpired as exc:
        raise AppError(401, ErrorCode.TOKEN_EXPIRED, "アクセストークンの有効期限が切れています") from exc
    except security.AccessTokenInvalid as exc:
        raise _unauthenticated() from exc
    try:
        user_id = uuid.UUID(payload["sub"])
        auth_session_id = uuid.UUID(payload["sid"])
    except ValueError as exc:
        raise _unauthenticated() from exc

    row = (
        await db.execute(
            select(User, AuthSession)
            .join(AuthSession, AuthSession.user_id == User.id)
            .where(User.id == user_id, AuthSession.id == auth_session_id)
        )
    ).first()
    if row is None:
        raise _unauthenticated()
    user, auth_session = row
    if auth_session.revoked_at is not None or user.disabled_at is not None:
        raise _unauthenticated()
    return AuthContext(
        user=user, auth_session_id=auth_session_id, device_id=auth_session.device_id
    )


# ---- 自分のアカウント ----------------------------------------------------------------


async def update_me(db: AsyncSession, user: User, body: UpdateMeRequest) -> UserResponse:
    user.display_name = body.display_name
    user.updated_at = await current_time(db)
    await db.commit()
    return user_response(user)


PASSWORD_CHANGED_SUBJECT = "【osampo-tracker】パスワードが変更されました"
PASSWORD_CHANGED_BODY = """osampo-trackerのパスワードが変更されました。

心当たりが無い場合は、第三者にアカウントを使われている可能性があります。
"""


async def change_password(db: AsyncSession, auth: AuthContext, body: ChangePasswordRequest) -> None:
    """現在のパスワードを確かめてから、新しいパスワードに変える。

    変えた端末以外のログイン状態は全て無効にし(パスワードが漏れていた場合に、他の端末に残った攻撃者を締め出すため)、
    変更を知らせるメールを本人に送る(乗っ取りに早く気づけるように)。今と同じパスワードへの変更も受け付ける。
    """
    user = auth.user
    # 試行回数の上限でロック中なら、現在のパスワードを照合せずに429にする(ログインとは別に数える)
    retry_after = await attempt_limit_service.reauth_retry_after(db, user.id)
    if retry_after is not None:
        audit_service.record(
            db, EVENT_PASSWORD_CHANGE_LOCKED, user_id=user.id, email=user.email, device_id=auth.device_id
        )
        await db.commit()
        raise attempt_limit_service.too_many_attempts(retry_after)
    if not security.verify_password(body.current_password, user.password_hash):
        audit_service.record(
            db, EVENT_PASSWORD_CHANGE_FAILED, user_id=user.id, email=user.email, device_id=auth.device_id
        )
        await db.commit()
        raise AppError(400, ErrorCode.INVALID_CURRENT_PASSWORD, "現在のパスワードが違います")

    now = await current_time(db)
    user.password_hash = security.hash_password(body.new_password)
    user.updated_at = now
    await db.execute(
        update(AuthSession)
        .where(
            AuthSession.user_id == user.id,
            AuthSession.id != auth.auth_session_id,
            AuthSession.revoked_at.is_(None),
        )
        .values(revoked_at=now)
    )
    await mail_service.enqueue_email(
        db,
        to_address=user.email,
        subject=PASSWORD_CHANGED_SUBJECT,
        body=PASSWORD_CHANGED_BODY,
        recipient_user_id=user.id,
    )
    audit_service.record(
        db, EVENT_PASSWORD_CHANGED, user_id=user.id, email=user.email, device_id=auth.device_id
    )
    await db.commit()


async def delete_me(db: AsyncSession, user: User) -> None:
    """アカウントを物理削除する。外部キーのON DELETE CASCADEで、sessions・track_points・端末のログイン状態・
    リフレッシュトークンも一緒に消える(tombstoneは残さない)。監査ログはそのユーザーの記録を消し、削除の記録
    (日時とuser_id)だけを残す。"""
    await audit_service.record_account_deleted(db, user.id)
    await db.delete(user)
    await db.commit()


# ---- アカウントの停止・解除(管理用のコマンドから使う) ----------------------------------


async def set_user_disabled(db: AsyncSession, email: str, disabled: bool) -> User:
    """アカウントを停止・解除する。停止するときはその人の端末のログイン状態も全て無効にする
    (解除しても前のトークンは使えず、ログインし直す)。"""
    user = await db.scalar(select(User).where(User.email == email.lower()))
    if user is None:
        raise ValueError(f"ユーザーが見つかりません: {email}")
    now = await current_time(db)
    if disabled:
        user.disabled_at = now
        await db.execute(
            update(AuthSession)
            .where(AuthSession.user_id == user.id, AuthSession.revoked_at.is_(None))
            .values(revoked_at=now)
        )
    else:
        user.disabled_at = None
    user.updated_at = now
    audit_service.record(
        db,
        EVENT_ACCOUNT_DISABLED if disabled else EVENT_ACCOUNT_ENABLED,
        user_id=user.id,
        email=user.email,
    )
    await db.commit()
    return user
