"""Alembicの実行時に読み込まれる設定(非同期用)。

接続はマイグレーション用のロール(MIGRATOR_DB_USER)で行う。テーブルの所有者がこのロールになり、
初回起動時のスクリプト(db/init/)で設定したALTER DEFAULT PRIVILEGESによって、アプリ用のロールに
読み書きの権限が自動で付く。

対象のデータベースは`-x db=test`を付けるとテスト用、付けなければ開発用になる。
"""

import asyncio
from logging.config import fileConfig

from alembic import context
from geoalchemy2 import alembic_helpers
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import settings
from app.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def _database_name() -> str:
    x_args = context.get_x_argument(as_dictionary=True)
    return settings.postgres_test_db if x_args.get("db") == "test" else settings.postgres_db


def _configure_options() -> dict:
    # GeoAlchemy2の補助:
    # - include_object: PostGISが作るテーブル(spatial_ref_sys)や空間インデックスを比較の対象から外す
    # - render_item / writer: 自動生成時にGeography型を正しく出力する
    return {
        "target_metadata": target_metadata,
        "include_object": alembic_helpers.include_object,
        "process_revision_directives": alembic_helpers.writer,
        "render_item": alembic_helpers.render_item,
    }


def run_migrations_offline() -> None:
    """DBに接続せず、実行されるSQLを出力する(`alembic upgrade head --sql`)。"""
    url = settings.migrator_database_url(_database_name())
    context.configure(
        url=url.render_as_string(hide_password=False),
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        **_configure_options(),
    )
    with context.begin_transaction():
        context.run_migrations()


def _run_migrations(connection: Connection) -> None:
    context.configure(connection=connection, **_configure_options())
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    engine = create_async_engine(
        settings.migrator_database_url(_database_name()),
        poolclass=pool.NullPool,
    )
    async with engine.connect() as connection:
        # Alembicのマイグレーション処理は同期なので、非同期の接続の上で同期関数として実行する
        await connection.run_sync(_run_migrations)
    await engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
