import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Identity, Index, String, text
from sqlalchemy.dialects.postgresql import INET, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base

# 出来事の種類。追加してもマイグレーションは要らない(CHECK制約を付けていない)。
# 一覧と記録する項目はbackend/docs/バックエンド構成.mdの「監査ログ」
EVENT_SIGNUP = "signup"
EVENT_LOGIN_SUCCEEDED = "login_succeeded"
EVENT_LOGIN_FAILED = "login_failed"  # reasonにinvalid_credentials・account_disabled
EVENT_LOGIN_LOCKED = "login_locked"  # 試行回数の上限でロック中のため、照合せずに拒否した(失敗には数えない)
EVENT_LOGOUT = "logout"
EVENT_REFRESH_TOKEN_REUSED = "refresh_token_reused"  # 使用済みのリフレッシュトークンの再使用(盗まれた疑い)
EVENT_PASSWORD_CHANGED = "password_changed"
EVENT_PASSWORD_CHANGE_FAILED = "password_change_failed"  # 現在のパスワードの間違い
EVENT_PASSWORD_CHANGE_LOCKED = "password_change_locked"  # 試行回数の上限でロック中のため、照合せずに拒否した
EVENT_EMAIL_VERIFIED = "email_verified"
EVENT_ACCOUNT_DELETED = "account_deleted"  # 日時とuser_idだけを残す
EVENT_ACCOUNT_DISABLED = "account_disabled"  # 管理用のコマンドでの停止
EVENT_ACCOUNT_ENABLED = "account_enabled"  # 管理用のコマンドでの解除
EVENT_ACCESS_DENIED = "access_denied"  # 他人のデータへのアクセス(403 forbidden)。target_user_idに対象
EVENT_ADMIN_USER_ACCESS = "admin_user_access"  # 管理者による他のユーザーのデータへのアクセス


class AuditEvent(Base):
    """監査ログ: 認証・アカウント・権限の出来事(誰が・何を・いつ・どこから)を1件1行で残す。

    正常な流れでも頻繁に起きるもの(アクセストークンの期限切れ・メールアドレスが未確認の403等)は残さない
    (全てのリクエストの記録はアクセスログの役割)。追記のみで、更新しない。
    user_idには外部キーを付けない(アカウントの削除の記録を、ユーザーを消した後も残すため)。アカウントを削除したときは、
    そのユーザーの記録をサービスの処理で消してから削除の記録を書く。
    設計はbackend/docs/バックエンド構成.mdの「監査ログ」。
    """

    __tablename__ = "audit_events"
    __table_args__ = (
        Index("idx_audit_events_user_id", "user_id", "occurred_at"),
        # 入力されたメールアドレスでの検索(ログインの試行回数の判定にも使う)
        Index("idx_audit_events_email", "email", "occurred_at"),
        # パージ用
        Index("idx_audit_events_occurred_at", "occurred_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    # トランザクションの開始時刻ではなく、記録した時刻
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("clock_timestamp()")
    )
    event_type: Mapped[str] = mapped_column(String(50))
    # 出来事の補足(ログインの失敗の理由等)
    reason: Mapped[str | None] = mapped_column(String(50))
    # 出来事の主体のユーザー(ログインの失敗で該当するユーザーがいなければnull)
    user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    # 入力されたメールアドレス(小文字にそろえる)。存在しないアドレスでのログインの失敗も残す
    email: Mapped[str | None] = mapped_column(String(255))
    device_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    # リクエストの送信元。リバースプロキシを置いたら、その設定に合わせて取り方を見直す
    ip: Mapped[str | None] = mapped_column(INET)
    # 操作の対象のユーザー(他人のデータへのアクセス等)
    target_user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    # リクエストID(同じリクエストのアクセスログ・アプリのログをたどるため。管理用のコマンドからの操作ではnull)
    request_id: Mapped[str | None] = mapped_column(String(64))
