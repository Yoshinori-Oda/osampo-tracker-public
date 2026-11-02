import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, Integer, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base

# 確認コードの用途。パスワードリセット・メールアドレスの変更(11月以降)を作るときに追加する
PURPOSE_VERIFY_EMAIL = "verify_email"

CODE_PENDING = "pending"  # 入力待ち(期限切れかどうかはexpires_atで判定する)
CODE_USED = "used"  # 確認に成功した
CODE_LOCKED = "locked"  # 入力の失敗の上限に達した(再送で新しいコードを受け取る)


class EmailCode(Base):
    """メールで送る確認コード。ユーザーと用途ごとに1行を持ち、送るたびに上書きする。

    コードそのものは保存せず、argon2のハッシュだけを持つ。入力の失敗の回数・送信の回数はリクエストをまたいで数えるのでここに持つ。
    設計はbackend/docs/バックエンド構成.mdの「メールアドレスの確認コード」。
    """

    __tablename__ = "email_codes"
    __table_args__ = (
        CheckConstraint("purpose IN ('verify_email')", name="email_codes_purpose_check"),
        CheckConstraint(
            "status IN ('pending', 'used', 'locked')", name="email_codes_status_check"
        ),
        # outboxの行のパージ(ON DELETE SET NULL)用
        Index("idx_email_codes_outbox_email_id", "outbox_email_id"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE", name="email_codes_user_id_fkey"),
        primary_key=True,
    )
    purpose: Mapped[str] = mapped_column(String(30), primary_key=True)
    # 今のコードのハッシュと有効期限。確認に成功した・失敗の上限に達したらnull
    code_hash: Mapped[str | None] = mapped_column(String(255))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # 期限切れは状態として保存しない(時間が経つだけで起き、その瞬間に処理が走らないため)
    status: Mapped[str] = mapped_column(String(20))
    # 今のコードで間違えた回数。送るたびに0に戻す
    failed_attempts: Mapped[int] = mapped_column(Integer)
    # 最後に送った日時(再送の間隔の判定)
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # 数え始めからの送信回数と、その数え始め(24時間あたりの上限の判定。24時間経った後の最初の送信で数え直す)
    send_count: Mapped[int] = mapped_column(Integer)
    send_window_started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # 今のコードを送ったoutboxの行。再送のとき、まだ送られていなければ取り消す。outboxの行がパージされたらnull
    outbox_email_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(
            "outbox_emails.id", ondelete="SET NULL", name="email_codes_outbox_email_id_fkey"
        ),
    )
