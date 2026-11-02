"""現行のスキーマ(旧initdb.sql)をそのまま写した初期マイグレーション

テーブル(users / sessions / track_points)・インデックスに加えて、PostgRESTが使うストアドファンクション
(register_session_with_points / fetch_remote_sessions)も含める。ストアドファンクションはPostgRESTを
削除する際に別のマイグレーションで削除する。
拡張機能(postgis / uuid-ossp)はスーパーユーザーの権限が必要なので、ここではなく初回起動時の
スクリプト(db/init/)で作成済みの前提。

Revision ID: 0001
Revises:
Create Date: 2026-10-05

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from geoalchemy2 import Geography
from sqlalchemy.dialects.postgresql import DOUBLE_PRECISION, UUID

# revision identifiers, used by Alembic.
revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


REGISTER_SESSION_WITH_POINTS = """
CREATE OR REPLACE FUNCTION public.register_session_with_points(
    p_session jsonb,
    p_track_points jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_session_id uuid;
BEGIN
    v_session_id := (p_session->>'id')::uuid;

    -- upsert session
    INSERT INTO public.sessions (
        id, user_id, name, started_at, ended_at, is_favorite, updated_at, move_method,
        total_distance, duration_seconds, elevation_gain, max_altitude, min_altitude
    ) VALUES (
        v_session_id,
        (p_session->>'user_id')::uuid,
        p_session->>'name',
        (p_session->>'started_at')::timestamptz,
        (p_session->>'ended_at')::timestamptz,
        COALESCE((p_session->>'is_favorite')::boolean, false),
        COALESCE((p_session->>'updated_at')::timestamptz, CURRENT_TIMESTAMP),
        p_session->>'move_method',
        COALESCE((p_session->>'total_distance')::double precision, 0.0),
        COALESCE((p_session->>'duration_seconds')::integer, 0),
        COALESCE((p_session->>'elevation_gain')::real, 0.0),
        (p_session->>'max_altitude')::real,
        (p_session->>'min_altitude')::real
    )
    ON CONFLICT (id) DO UPDATE SET
        user_id = EXCLUDED.user_id,
        name = EXCLUDED.name,
        started_at = EXCLUDED.started_at,
        ended_at = EXCLUDED.ended_at,
        is_favorite = EXCLUDED.is_favorite,
        updated_at = EXCLUDED.updated_at,
        move_method = EXCLUDED.move_method,
        total_distance = EXCLUDED.total_distance,
        duration_seconds = EXCLUDED.duration_seconds,
        elevation_gain = EXCLUDED.elevation_gain,
        max_altitude = EXCLUDED.max_altitude,
        min_altitude = EXCLUDED.min_altitude;

    -- insert track_points
    DELETE FROM public.track_points WHERE session_id = v_session_id;
    IF jsonb_array_length(p_track_points) > 0 THEN
        INSERT INTO public.track_points (session_id, location, recorded_at)
        SELECT
            v_session_id,
            ST_SetSRID(
                ST_MakePoint(
                    (elem->>'longitude')::double precision,
                    (elem->>'latitude')::double precision,
                    (elem->>'altitude')::double precision
                ),
                4326
            )::geography,
            (elem->>'recorded_at')::timestamptz
        FROM jsonb_array_elements(p_track_points) AS elem;
    END IF;
END;
$$;
"""

FETCH_REMOTE_SESSIONS = """
CREATE OR REPLACE FUNCTION public.fetch_remote_sessions(
    p_user_id uuid,
    p_sync_time timestamptz DEFAULT NULL,
    p_last_synced_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_agg(session_obj) INTO v_result
    FROM (
        SELECT
            s.id,
            s.user_id,
            s.name,
            s.started_at,
            s.ended_at,
            s.is_favorite,
            s.move_method,
            s.total_distance,
            s.duration_seconds,
            s.elevation_gain,
            s.max_altitude,
            s.min_altitude,
            s.updated_at,
            s.deleted_at,
            COALESCE(
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'recorded_at', tp.recorded_at,
                            'longitude', ST_X(tp.location::geometry),
                            'latitude', ST_Y(tp.location::geometry),
                            'altitude', ST_Z(tp.location::geometry)
                        ) ORDER BY tp.recorded_at ASC
                    )
                    FROM public.track_points tp
                    WHERE tp.session_id = s.id
                ),
                '[]'::jsonb
            ) AS track_points
        FROM public.sessions s
        WHERE s.user_id = p_user_id
            AND (p_sync_time IS NULL OR s.updated_at != p_sync_time)
            AND (p_last_synced_at IS NULL OR s.updated_at > p_last_synced_at)
        ORDER BY s.started_at DESC
    ) session_obj;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;
"""


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")
        ),
        sa.Column("email", sa.String(255), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=True,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.UniqueConstraint("email", name="users_email_key"),
    )

    op.create_table(
        "sessions",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")
        ),
        sa.Column(
            "user_id",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE", name="sessions_user_id_fkey"),
            nullable=False,
        ),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("is_favorite", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=True,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("move_method", sa.String(50), nullable=False),
        sa.Column(
            "total_distance", DOUBLE_PRECISION(), nullable=False, server_default=sa.text("0.0")
        ),
        sa.Column("duration_seconds", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("elevation_gain", sa.REAL(), nullable=False, server_default=sa.text("0.0")),
        sa.Column("max_altitude", sa.REAL(), nullable=True),
        sa.Column("min_altitude", sa.REAL(), nullable=True),
    )
    op.create_index("idx_sessions_user_id", "sessions", ["user_id"])
    op.create_index("idx_sessions_updated_at", "sessions", ["updated_at"])
    # パージ処理の対象抽出用。tombstone行は少数のはずなので部分インデックスにする
    op.create_index(
        "idx_sessions_deleted_at",
        "sessions",
        ["deleted_at"],
        postgresql_where=sa.text("deleted_at IS NOT NULL"),
    )

    op.create_table(
        "track_points",
        sa.Column("id", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column(
            "session_id",
            UUID(as_uuid=True),
            sa.ForeignKey("sessions.id", ondelete="CASCADE", name="track_points_session_id_fkey"),
            nullable=False,
        ),
        sa.Column(
            "location",
            Geography(geometry_type="POINTZ", srid=4326, spatial_index=False),
            nullable=False,
        ),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("idx_track_points_session_id", "track_points", ["session_id"])

    op.execute(REGISTER_SESSION_WITH_POINTS)
    op.execute(FETCH_REMOTE_SESSIONS)


def downgrade() -> None:
    op.execute("DROP FUNCTION IF EXISTS public.fetch_remote_sessions(uuid, timestamptz, timestamptz)")
    op.execute("DROP FUNCTION IF EXISTS public.register_session_with_points(jsonb, jsonb)")
    op.drop_table("track_points")
    op.drop_table("sessions")
    op.drop_table("users")
