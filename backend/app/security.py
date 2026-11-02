"""パスワードのハッシュとトークン(アクセストークン=JWT・リフレッシュトークン)の生成・検証。

DBには触れない(DBが絡む認証の業務ルールはapp/services/auth_service.py)。
"""

import hashlib
import secrets
import uuid
from datetime import UTC, datetime, timedelta
from functools import cache
from pathlib import Path
from typing import Any

import jwt
from pwdlib import PasswordHash

from app.config import settings

# ---- パスワード -----------------------------------------------------------------

# pwdlibの推奨設定(argon2)
_password_hash = PasswordHash.recommended()


def hash_password(password: str) -> str:
    return _password_hash.hash(password)


@cache
def _dummy_hash() -> str:
    return _password_hash.hash("dummy-password-to-equalize-timing")


def verify_password(password: str, hashed: str | None) -> bool:
    """パスワードを検証する。ハッシュが無い(ユーザーが無い・パスワード未設定)場合もダミーのハッシュで検証して、
    応答時間からユーザーの有無を推測できないようにする。"""
    if hashed is None:
        _password_hash.verify(password, _dummy_hash())
        return False
    return _password_hash.verify(password, hashed)


# ---- メールアドレスの確認コード ------------------------------------------------------


def new_verification_code() -> str:
    """6桁の数字の確認コード(先頭の0を含む)。推測されないよう、暗号論的な乱数(secrets)で作る。"""
    return f"{secrets.randbelow(10**6):06d}"


def hash_verification_code(code: str) -> str:
    """確認コードをパスワードと同じargon2でハッシュにする。6桁は総当たりできるので、守りの本体は有効期限と失敗の上限。"""
    return _password_hash.hash(code)


def verify_verification_code(code: str, hashed: str) -> bool:
    return _password_hash.verify(code, hashed)


# ---- アクセストークン(JWT) --------------------------------------------------------

JWT_ALGORITHM = "ES256"
ACCESS_TOKEN_TYPE = "access"


class AccessTokenExpired(Exception):
    """署名は正しいが有効期限が切れている(クライアントはリフレッシュトークンで更新する)。"""


class AccessTokenInvalid(Exception):
    """署名が不正・形式が不正など(クライアントは再ログインする)。"""


@cache
def _private_key() -> str:
    return Path(settings.jwt_private_key_path).read_text()


@cache
def _public_key() -> str:
    return Path(settings.jwt_public_key_path).read_text()


def access_token_ttl() -> timedelta:
    return timedelta(minutes=settings.access_token_ttl_minutes)


def create_access_token(
    user_id: uuid.UUID, auth_session_id: uuid.UUID, now: datetime | None = None
) -> str:
    """ES256で署名したアクセストークンを作る。ロールは入れない(リクエストのたびにDBから読む)。"""
    issued_at = now or datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "sid": str(auth_session_id),
        "type": ACCESS_TOKEN_TYPE,
        "iat": issued_at,
        "exp": issued_at + access_token_ttl(),
    }
    return jwt.encode(payload, _private_key(), algorithm=JWT_ALGORITHM)


def decode_access_token(token: str) -> dict[str, Any]:
    try:
        payload = jwt.decode(
            token,
            _public_key(),
            algorithms=[JWT_ALGORITHM],
            options={"require": ["sub", "sid", "type", "iat", "exp"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise AccessTokenExpired from exc
    except jwt.InvalidTokenError as exc:
        raise AccessTokenInvalid from exc
    if payload["type"] != ACCESS_TOKEN_TYPE:
        raise AccessTokenInvalid
    return payload


# ---- リフレッシュトークン ----------------------------------------------------------


def new_refresh_token() -> str:
    """256ビットの乱数をURLセーフなBase64にした文字列。"""
    return secrets.token_urlsafe(32)


def hash_refresh_token(token: str) -> str:
    """DBに保存・検索するためのSHA-256(16進数)。十分にランダムなので遅いハッシュは不要。"""
    return hashlib.sha256(token.encode()).hexdigest()


def refresh_token_ttl() -> timedelta:
    return timedelta(days=settings.refresh_token_ttl_days)
