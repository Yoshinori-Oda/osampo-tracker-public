from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """全てのモデルの基底クラス。Alembicの自動生成・checkはこのmetadataを参照する。"""
