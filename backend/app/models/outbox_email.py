import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, Integer, String, Text, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base

OUTBOX_PENDING = "pending"  # 送信待ち(失敗して再送を待っているものを含む)
OUTBOX_SENT = "sent"  # 送信済み(SMTPサーバーが受け取った。相手に届いたことまでは分からない)
OUTBOX_FAILED = "failed"  # 諦めた(恒久的な失敗、試行回数の上限、または送信期限切れ)
OUTBOX_CANCELLED = "cancelled"  # 送る必要が無くなった(確認コードの再送で古いコードのメールを取り消した等)


class OutboxEmail(Base):
    """送信待ちのメール(outbox)と、送信の記録。

    apiは業務のデータと同じトランザクションでここに積むだけで、送信はworkerが行う。送信に成功したら本文を消し
    (確認コードが平文で入るため)、「いつ・誰に・何を・どうなったか」の記録として残す。失敗の理由はworkerのログに出す。
    設計はbackend/docs/バックエンド構成.mdの「メール送信の基盤」。
    """

    __tablename__ = "outbox_emails"
    __table_args__ = (
        CheckConstraint(
            "status IN ('pending', 'sent', 'failed', 'cancelled')",
            name="outbox_emails_status_check",
        ),
        # workerが送信待ちの行を探す用
        Index(
            "idx_outbox_emails_next_attempt_at",
            "next_attempt_at",
            postgresql_where=text("status = 'pending'"),
        ),
        Index("idx_outbox_emails_recipient_user_id", "recipient_user_id"),
        # パージ用
        Index("idx_outbox_emails_created_at", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    # 宛先のユーザー(差出人はアプリ共通のMAIL_FROMなので行ごとには持たない)。アカウントの削除で一緒に消える。
    # ユーザーに紐づかないメールのためにnullを許す
    recipient_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE", name="outbox_emails_recipient_user_id_fkey"),
    )
    # 積んだ時点の宛先。users.emailから引かない(メールアドレスの変更で新旧のアドレスに送る・送った記録を残すため)
    to_address: Mapped[str] = mapped_column(String(255))
    subject: Mapped[str] = mapped_column(String(200))
    # 本文(テキストのみ)。送信に成功したらnullにする
    body: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(20), server_default=text("'pending'"))
    # 送信を試みた回数と、次に試みる日時(一時的な失敗のたびに間隔を倍にする)
    attempts: Mapped[int] = mapped_column(Integer, server_default=text("0"))
    next_attempt_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )
    # 送信済みになった日時、または諦めた・取り消した日時。pendingならnull
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # この日時を過ぎたら送らない(確認コードのメールではコードの有効期限)。nullなら期限なし
    send_deadline: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("CURRENT_TIMESTAMP")
    )
