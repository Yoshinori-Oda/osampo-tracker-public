"""メールアドレスの確認コードの送信と確認。

設計はbackend/docs/バックエンド構成.mdの「メールアドレスの確認コード」、仕様はbackend/docs/API設計ドラフト.mdの
「メールアドレスの確認のendpoints」。時刻はDBのclock_timestamp()を正とする。
"""

import math
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app import security
from app.config import settings
from app.errors import AppError, ErrorCode
from app.models import EmailCode, User
from app.models.audit_event import EVENT_EMAIL_VERIFIED
from app.models.email_code import CODE_LOCKED, CODE_PENDING, CODE_USED, PURPOSE_VERIFY_EMAIL
from app.services import audit_service, mail_service
from app.services.session_service import current_time

SEND_WINDOW = timedelta(hours=24)

SUBJECT = "【osampo-tracker】メールアドレスの確認コード"
BODY_TEMPLATE = """確認コード: {code}

このコードの有効期限は{ttl_minutes}分です。
心当たりが無い場合は、このメールを破棄してください。
"""


@dataclass(frozen=True)
class IssuedCode:
    """送ったコードの有効期限までの秒数と、次に再送できるまでの秒数。"""

    expires_in: int
    resend_available_in: int


def _seconds_until(moment: datetime, now: datetime) -> int:
    """momentまでの秒数(切り上げ。過ぎていれば0)。Retry-After等で「この秒数だけ待てばよい」を返すため。"""
    return max(0, math.ceil((moment - now).total_seconds()))


def _resend_interval() -> timedelta:
    return timedelta(seconds=settings.email_code_resend_interval_seconds)


def _next_send_available_at(row: EmailCode) -> datetime | None:
    """次に送れるようになる日時。今すぐ送れるならNone。"""
    if row.send_count >= settings.email_code_daily_limit:
        return row.send_window_started_at + SEND_WINDOW
    if row.send_count > 0:
        return row.issued_at + _resend_interval()
    return None


async def _lock_code_row(db: AsyncSession, user: User) -> EmailCode | None:
    return await db.scalar(
        select(EmailCode)
        .where(EmailCode.user_id == user.id, EmailCode.purpose == PURPOSE_VERIFY_EMAIL)
        .with_for_update()
    )


async def issue_verification_code(db: AsyncSession, user: User) -> IssuedCode:
    """確認コードを作り、メールをoutboxに積む(サインアップ時・再送で共通)。commitは呼び出し元。

    送信の間隔・回数の上限を超えていれば429。前のコードは使えなくなり、前のコードのメールがまだ送られていなければ取り消す。
    """
    now = await current_time(db)
    # 行が無ければ作る(サインアップ以外で作られたユーザー: この機能より前のユーザー・seed-devの未確認ユーザー等)。
    # 同じユーザーの再送が同時に届いても主キーが衝突しないよう、INSERT ... ON CONFLICT DO NOTHINGにする
    await db.execute(
        insert(EmailCode)
        .values(
            user_id=user.id,
            purpose=PURPOSE_VERIFY_EMAIL,
            status=CODE_PENDING,
            failed_attempts=0,
            issued_at=now,
            send_count=0,
            send_window_started_at=now,
        )
        .on_conflict_do_nothing()
    )
    # 行をロックして、同じユーザーの送信・確認を順番に処理する
    row = await _lock_code_row(db, user)

    # 数え始めから24時間経っていれば、送信回数を数え直す
    if now >= row.send_window_started_at + SEND_WINDOW:
        row.send_count = 0
        row.send_window_started_at = now
    available_at = _next_send_available_at(row)
    if available_at is not None and now < available_at:
        retry_after = _seconds_until(available_at, now)
        raise AppError(
            429,
            ErrorCode.TOO_MANY_REQUESTS,
            f"確認コードは{retry_after}秒後に送れます",
            headers={"Retry-After": str(retry_after)},
        )

    # 前のコードのメールがまだ送られていなければ取り消す(後から届いて、入力の失敗の枠を無駄に使わないように)
    if row.outbox_email_id is not None:
        await mail_service.cancel_pending_email(db, row.outbox_email_id)

    code = security.new_verification_code()
    expires_at = now + timedelta(minutes=settings.email_code_ttl_minutes)
    row.code_hash = security.hash_verification_code(code)
    row.expires_at = expires_at
    row.status = CODE_PENDING
    row.failed_attempts = 0
    row.issued_at = now
    row.send_count += 1
    email = await mail_service.enqueue_email(
        db,
        to_address=user.email,
        subject=SUBJECT,
        body=BODY_TEMPLATE.format(code=code, ttl_minutes=settings.email_code_ttl_minutes),
        recipient_user_id=user.id,
        # 送信が遅れてコードの有効期限を過ぎたら送らない
        send_deadline=expires_at,
    )
    row.outbox_email_id = email.id
    await db.flush()

    next_available_at = _next_send_available_at(row)
    return IssuedCode(
        expires_in=_seconds_until(expires_at, now),
        resend_available_in=_seconds_until(next_available_at, now) if next_available_at else 0,
    )


async def send_verification_code(db: AsyncSession, user: User) -> IssuedCode:
    """確認コードを(再)送する。確認済みなら409。"""
    if user.email_verified:
        raise AppError(409, ErrorCode.EMAIL_ALREADY_VERIFIED, "メールアドレスは確認済みです")
    issued = await issue_verification_code(db, user)
    await db.commit()
    return issued


def _code_expired() -> AppError:
    return AppError(
        400, ErrorCode.VERIFICATION_CODE_EXPIRED, "確認コードの有効期限が切れています。再送してください"
    )


async def confirm_verification_code(
    db: AsyncSession, user: User, code: str, device_id: uuid.UUID | None = None
) -> User:
    """確認コードを照合し、合っていればメールアドレスを確認済みにする。

    確認済みなら、コードを見ずにそのまま返す(確認に成功したのにレスポンスが届かず再送された場合に、失敗に見えないようにするため)。
    """
    if user.email_verified:
        return user

    now = await current_time(db)
    row = await _lock_code_row(db, user)
    if (
        row is None
        or row.status != CODE_PENDING
        or row.code_hash is None
        or row.expires_at is None
        or row.expires_at <= now
    ):
        raise _code_expired()

    if not security.verify_verification_code(code, row.code_hash):
        row.failed_attempts += 1
        if row.failed_attempts >= settings.email_code_max_failed_attempts:
            # 失敗の上限に達したら、このコードは使えなくする(再送で新しいコードを受け取る)
            row.status = CODE_LOCKED
            row.code_hash = None
            row.expires_at = None
        await db.commit()
        raise AppError(400, ErrorCode.INVALID_VERIFICATION_CODE, "確認コードが違います")

    row.status = CODE_USED
    row.code_hash = None
    row.expires_at = None
    user.email_verified_at = now
    user.updated_at = now
    audit_service.record(
        db, EVENT_EMAIL_VERIFIED, user_id=user.id, email=user.email, device_id=device_id
    )
    await db.commit()
    return user
