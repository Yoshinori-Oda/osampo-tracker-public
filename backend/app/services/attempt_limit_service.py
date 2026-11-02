"""ログインと、現在のパスワードによる再確認の試行回数の制限(パスワードの総当たりへの対策)。

設計はbackend/docs/バックエンド構成.mdの「ログインの試行回数の制限」。失敗は監査ログ(audit_events)から数え、2つは別に数える
(攻撃者が違うため。ログインはログインしていない人の推測、再確認はログイン状態を持つ人(盗んだトークン等)の推測)。
- ログイン: 入力されたメールアドレス単位(存在しないアドレスも同じように数え、ロックの有無で登録の有無が分からないようにする)
- 再確認(パスワードの変更。メールアドレスの変更を作ったら加える): ユーザー単位

直近の成功より後の失敗が、AUTH_FAILURE_WINDOW_MINUTES(既定15分)以内にAUTH_MAX_FAILED_ATTEMPTS(既定10回)たまったら、
最後の失敗からAUTH_LOCK_MINUTES(既定15分)ロックする。時間が経てば解ける(完全にロックすると、攻撃者がわざと間違えて本人を
締め出せるため)。ロック中の拒否は失敗に数えない(数えると、攻撃が続く限りロックが解けないため)。
"""

import math
import uuid
from datetime import datetime, timedelta

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute

from app.config import settings
from app.errors import AppError, ErrorCode
from app.models import AuditEvent
from app.models.audit_event import (
    EVENT_LOGIN_FAILED,
    EVENT_LOGIN_SUCCEEDED,
    EVENT_PASSWORD_CHANGE_FAILED,
    EVENT_PASSWORD_CHANGED,
)
from app.services.session_service import current_time

# 再確認の失敗・成功として数える出来事(メールアドレスの変更を作ったら、その失敗・成功も加える)
REAUTH_FAILED_EVENTS = (EVENT_PASSWORD_CHANGE_FAILED,)
REAUTH_SUCCEEDED_EVENTS = (EVENT_PASSWORD_CHANGED,)


async def login_retry_after(db: AsyncSession, email: str) -> int | None:
    """そのメールアドレスでのログインがロック中なら、解けるまでの秒数を返す(ロックされていなければNone)。

    同じメールアドレスへの同時のログインで、判定と失敗の記録の間に割り込まれないよう、トランザクションの終わりまで
    メールアドレスごとのロック(advisory lock)を取る。呼び出し元はこの後、失敗・成功を記録してcommitする。
    """
    await _lock(db, f"login:{email}")
    # 停止中のアカウントでの失敗(パスワードは合っていた)は、推測ではないので数えない
    until = await _locked_until(
        db,
        AuditEvent.email,
        email,
        failed_events=(EVENT_LOGIN_FAILED,),
        succeeded_events=(EVENT_LOGIN_SUCCEEDED,),
        failed_reason=ErrorCode.INVALID_CREDENTIALS,
    )
    return await _seconds_until(db, until)


async def reauth_retry_after(db: AsyncSession, user_id: uuid.UUID) -> int | None:
    """そのユーザーの現在のパスワードによる再確認がロック中なら、解けるまでの秒数を返す(ロックされていなければNone)。"""
    await _lock(db, f"reauth:{user_id}")
    until = await _locked_until(
        db,
        AuditEvent.user_id,
        user_id,
        failed_events=REAUTH_FAILED_EVENTS,
        succeeded_events=REAUTH_SUCCEEDED_EVENTS,
    )
    return await _seconds_until(db, until)


def too_many_attempts(retry_after: int) -> AppError:
    minutes = math.ceil(retry_after / 60)
    return AppError(
        429,
        ErrorCode.TOO_MANY_REQUESTS,
        f"試行回数の上限に達しました。{minutes}分後に試してください",
        headers={"Retry-After": str(retry_after)},
    )


async def _lock(db: AsyncSession, key: str) -> None:
    """トランザクションの終わり(commit・rollback)まで、keyごとのロックを取る。"""
    await db.execute(select(func.pg_advisory_xact_lock(func.hashtextextended(key, 0))))


async def _locked_until(
    db: AsyncSession,
    column: InstrumentedAttribute,
    value: object,
    *,
    failed_events: tuple[str, ...],
    succeeded_events: tuple[str, ...],
    failed_reason: str | None = None,
) -> datetime | None:
    """ロックが解ける日時(上限に達していなければNone。過去の日時なら、もう解けている)。"""
    max_attempts = settings.auth_max_failed_attempts
    last_success = (
        select(func.max(AuditEvent.occurred_at))
        .where(column == value, AuditEvent.event_type.in_(succeeded_events))
        .scalar_subquery()
    )
    query = (
        select(AuditEvent.occurred_at)
        .where(
            column == value,
            AuditEvent.event_type.in_(failed_events),
            or_(last_success.is_(None), AuditEvent.occurred_at > last_success),
        )
        .order_by(AuditEvent.occurred_at.desc())
        .limit(max_attempts)
    )
    if failed_reason is not None:
        query = query.where(AuditEvent.reason == failed_reason)
    failures = list(await db.scalars(query))
    if len(failures) < max_attempts:
        return None
    # 直近のmax_attempts回の失敗が、ウィンドウの中に収まっているか
    newest, oldest = failures[0], failures[-1]
    if newest - oldest >= timedelta(minutes=settings.auth_failure_window_minutes):
        return None
    return newest + timedelta(minutes=settings.auth_lock_minutes)


async def _seconds_until(db: AsyncSession, until: datetime | None) -> int | None:
    if until is None:
        return None
    seconds = math.ceil((until - await current_time(db)).total_seconds())
    return seconds if seconds > 0 else None
