import os
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


def _write_test_jwt_keys() -> None:
    """テスト用のES256の鍵のペアをその場で作る(backend/secrets/の本物の鍵をテストに使わないため)。"""
    key_dir = Path(tempfile.mkdtemp(prefix="jwt-keys-"))
    private_key = ec.generate_private_key(ec.SECP256R1())
    (key_dir / "private.pem").write_bytes(
        private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    (key_dir / "public.pem").write_bytes(
        private_key.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
        )
    )
    os.environ["JWT_PRIVATE_KEY_PATH"] = str(key_dir / "private.pem")
    os.environ["JWT_PUBLIC_KEY_PATH"] = str(key_dir / "public.pem")


# app.configのSettingsはimport時に環境変数を読むので、appをimportする前に設定する。
# pytestは常にテスト用のデータベース(POSTGRES_TEST_DB)に接続する
os.environ["POSTGRES_DB"] = os.environ.get("POSTGRES_TEST_DB", "location_db_test")
_write_test_jwt_keys()

import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.pool import NullPool

from app import security
from app.config import settings
from app.db import DB_CONNECT_ARGS, get_session
from app.main import app
from app.models import AuthSession, User
from app.models.user import ROLE_ADMIN, ROLE_USER


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    """テストごとにトランザクションを開始し、最後にロールバックするDBセッション(データはテスト用DBに残らない)。

    APIの処理の中でのcommit()は、join_transaction_mode="create_savepoint"によってセーブポイントの確定になり、
    外側のトランザクションは確定しない。
    """
    # テストごとにイベントループが変わるので、接続を使い回さない(NullPool)
    engine = create_async_engine(
        settings.app_database_url, poolclass=NullPool, connect_args=DB_CONNECT_ARGS
    )
    async with engine.connect() as connection:
        transaction = await connection.begin()
        session = AsyncSession(
            bind=connection,
            join_transaction_mode="create_savepoint",
            expire_on_commit=False,
        )
        try:
            yield session
        finally:
            await session.close()
            await transaction.rollback()
    await engine.dispose()


async def create_user(
    db_session: AsyncSession,
    *,
    verified: bool = True,
    role: str = ROLE_USER,
    password: str | None = None,
) -> User:
    """テスト用のユーザーを作る。passwordを渡したときだけハッシュを作る(argon2は遅いため)。"""
    email = f"{uuid.uuid4()}@example.com"
    user = User(
        email=email,
        display_name="テスト",
        role=role,
        password_hash=security.hash_password(password) if password else None,
        email_verified_at=datetime.now(UTC) if verified else None,
    )
    db_session.add(user)
    await db_session.flush()
    return user


async def auth_headers(db_session: AsyncSession, user: User) -> dict[str, str]:
    """userでログインした状態のAuthorizationヘッダー(端末のログイン状態を作り、アクセストークンを発行する)。"""
    auth_session = AuthSession(user_id=user.id, device_id=uuid.uuid4())
    db_session.add(auth_session)
    await db_session.flush()
    return {"Authorization": f"Bearer {security.create_access_token(user.id, auth_session.id)}"}


ClientFactory = Callable[[User | None], Awaitable[AsyncClient]]


@pytest.fixture
async def client_factory(db_session: AsyncSession) -> AsyncIterator[ClientFactory]:
    """APIを呼ぶクライアントを作る関数。userを渡すとそのユーザーでログインした状態(Authorizationヘッダー付き)になる。

    APIのDBセッションはdb_sessionに差し替える(FastAPIのdependency_overrides)。
    """

    async def override_get_session() -> AsyncIterator[AsyncSession]:
        yield db_session

    app.dependency_overrides[get_session] = override_get_session
    clients: list[AsyncClient] = []

    async def make(user: User | None = None) -> AsyncClient:
        headers = await auth_headers(db_session, user) if user is not None else {}
        client = AsyncClient(transport=ASGITransport(app=app), base_url="http://test", headers=headers)
        clients.append(client)
        return client

    try:
        yield make
    finally:
        for client in clients:
            await client.aclose()
        app.dependency_overrides.clear()


@pytest.fixture
def user_factory(db_session: AsyncSession) -> Callable[..., Awaitable[User]]:
    """テスト用のユーザーを作る関数(create_userの引数を渡せる)。テストファイルからconftestをimportしないために使う。"""

    async def make(**kwargs) -> User:
        return await create_user(db_session, **kwargs)

    return make


@pytest.fixture
async def user(db_session: AsyncSession) -> User:
    return await create_user(db_session)


@pytest.fixture
async def other_user(db_session: AsyncSession) -> User:
    return await create_user(db_session)


@pytest.fixture
async def admin_user(db_session: AsyncSession) -> User:
    return await create_user(db_session, role=ROLE_ADMIN)


@pytest.fixture
async def api_client(client_factory: ClientFactory, user: User) -> AsyncClient:
    """userでログインした状態のクライアント。"""
    return await client_factory(user)


@pytest.fixture
async def other_api_client(client_factory: ClientFactory, other_user: User) -> AsyncClient:
    """other_userでログインした状態のクライアント。"""
    return await client_factory(other_user)


@pytest.fixture
async def anonymous_client(client_factory: ClientFactory) -> AsyncClient:
    """ログインしていない(Authorizationヘッダーの無い)クライアント。"""
    return await client_factory(None)
