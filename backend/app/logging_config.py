"""ログの出力の設定(api・worker共通)。

設計はbackend/docs/バックエンド構成.mdの「ログ」。Python標準のloggingに、整形(Formatter)を2種類足しただけのもの。
- 出力先は標準出力(Dockerのログとして見る。`docker compose logs api`)
- 形式は`LOG_FORMAT`で切り替える。text(既定): `時刻 レベル ロガー名 メッセージ key=value ...`、json: 1行1つのJSON
- ログを出す側は、項目を`extra`で渡す(例: `logger.info("purged", extra={"tombstones": 3})`)。リクエストの中なら
  リクエストIDとuser_idは自動で付く(extraで渡さない)
- パスワード・トークン・確認コード・メール本文・位置情報・メールアドレスはログに出さない(IDと件数を出す)
"""

import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

from app import request_context

# LogRecordが元から持っている属性。これ以外の属性をextraで渡された項目として出す
_STANDARD_ATTRS = set(vars(logging.LogRecord("", 0, "", 0, "", None, None))) | {
    "message",
    "asctime",
    "taskName",
}
# 先頭に並べる項目(他のログとの突き合わせに使う)
_LEADING_FIELDS = ("request_id", "user_id")


_base_record_factory = logging.getLogRecordFactory()


def _record_factory(*args: Any, **kwargs: Any) -> logging.LogRecord:
    """ログを出した時点でリクエストの中なら、リクエストIDとuser_idを付ける(どのハンドラーで出しても付くように、
    ハンドラーのフィルターではなくLogRecordを作るところで付ける)。そのため、この2つはextraで渡さない。"""
    record = _base_record_factory(*args, **kwargs)
    context = request_context.current()
    if context is not None:
        record.request_id = context.request_id
        record.user_id = context.user_id
    return record


def _fields(record: logging.LogRecord) -> dict[str, Any]:
    """extraで渡された項目(値がNoneのものは省く)。リクエストIDとuser_idを先頭にする。"""
    extra = {
        key: value
        for key, value in vars(record).items()
        if key not in _STANDARD_ATTRS and value is not None
    }
    leading = {key: extra.pop(key) for key in _LEADING_FIELDS if key in extra}
    return {**leading, **extra}


def _timestamp(record: logging.LogRecord) -> str:
    return datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def _text_value(value: Any) -> str:
    """key=valueの値。空白・引用符・=を含むものは引用符で囲む(1行のまま項目を切り出せるように)。"""
    text = str(value)
    if text == "" or any(c in text for c in ' "=\n'):
        return json.dumps(text, ensure_ascii=False)
    return text


class TextFormatter(logging.Formatter):
    """`2026-10-23T05:05:12.345Z INFO app.access request request_id=... status=200 duration_ms=12.3`の形。"""

    def format(self, record: logging.LogRecord) -> str:
        line = f"{_timestamp(record)} {record.levelname} {record.name} {record.getMessage()}"
        fields = _fields(record)
        if fields:
            line += " " + " ".join(f"{key}={_text_value(value)}" for key, value in fields.items())
        if record.exc_info:
            # スタックトレースは複数行になる(テキストの形式では読みやすさを優先する)
            line += "\n" + self.formatException(record.exc_info)
        return line


class JsonFormatter(logging.Formatter):
    """1行1つのJSON。ログを集める基盤(CloudWatch Logs等)で項目ごとに検索・集計できる。"""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "time": _timestamp(record),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            **_fields(record),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False, default=str)


def configure_logging(log_format: str, log_level: str) -> None:
    """ルートのロガーに標準出力のハンドラーを1つだけ付け、uvicornのログも同じ形式で出す。"""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter() if log_format == "json" else TextFormatter())
    logging.setLogRecordFactory(_record_factory)
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(log_level.upper())

    # uvicornは自分のハンドラーで出すので外し、ルートに流して同じ形式にする
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uvicorn_logger = logging.getLogger(name)
        uvicorn_logger.handlers.clear()
        uvicorn_logger.propagate = True
    # uvicorn標準のアクセスログは、app.access(app/request_context.py)に置き換える
    logging.getLogger("uvicorn.access").disabled = True
