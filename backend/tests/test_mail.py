"""メールの送信基盤(app/mail.py・app/services/mail_service.py)のテスト。SMTPには接続しない。

設計はbackend/docs/バックエンド構成.mdの「メール送信の基盤」。
"""

import smtplib
from datetime import timedelta
from email.message import EmailMessage

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import mail
from app.mail import PermanentMailError, TemporaryMailError, classify_smtp_error
from app.models import OutboxEmail, User
from app.models.outbox_email import OUTBOX_CANCELLED, OUTBOX_FAILED, OUTBOX_PENDING, OUTBOX_SENT
from app.services.mail_service import (
    cancel_pending_email,
    enqueue_email,
    retry_delay,
    send_pending_emails,
)
from app.services.session_service import current_time

MAX_ATTEMPTS = 5


class FakeSender:
    """SMTPの代わりに、送ろうとしたメールを記録する。errorを設定すると、送るたびにその例外を投げる。"""

    def __init__(self, error: Exception | None = None) -> None:
        self.messages: list[EmailMessage] = []
        self.error = error

    async def __call__(self, message: EmailMessage) -> None:
        if self.error is not None:
            raise self.error
        self.messages.append(message)


async def enqueue(db: AsyncSession, to_address: str = "taro@example.com", **kwargs) -> OutboxEmail:
    return await enqueue_email(
        db, to_address=to_address, subject="件名", body="本文 123456", **kwargs
    )


async def send(db: AsyncSession, sender: FakeSender):
    return await send_pending_emails(db, sender, max_attempts=MAX_ATTEMPTS)


# ---- 積む・送る ------------------------------------------------------------------------


async def test_enqueue_creates_pending_email(db_session: AsyncSession, user: User):
    email = await enqueue(db_session, recipient_user_id=user.id)

    assert email.status == OUTBOX_PENDING
    assert email.attempts == 0
    assert email.recipient_user_id == user.id
    assert email.completed_at is None
    # 積んだ時点ですぐに送る対象になる
    assert email.next_attempt_at <= await current_time(db_session)


async def test_sends_pending_email_and_clears_body(db_session: AsyncSession):
    email = await enqueue(db_session)
    sender = FakeSender()

    result = await send(db_session, sender)

    assert (result.sent, result.retrying, result.failed) == (1, 0, 0)
    [message] = sender.messages
    assert message["To"] == "taro@example.com"
    assert message["Subject"] == "件名"
    assert message["From"]
    assert message["Message-ID"]
    assert message.get_content().strip() == "本文 123456"
    assert email.status == OUTBOX_SENT
    assert email.attempts == 1
    assert email.completed_at is not None
    # 確認コードが平文で入るので、送ったら本文を消す。宛先・件名は記録として残す
    assert email.body is None
    assert email.to_address == "taro@example.com"


async def test_sends_multiple_emails_up_to_batch_size(db_session: AsyncSession):
    for i in range(3):
        await enqueue(db_session, to_address=f"user{i}@example.com")
    sender = FakeSender()

    result = await send_pending_emails(db_session, sender, max_attempts=MAX_ATTEMPTS, batch_size=2)

    assert result.sent == 2
    # 残りは次の実行で送る
    assert (await send(db_session, sender)).sent == 1
    assert len(sender.messages) == 3


async def test_does_not_send_emails_not_due_or_completed(db_session: AsyncSession):
    not_due = await enqueue(db_session)
    not_due.next_attempt_at = await current_time(db_session) + timedelta(minutes=1)
    sent = await enqueue(db_session)
    sent.status = OUTBOX_SENT
    failed = await enqueue(db_session)
    failed.status = OUTBOX_FAILED
    await db_session.flush()
    sender = FakeSender()

    result = await send(db_session, sender)

    assert result.processed == 0
    assert sender.messages == []


async def test_does_not_send_email_past_send_deadline(db_session: AsyncSession):
    email = await enqueue(db_session)
    email.send_deadline = await current_time(db_session) - timedelta(seconds=1)
    await db_session.flush()
    sender = FakeSender()

    result = await send(db_session, sender)

    # 期限を過ぎたメール(確認コードなら届いても使えない)は送らずに諦める
    assert result.failed == 1
    assert sender.messages == []
    assert email.status == OUTBOX_FAILED
    assert email.attempts == 0


