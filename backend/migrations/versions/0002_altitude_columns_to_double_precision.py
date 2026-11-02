"""sessionsの高度関連の3列をREALからdouble precisionにする

elevation_gain・max_altitude・min_altitudeをREAL(単精度)からdouble precision(倍精度)にする。
端末(Dartのdouble・SQLite)は倍精度なので、REALのままだと保存時に精度が落ち、POSTの再送判定で
値を比較すると一致しなくなるため。同期で取得したデータの精度を落とさない目的もある。

PostgRESTが使うストアドファンクションregister_session_with_pointsも、この3列の値を::realに変換してから
保存しているので、::double precisionに変換するよう作り直す(列だけ変えても関数の中で精度が落ちるため)。

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-05

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import DOUBLE_PRECISION

# revision identifiers, used by Alembic.
revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


ALTITUDE_COLUMNS = ("elevation_gain", "max_altitude", "min_altitude")


def _register_session_with_points(altitude_type: str) -> str:
    """register_session_with_pointsの定義。高度関連の3列を変換する型(altitude_type)だけが0001と異なる。"""
    return f"""
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
        COALESCE((p_session->>'elevation_gain')::{altitude_type}, 0.0),
        (p_session->>'max_altitude')::{altitude_type},
        (p_session->>'min_altitude')::{altitude_type}
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


def upgrade() -> None:
    # REALからdouble precisionへの変換は値が失われないので、既存のデータはそのまま変換される
    for column in ALTITUDE_COLUMNS:
        op.alter_column(
            "sessions",
            column,
            type_=DOUBLE_PRECISION(),
            existing_type=sa.REAL(),
        )
    op.execute(_register_session_with_points("double precision"))


def downgrade() -> None:
    # double precisionからREALに戻すと、REALで表せない桁は丸められる
    for column in ALTITUDE_COLUMNS:
        op.alter_column(
            "sessions",
            column,
            type_=sa.REAL(),
            existing_type=DOUBLE_PRECISION(),
        )
    op.execute(_register_session_with_points("real"))
