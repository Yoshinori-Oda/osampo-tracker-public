from typing import Literal

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import URL


class Settings(BaseSettings):
    """環境変数(backend/.env)から読み込む設定。

    フィールド名は大文字小文字を区別せずに環境変数と対応する(例: postgres_db <- POSTGRES_DB)。
    """

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    postgres_host: str = "db"
    postgres_port: int = 5432
    # 開発用のデータベース(api・workerが使う)
    postgres_db: str
    # pytest専用のデータベース
    postgres_test_db: str = "location_db_test"

    # api用のロール(データの読み書きのみ。sessions・track_pointsはRLSで本人の行だけ)。workerには渡さない
    app_db_user: str | None = None
    app_db_password: SecretStr | None = None
    # worker用のロール(ジョブで使うテーブル・操作だけ)。apiでは、マイグレーション(ポリシーの対象のロール名)とpytestで使う
    worker_db_user: str | None = None
    worker_db_password: SecretStr | None = None
    # マイグレーション(Alembic)用のロール(テーブルの作成・変更ができる)。workerには渡さない
    migrator_db_user: str | None = None
    migrator_db_password: SecretStr | None = None

    # ログ(api・worker)。形式はtext(key=value。既定)かjson(1行1つのJSON)、レベルはDEBUG・INFO・WARNING・ERROR
    log_format: Literal["text", "json"] = "text"
    log_level: str = "INFO"

    # リクエストのbodyのサイズの上限(uvicorn・FastAPIには既定の上限が無いため)。超えると413を返す
    max_request_body_bytes: int = 10 * 1024 * 1024

    # tombstoneのパージ(worker)。パージ期間はGETのrequest_existence_checkの判定でも参照する
    purge_retention_days: int = 90
    purge_interval_hours: int = 24

    # 認証。ES256の鍵のペア(PEM)はbackend/secrets/に置き、apiにだけマウントする(コミットしない)
    jwt_private_key_path: str = "/app/secrets/jwt_private.pem"
    jwt_public_key_path: str = "/app/secrets/jwt_public.pem"
    access_token_ttl_minutes: int = 15
    # リフレッシュトークンの有効期限。無効にした端末のログイン状態をパージするまでの期間にも使う
    refresh_token_ttl_days: int = 30

    # メール送信。apiはoutboxに積むだけなので、SMTPの設定を使うのはworkerだけ。既定はcomposeの中のMailpit
    smtp_host: str = "mailpit"
    smtp_port: int = 1025
    smtp_username: str | None = None
    smtp_password: SecretStr | None = None
    smtp_starttls: bool = False
    smtp_timeout_seconds: int = 10
    mail_from: str = "osampo-tracker <no-reply@osampo-tracker.local>"
    # outboxを確認する間隔、1通あたりの試行回数の上限、送信済み・諦めた行を残す日数
    mail_poll_interval_seconds: int = 5
    mail_max_attempts: int = 5
    outbox_retention_days: int = 90
    # ログインと、現在のパスワードによる再確認(パスワードの変更)の試行回数の制限。2つは別に数え、同じ値を使う。
    # 直近の成功より後の失敗が、ウィンドウ(分)以内に上限の回数たまったら、最後の失敗からロックする(分)
    auth_max_failed_attempts: int = 10
    auth_failure_window_minutes: int = 15
    auth_lock_minutes: int = 15

    # 監査ログ(audit_events)を残す日数。アカウントの削除の記録も含めて、これを過ぎたら消す
    audit_event_retention_days: int = 90

    # メールアドレスの確認コード(6桁): 有効期限、1つのコードで間違えてよい回数、再送の間隔、24時間あたりの送信回数の上限
    email_code_ttl_minutes: int = 10
    email_code_max_failed_attempts: int = 5
    email_code_resend_interval_seconds: int = 60
    email_code_daily_limit: int = 5

    @property
    def app_database_url(self) -> URL:
        return self._database_url(self.app_db_user, self.app_db_password, self.postgres_db, "APP_DB")

    @property
    def worker_database_url(self) -> URL:
        return self._database_url(
            self.worker_db_user, self.worker_db_password, self.postgres_db, "WORKER_DB"
        )

    def migrator_database_url(self, database: str) -> URL:
        return self._database_url(
            self.migrator_db_user, self.migrator_db_password, database, "MIGRATOR_DB"
        )

    def _database_url(
        self, user: str | None, password: SecretStr | None, database: str, env_prefix: str
    ) -> URL:
        if user is None or password is None:
            raise RuntimeError(f"{env_prefix}_USER / {env_prefix}_PASSWORD が設定されていません")
        return URL.create(
            "postgresql+psycopg",
            username=user,
            password=password.get_secret_value(),
            host=self.postgres_host,
            port=self.postgres_port,
            database=database,
        )


settings = Settings()