async def test_cancel_pending_email(db_session: AsyncSession):
    pending = await enqueue(db_session)
    sent = await enqueue(db_session)
    sent.status = OUTBOX_SENT
    await db_session.flush()

    assert await cancel_pending_email(db_session, pending.id) is True
    # 送信済みは取り消せない
    assert await cancel_pending_email(db_session, sent.id) is False

    # UPDATE文で書いたので、手元のオブジェクトではなくDBの値を読み直して確かめる
    await db_session.refresh(pending)
    await db_session.refresh(sent)
    assert pending.status == OUTBOX_CANCELLED
    assert pending.completed_at is not None
    assert sent.status == OUTBOX_SENT
    # 取り消した行は送らない
    assert (await send(db_session, FakeSender())).processed == 0


# ---- 失敗の扱い ------------------------------------------------------------------------


def test_retry_delay_doubles():
    assert [retry_delay(n) for n in range(1, 5)] == [timedelta(minutes=m) for m in (1, 2, 4, 8)]


async def test_temporary_failure_schedules_retry_with_backoff(db_session: AsyncSession):
    email = await enqueue(db_session)
    # 既に2回失敗している(3回目の試行)
    email.attempts = 2
    await db_session.flush()

    before = await current_time(db_session)
    result = await send(db_session, FakeSender(TemporaryMailError("connection refused")))
    after = await current_time(db_session)

    assert (result.sent, result.retrying, result.failed) == (0, 1, 0)
    assert email.status == OUTBOX_PENDING
    assert email.attempts == 3
    # 3回目の失敗の後は4分あける
    assert before + timedelta(minutes=4) <= email.next_attempt_at <= after + timedelta(minutes=4)
    # 再送を待つ間は本文を残す
    assert email.body == "本文 123456"


async def test_unexpected_error_is_treated_as_temporary(db_session: AsyncSession):
    email = await enqueue(db_session)

    result = await send(db_session, FakeSender(RuntimeError("bug")))

    assert result.retrying == 1
    assert email.status == OUTBOX_PENDING


async def test_gives_up_after_max_attempts(db_session: AsyncSession):
    email = await enqueue(db_session)
    email.attempts = MAX_ATTEMPTS - 1
    await db_session.flush()

    result = await send(db_session, FakeSender(TemporaryMailError("timeout")))

    assert result.failed == 1
    assert email.status == OUTBOX_FAILED
    assert email.attempts == MAX_ATTEMPTS
    assert email.completed_at is not None


async def test_permanent_failure_gives_up_immediately(db_session: AsyncSession):
    email = await enqueue(db_session)

    result = await send(db_session, FakeSender(PermanentMailError("550 no such user")))

    assert result.failed == 1
    assert email.status == OUTBOX_FAILED
    assert email.attempts == 1


async def test_deleting_user_deletes_their_emails(db_session: AsyncSession, user: User):
    await enqueue(db_session, recipient_user_id=user.id)

    await db_session.delete(user)
    await db_session.flush()

    remaining = await db_session.scalar(
        select(func.count()).select_from(OutboxEmail).where(OutboxEmail.recipient_user_id == user.id)
    )
    assert remaining == 0


# ---- SMTPの例外の振り分け --------------------------------------------------------------


@pytest.mark.parametrize(
    ("exc", "expected"),
    [
        # 宛先・本文が5xxで拒否された: 何度送っても同じなので恒久的
        (smtplib.SMTPRecipientsRefused({"a@example.com": (550, b"no such user")}), PermanentMailError),
        (smtplib.SMTPDataError(554, b"rejected"), PermanentMailError),
        # 4xxは一時的
        (smtplib.SMTPRecipientsRefused({"a@example.com": (450, b"mailbox busy")}), TemporaryMailError),
        (smtplib.SMTPDataError(451, b"try again later"), TemporaryMailError),
        # 認証・差出人の拒否は設定の誤り(全てのメールに共通)なので、1通ずつ諦めずに再送してログで気づく
        (smtplib.SMTPAuthenticationError(535, b"bad credentials"), TemporaryMailError),
        (smtplib.SMTPSenderRefused(553, b"sender rejected", "no-reply@example.com"), TemporaryMailError),
        # 接続できない・切れた
        (ConnectionRefusedError(111, "Connection refused"), TemporaryMailError),
        (smtplib.SMTPServerDisconnected("closed"), TemporaryMailError),
        (TimeoutError("timed out"), TemporaryMailError),
    ],
)
def test_classify_smtp_error(exc: Exception, expected: type[Exception]):
    assert type(classify_smtp_error(exc)) is expected


async def test_send_via_smtp_raises_classified_error(monkeypatch: pytest.MonkeyPatch):
    def refuse(message: EmailMessage) -> None:
        raise smtplib.SMTPRecipientsRefused({"a@example.com": (550, b"no such user")})

    monkeypatch.setattr(mail, "_send_sync", refuse)

    with pytest.raises(PermanentMailError):
        await mail.send_via_smtp(mail.build_message("a@example.com", "件名", "本文"))
