"""削除済みのsession(tombstone)等の長周期パージ。workerが定期実行する。

tombstoneは、他の端末が差分取得で削除を受け取れるよう、削除してからパージ期間(既定90日)は残しておく。
パージ期間を過ぎたものを物理削除する(track_pointsはsessionsのON DELETE CASCADEで一緒に消える)。
"""

from datetime import timedelta

from sqlalchemy import delete, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AuditEvent, AuthSession, OutboxEmail, RefreshToken, TrackingSession
from app.models.outbox_email import OUTBOX_CANCELLED, OUTBOX_FAILED, OUTBOX_SENT


async def purge_expired_tombstones(db: AsyncSession, retention_days: int) -> int:
    """deleted_at(削除した日時)がパージ期間より古いtombstoneを物理削除し、削除した件数を返す。"""
    result = await db.execute(
        delete(TrackingSession).where(
            TrackingSession.deleted_at.is_not(None),
            TrackingSession.deleted_at < func.clock_timestamp() - timedelta(days=retention_days),
        )
    )
    await db.commit()
    return result.rowcount


async def purge_expired_auth(db: AsyncSession, refresh_token_ttl_days: int) -> tuple[int, int]:
    """期限切れのリフレッシュトークンと、無効にしてから一定期間経った端末のログイン状態を物理削除する。

    使用済みのリフレッシュトークンは再使用の検知のために残しているが、期限が切れたものはそれ以降の検知が不要なので消す。
    無効にしたログイン状態は、そのトークンの有効期限(refresh_token_ttl_days)が過ぎたら消す(トークンもCASCADEで消える)。
    (削除したリフレッシュトークンの件数, 削除したログイン状態の件数)を返す。
    """
    now = func.clock_timestamp()
    tokens = await db.execute(delete(RefreshToken).where(RefreshToken.expires_at < now))
    sessions = await db.execute(
        delete(AuthSession).where(
            AuthSession.revoked_at.is_not(None),
            AuthSession.revoked_at < now - timedelta(days=refresh_token_ttl_days),
        )
    )
    await db.commit()
    return tokens.rowcount, sessions.rowcount


async def purge_old_outbox_emails(db: AsyncSession, retention_days: int) -> int:
    """送信済み・諦めた・取り消したメールの記録のうち、積んでから保持期間(既定90日)を過ぎたものを物理削除し、削除した件数を返す。

    送信待ちの行は消さない。
    """
    result = await db.execute(
        delete(OutboxEmail).where(
            OutboxEmail.status.in_([OUTBOX_SENT, OUTBOX_FAILED, OUTBOX_CANCELLED]),
            OutboxEmail.created_at < func.clock_timestamp() - timedelta(days=retention_days),
        )
    )
    await db.commit()
    return result.rowcount


async def purge_old_audit_events(db: AsyncSession, retention_days: int) -> int:
    """記録してから保持期間(既定90日)を過ぎた監査ログを物理削除し、削除した件数を返す。"""
    result = await db.execute(
        delete(AuditEvent).where(
            AuditEvent.occurred_at < func.clock_timestamp() - timedelta(days=retention_days)
        )
    )
    await db.commit()
    return result.rowcount
