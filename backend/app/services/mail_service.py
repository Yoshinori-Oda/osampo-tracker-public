"""メールのoutbox: apiが送るメールを積み、workerが取り出して送る。

設計はbackend/docs/バックエンド構成.mdの「メール送信の基盤」。時刻はDBのclock_timestamp()を正とする。
送信は「少なくとも1回」: SMTPサーバーが受け取った後、結果をcommitする前にworkerが落ちると、次の起動で同じメールをもう一度送る。
"""

import logging
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from email.message import EmailMessage

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.mail import PermanentMailError, TemporaryMailError, build_message
from app.models import OutboxEmail
from app.models.outbox_email import (
    OUTBOX_CANCELLED,
    OUTBOX_FAILED,
    OUTBOX_PENDING,
    OUTBOX_SENT,
)
from app.services.session_service import current_time

logger = logging.getLogger(__name__)

# メールを送る関数。テストではSMTPに接続しないものに差し替える
SendFunc = Callable[[EmailMessage], Awaitable[None]]

# 1回のジョブで送る上限(送信待ちが溜まっていても、次の実行に回して1回の実行を長引かせない)
BATCH_SIZE = 20


async def enqueue_email(
    db: AsyncSession,
    *,
    to_address: str,
    subject: str,
    body: str,
    recipient_user_id: uuid.UUID | None = None,
    send_deadline: datetime | None = None,
) -> OutboxEmail:
    """送るメールをoutboxに積む。commitは呼び出し元が業務のデータと一緒に行う(同じトランザクションで確定させるため)。

    send_deadlineを渡すと、その日時を過ぎても送れていなければ送らずに諦める(確認コードの有効期限など)。
    """
    now = await current_time(db)
    # server_defaultに任せると、flush後に値を読むときに暗黙のSELECTが起きる(非同期ではエラー)ので、値を明示する
    email = OutboxEmail(
        recipient_user_id=recipient_user_id,
        to_address=to_address,
        subject=subject,
        body=body,
        status=OUTBOX_PENDING,
        attempts=0,
        next_attempt_at=now,
        send_deadline=send_deadline,
        created_at=now,
    )
    db.add(email)
    await db.flush()
    return email


async def cancel_pending_email(db: AsyncSession, email_id: uuid.UUID) -> bool:
    """まだ送っていないメールを取り消す(commitは呼び出し元)。取り消したらTrue、送信済み等で取り消せなければFalseを返す。

    workerが送信中の行はロックされているので、送信の結果がcommitされるまで待ち、送信済みなら何もしない。
    """
    # 時刻はSQLの関数ではなく値で渡す(関数だと、手元のオブジェクトの属性が期限切れになり、読むときに暗黙のSELECTが起きるため)
    now = await current_time(db)
    result = await db.execute(
        update(OutboxEmail)
        .where(OutboxEmail.id == email_id, OutboxEmail.status == OUTBOX_PENDING)
        .values(status=OUTBOX_CANCELLED, completed_at=now)
    )
    return result.rowcount > 0


def retry_delay(attempts: int) -> timedelta:
    """attempts回目の試行が一時的に失敗した後、次に試みるまでの間隔(1分、2分、4分、8分…と倍にする)。"""
    return timedelta(minutes=2 ** (attempts - 1))


@dataclass(frozen=True)
class SendResult:
    sent: int = 0
    retrying: int = 0
    failed: int = 0

    @property
    def processed(self) -> int:
        return self.sent + self.retrying + self.failed


async def send_pending_emails(
    db: AsyncSession, send: SendFunc, *, max_attempts: int, batch_size: int = BATCH_SIZE
) -> SendResult:
    """送る時刻が来た送信待ちのメールを、1通ずつ送って結果を記録する(最大batch_size通)。

    1通ごとに行をロックして取り出し(SKIP LOCKED: 他のworkerが処理中の行は飛ばす)、送信の結果を書いてcommitする。
    """
    sent = retrying = failed = 0
    for _ in range(batch_size):
        email = await db.scalar(
            select(OutboxEmail)
            .where(
                OutboxEmail.status == OUTBOX_PENDING,
                OutboxEmail.next_attempt_at <= func.clock_timestamp(),
            )
            .order_by(OutboxEmail.next_attempt_at)
            .limit(1)
            .with_for_update(skip_locked=True)
        )
        if email is None:
            break

        now = await current_time(db)
        if email.send_deadline is not None and email.send_deadline <= now:
            # 送信が遅れて期限を過ぎた(確認コードなら、届いても使えない)。送らずに諦める
            email.status = OUTBOX_FAILED
            email.completed_at = now
            logger.error("outbox email %s: gave up because the send deadline has passed", email.id)
            failed += 1
            await db.commit()
            continue

        email.attempts += 1
        try:
            await send(build_message(email.to_address, email.subject, email.body or ""))
        except PermanentMailError as exc:
            await _give_up(db, email, exc)
            failed += 1
        except TemporaryMailError as exc:
            if await _retry_or_give_up(db, email, exc, max_attempts):
                retrying += 1
            else:
                failed += 1
        except Exception as exc:
            # 想定外の例外(バグ等)。スタックトレースを残し、一時的な失敗と同じく再送の対象にする
            # (ここで止めると、同じ行を5秒ごとに取り出しては落ちる状態になるため)
            logger.exception("outbox email %s: unexpected error while sending", email.id)
            if await _retry_or_give_up(db, email, exc, max_attempts):
                retrying += 1
            else:
                failed += 1
        else:
            email.status = OUTBOX_SENT
            email.completed_at = await current_time(db)
            # 確認コードが平文で入るので、送ったら本文を消す
            email.body = None
            logger.info("outbox email %s: sent (attempt %d)", email.id, email.attempts)
            sent += 1
        await db.commit()
    return SendResult(sent=sent, retrying=retrying, failed=failed)


async def _retry_or_give_up(
    db: AsyncSession, email: OutboxEmail, exc: Exception, max_attempts: int
) -> bool:
    """一時的な失敗の後、試行回数の上限に達していなければ次の試行を予約してTrueを返す。達していれば諦めてFalseを返す。"""
    if email.attempts >= max_attempts:
        await _give_up(db, email, exc)
        return False
    email.next_attempt_at = await current_time(db) + retry_delay(email.attempts)
    logger.warning(
        "outbox email %s: temporary failure (attempt %d/%d), retry at %s: %s",
        email.id,
        email.attempts,
        max_attempts,
        email.next_attempt_at.isoformat(),
        exc,
    )
    return True


async def _give_up(db: AsyncSession, email: OutboxEmail, exc: Exception) -> None:
    email.status = OUTBOX_FAILED
    email.completed_at = await current_time(db)
    # 宛先のアドレスはログに出さず、行のidで追う
    logger.error("outbox email %s: gave up after %d attempt(s): %s", email.id, email.attempts, exc)
