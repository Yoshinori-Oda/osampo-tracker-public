"""定期実行ジョブ(パージ・メール送信)を動かすworkerプロセス。

apiと同じイメージで、起動コマンドだけを`python -m app.worker`に変えて動かす。
ジョブが重複して実行されないよう、workerは1つだけ起動する。
"""

import asyncio
import logging
from datetime import UTC, datetime

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.config import settings
from app.db import worker_session
from app.logging_config import configure_logging
from app.mail import send_via_smtp
from app.services.mail_service import send_pending_emails
from app.services.purge_service import (
    purge_expired_auth,
    purge_expired_tombstones,
    purge_old_audit_events,
    purge_old_outbox_emails,
)

logger = logging.getLogger(__name__)


async def purge_job() -> None:
    """パージ期間を過ぎたtombstoneと、期限切れのリフレッシュトークン・無効にした端末のログイン状態、
    保持期間を過ぎたメールの送信の記録・監査ログを物理削除する。

    失敗してもworkerは止めず、次の実行で再び試みる。
    """
    try:
        async with worker_session() as db:
            purged = await purge_expired_tombstones(db, settings.purge_retention_days)
            tokens, auth_sessions = await purge_expired_auth(db, settings.refresh_token_ttl_days)
            emails = await purge_old_outbox_emails(db, settings.outbox_retention_days)
            audit_events = await purge_old_audit_events(db, settings.audit_event_retention_days)
        logger.info(
            "purged",
            extra={
                "tombstones": purged,
                "refresh_tokens": tokens,
                "auth_sessions": auth_sessions,
                "outbox_emails": emails,
                "audit_events": audit_events,
            },
        )
    except Exception:
        logger.exception("failed to purge")


async def send_mail_job() -> None:
    """outboxの送信待ちのメールを送る。失敗してもworkerは止めず、次の実行で再び試みる。"""
    try:
        async with worker_session() as db:
            result = await send_pending_emails(
                db, send_via_smtp, max_attempts=settings.mail_max_attempts
            )
        if result.processed:
            logger.info(
                "outbox processed",
                extra={"sent": result.sent, "retrying": result.retrying, "failed": result.failed},
            )
    except Exception:
        logger.exception("failed to send emails")


async def main() -> None:
    configure_logging(settings.log_format, settings.log_level)
    # APSchedulerはジョブを実行するたびにINFOのログを出す。メールの送信は5秒ごとなので、WARNING以上だけにする
    logging.getLogger("apscheduler").setLevel(logging.WARNING)

    scheduler = AsyncIOScheduler()
    scheduler.add_job(
        purge_job,
        "interval",
        hours=settings.purge_interval_hours,
        # 起動直後に1回実行し、以降はpurge_interval_hoursごとに実行する
        next_run_time=datetime.now(UTC),
        # 前回の実行が終わっていなければ重ねて実行しない。止まっていた間の実行分はまとめて1回にする
        max_instances=1,
        coalesce=True,
        id="purge_expired_tombstones",
    )
    scheduler.add_job(
        send_mail_job,
        "interval",
        seconds=settings.mail_poll_interval_seconds,
        next_run_time=datetime.now(UTC),
        max_instances=1,
        coalesce=True,
        id="send_outbox_emails",
    )
    scheduler.start()
    logger.info(
        "worker started (purge: every %d hour(s), retention %d day(s); mail: every %d second(s) via %s:%d)",
        settings.purge_interval_hours,
        settings.purge_retention_days,
        settings.mail_poll_interval_seconds,
        settings.smtp_host,
        settings.smtp_port,
    )

    # スケジューラーはイベントループ上で動くので、プロセスを終了させずに待ち続ける
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
