"""監査ログ(audit_events)への記録。

設計はbackend/docs/バックエンド構成.mdの「監査ログ」。記録は呼び出し元の業務の処理と同じトランザクションに入れ、
commitは呼び出し元が行う。エラーで終わる処理(ログインの失敗等)は、記録をcommitしてからエラーを投げる
(投げた後はロールバックされるため)。
"""

import uuid

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AuditEvent
from app.models.audit_event import EVENT_ACCOUNT_DELETED
from app.request_context import client_ip, request_id


def record(
    db: AsyncSession,
    event_type: str,
    *,
    user_id: uuid.UUID | None = None,
    email: str | None = None,
    device_id: uuid.UUID | None = None,
    target_user_id: uuid.UUID | None = None,
    reason: str | None = None,
) -> None:
    """出来事を1件記録する(セッションに加えるだけで、commitしない)。送信元のIPとリクエストIDは今のリクエストから取る。"""
    db.add(
        AuditEvent(
            event_type=event_type,
            reason=reason,
            user_id=user_id,
            email=email.lower() if email is not None else None,
            device_id=device_id,
            ip=client_ip(),
            target_user_id=target_user_id,
            request_id=request_id(),
        )
    )


async def record_account_deleted(db: AsyncSession, user_id: uuid.UUID) -> None:
    """アカウントの削除に合わせて、そのユーザーの記録を消し、削除の記録(日時とuser_idだけ)を残す(commitしない)。

    関連データを全て消す方針に合わせて、メールアドレス・IP・端末IDは残さない。削除の記録は、運営側が削除を実行したことを
    示したり、他のログ(user_idが残る)と突き合わせたりするためのもの。
    """
    await db.execute(delete(AuditEvent).where(AuditEvent.user_id == user_id))
    db.add(AuditEvent(event_type=EVENT_ACCOUNT_DELETED, user_id=user_id))
