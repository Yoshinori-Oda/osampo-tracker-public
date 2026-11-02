"""管理用のコマンド。apiのコンテナで実行する(backendディレクトリで):

    docker compose run --rm api python -m app.cli seed-dev                 # 開発用のユーザーを入れる
    docker compose run --rm api python -m app.cli disable-user <email>     # アカウントを停止する
    docker compose run --rm api python -m app.cli enable-user <email>      # 停止を解除する
    docker compose run --rm api python -m app.cli send-test-mail <宛先>    # テストメールをoutboxに積む(workerが送る)

管理者の画面・APIができるまでの手段。
"""

import argparse
import asyncio
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.db import app_session
from app.models import User
from app.models.user import ROLE_ADMIN, ROLE_USER
from app.security import hash_password
from app.services import auth_service, mail_service
from app.services.session_service import current_time

# 開発用のユーザー(本番では使わない)。パスワードは開発用なのでここに置く
DEV_USERS = [
    # (id, email, password, display_name, role, メールアドレス確認済みか)
    (uuid.UUID("00000000-0000-0000-0000-00000000a001"), "admin@example.com", "admin-password", "管理者", ROLE_ADMIN, True),
    # 既存のテストデータ(db/seed.sql・frontendの開発時のuser_id)のユーザー
    (uuid.UUID("11111111-1111-1111-1111-111111111111"), "testuser@example.com", "testuser-password", "テストユーザー", ROLE_USER, True),
    # メールアドレスが未確認のユーザー(同期が403になることの確認用)
    (uuid.UUID("00000000-0000-0000-0000-00000000a003"), "unverified@example.com", "unverified-password", "未確認ユーザー", ROLE_USER, False),
]


async def seed_dev() -> None:
    """開発用のユーザーを入れる。既にあれば(idで判定)パスワード・ロール・確認状態を設定し直す。"""
    async with app_session() as db:
        now = await current_time(db)
        for user_id, email, password, display_name, role, verified in DEV_USERS:
            user = await db.get(User, user_id)
            if user is None:
                user = User(id=user_id, email=email, display_name=display_name)
                db.add(user)
            user.email = email
            user.password_hash = hash_password(password)
            user.role = role
            user.email_verified_at = now if verified else None
            user.disabled_at = None
            user.updated_at = now
            print(f"{email} / {password} ({role}, {'確認済み' if verified else '未確認'})")
        await db.commit()


async def set_disabled(email: str, disabled: bool) -> None:
    async with app_session() as db:
        await _set_disabled(db, email, disabled)


async def _set_disabled(db: AsyncSession, email: str, disabled: bool) -> None:
    user = await auth_service.set_user_disabled(db, email, disabled)
    print(f"{user.email}: {'停止しました(端末のログイン状態も無効にしました)' if disabled else '停止を解除しました'}")


async def send_test_mail(to_address: str) -> None:
    """テストメールをoutboxに積む。送信はworkerが行う(開発中はMailpitの画面 http://localhost:8025 で確認する)。"""
    async with app_session() as db:
        email = await mail_service.enqueue_email(
            db,
            to_address=to_address,
            subject="【osampo-tracker】テストメール",
            body="osampo-trackerのメール送信のテストです。\nこのメールは開発用のコマンド(send-test-mail)で送りました。\n",
        )
        await db.commit()
    print(f"outboxに積みました(id: {email.id})。workerが数秒以内に送ります")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli", description="osampo-trackerの管理用のコマンド")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("seed-dev", help="開発用のユーザーを入れる")
    disable = commands.add_parser("disable-user", help="アカウントを停止する")
    disable.add_argument("email")
    enable = commands.add_parser("enable-user", help="アカウントの停止を解除する")
    enable.add_argument("email")
    test_mail = commands.add_parser("send-test-mail", help="テストメールをoutboxに積む(workerが送る)")
    test_mail.add_argument("to_address")
    args = parser.parse_args()

    if args.command == "seed-dev":
        asyncio.run(seed_dev())
    elif args.command == "disable-user":
        asyncio.run(set_disabled(args.email, disabled=True))
    elif args.command == "enable-user":
        asyncio.run(set_disabled(args.email, disabled=False))
    elif args.command == "send-test-mail":
        asyncio.run(send_test_mail(args.to_address))


if __name__ == "__main__":
    main()
