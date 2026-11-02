"""SMTPでのメールの送信と、失敗の振り分け(恒久的/一時的)。workerだけが使う。

DBには触れない(outboxの業務ルールはapp/services/mail_service.py)。設計はbackend/docs/バックエンド構成.mdの「メール送信の基盤」。
"""

import asyncio
import smtplib
from email.message import EmailMessage
from email.utils import formatdate, make_msgid, parseaddr

from app.config import settings


class MailError(Exception):
    """メールの送信の失敗。"""


class PermanentMailError(MailError):
    """何度送っても結果が変わらない失敗(宛先の拒否など)。再送せずにすぐ諦める。"""


class TemporaryMailError(MailError):
    """時間をおけば成功しうる失敗(接続できない・タイムアウト・4xxの応答など)。間隔をあけて再送する。"""


def build_message(to_address: str, subject: str, body: str) -> EmailMessage:
    """送るメールを組み立てる。本文はUTF-8のテキストのみ。"""
    message = EmailMessage()
    message["From"] = settings.mail_from
    message["To"] = to_address
    message["Subject"] = subject
    message["Date"] = formatdate(usegmt=True)
    # Message-IDは送信のたびに作る。右側は差出人のドメインにする(省略するとコンテナのホスト名になる)
    from_domain = parseaddr(settings.mail_from)[1].rpartition("@")[2] or None
    message["Message-ID"] = make_msgid(domain=from_domain)
    message.set_content(body)
    return message


def classify_smtp_error(exc: Exception) -> MailError:
    """SMTPの送信で起きた例外を、恒久的な失敗か一時的な失敗かに振り分ける。

    恒久的とみなすのは、宛先や本文がSMTPサーバーに5xxで拒否された場合だけ。認証の失敗・差出人の拒否も5xxだが、
    これはメールごとの問題ではなく設定の誤り(全てのメールに共通)なので、1通ずつ諦めずに一時的な失敗として再送し、
    ログで気づけるようにする。
    """
    if isinstance(exc, smtplib.SMTPRecipientsRefused):
        # 宛先ごとの(コード, メッセージ)。宛先は1つだけ送るので、その応答で判断する
        codes = [code for code, _ in exc.recipients.values()]
        if codes and all(500 <= code < 600 for code in codes):
            return PermanentMailError(f"recipient refused: {codes}")
        return TemporaryMailError(f"recipient refused temporarily: {codes}")
    if isinstance(exc, smtplib.SMTPDataError) and 500 <= exc.smtp_code < 600:
        return PermanentMailError(f"message rejected: {exc.smtp_code} {exc.smtp_error!r}")
    if isinstance(exc, smtplib.SMTPResponseException):
        return TemporaryMailError(f"smtp error: {exc.smtp_code} {exc.smtp_error!r}")
    # 接続できない・タイムアウト・接続が切れた(OSError、SMTPServerDisconnected等)
    return TemporaryMailError(f"{type(exc).__name__}: {exc}")


def _send_sync(message: EmailMessage) -> None:
    with smtplib.SMTP(
        settings.smtp_host, settings.smtp_port, timeout=settings.smtp_timeout_seconds
    ) as smtp:
        if settings.smtp_starttls:
            smtp.starttls()
        if settings.smtp_username and settings.smtp_password:
            smtp.login(settings.smtp_username, settings.smtp_password.get_secret_value())
        smtp.send_message(message)


async def send_via_smtp(message: EmailMessage) -> None:
    """SMTPでメールを送る。失敗したらPermanentMailError・TemporaryMailErrorを投げる。

    smtplibは同期のライブラリなので、別スレッドで動かしてworkerのイベントループ(他のジョブ)を止めない。
    """
    try:
        await asyncio.to_thread(_send_sync, message)
    except (smtplib.SMTPException, OSError) as exc:
        raise classify_smtp_error(exc) from exc
