import uuid
from collections.abc import AsyncIterator
from functools import cache

from sqlalchemy import URL, Connection, event, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import Session, SessionTransaction

from app.config import settings

# DBとの接続のタイムゾーンをUTCに固定する。timestamptzの値がUTCで返るので、レスポンスの日時が常に"Z"付きになる
DB_CONNECT_ARGS = {"options": "-c timezone=UTC"}

# RLSのポリシーが参照する、今のユーザーのIDの設定名(migrations/versions/0009_row_level_security.pyと揃える)
RLS_USER_SETTING = "app.user_id"
# 今のユーザーのIDをDBセッションに記録しておくキー(session.info)
_RLS_USER_KEY = "rls_user_id"
_SET_RLS_USER = text("SELECT set_config(:name, :user_id, true)")


def _create_sessionmaker(url: URL) -> async_sessionmaker[AsyncSession]:
    engine = create_async_engine(url, pool_pre_ping=True, connect_args=DB_CONNECT_ARGS)
    # commit後に属性へアクセスしても再読み込み(=暗黙のDBアクセス)が起きないようにする。
    # 非同期では暗黙のDBアクセスがエラーになるため
    return async_sessionmaker(engine, expire_on_commit=False)


# 接続先のロールはプロセスごとに1つ(apiと管理用のコマンドはapi用、workerはworker用)。
# 使うときに初めて作るのは、workerにapi用の接続情報を渡さない(その逆も)ため
@cache
def _app_sessionmaker() -> async_sessionmaker[AsyncSession]:
    return _create_sessionmaker(settings.app_database_url)


@cache
def _worker_sessionmaker() -> async_sessionmaker[AsyncSession]:
    return _create_sessionmaker(settings.worker_database_url)


def app_session() -> AsyncSession:
    """api用のロールのDBセッション(管理用のコマンドでも使う)。"""
    return _app_sessionmaker()()


def worker_session() -> AsyncSession:
    """worker用のロールのDBセッション。"""
    return _worker_sessionmaker()()


async def get_session() -> AsyncIterator[AsyncSession]:
    """リクエストごとにDBセッションを渡す依存関係(FastAPIのDepends用)。"""
    async with app_session() as session:
        yield session


# ---- RLS(行レベルセキュリティ)の今のユーザー ---------------------------------------------
# 設計はbackend/docs/バックエンド構成.mdの「行レベルセキュリティ(RLS)」。
# set_config(..., true)(=SET LOCAL)はトランザクションが終わると消えるので、トランザクションが始まるたびに渡し直す
# (管理者が他のユーザーを指定すると、監査ログのcommitを挟んでトランザクションが2つになるため)


async def set_rls_user(db: AsyncSession, user_id: uuid.UUID) -> None:
    """DBセッションに今のユーザーを記録し、以降のトランザクションでRLSのポリシーに渡す。

    認証が終わった時点で呼ぶ。その時点で始まっているトランザクションにはすぐ渡す。
    """
    db.info[_RLS_USER_KEY] = user_id
    if db.in_transaction():
        await db.execute(_SET_RLS_USER, {"name": RLS_USER_SETTING, "user_id": str(user_id)})


# 非同期のセッション(AsyncSession)の中身は同期のSessionなので、同期のSessionのクラスに登録する(全てのセッションが対象)
@event.listens_for(Session, "after_begin")
def _pass_rls_user_on_begin(
    session: Session, transaction: SessionTransaction, connection: Connection
) -> None:
    user_id = session.info.get(_RLS_USER_KEY)
    if user_id is not None:
        connection.execute(_SET_RLS_USER, {"name": RLS_USER_SETTING, "user_id": str(user_id)})
