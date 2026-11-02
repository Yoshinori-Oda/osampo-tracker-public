"""同期APIの業務ルール(再送の判定・削除と編集の競合・復活など)。仕様はbackend/docs/API設計ドラフト.mdを参照。

時刻はDBのclock_timestamp()(実行した瞬間のサーバー時刻)を正とする。端末の時計は使わない。
処理を続けられない場合はAppErrorを投げる(routersで共通の形式のエラーレスポンスになる)。
404・409の理由(レスポンスではわざと区別しないもの)は、アプリのログのINFOに出す(backend/docs/バックエンド構成.mdの「ログ」)。
"""

import logging
import uuid
from datetime import datetime, timedelta
from typing import NoReturn

from geoalchemy2 import Geometry
from sqlalchemy import any_, bindparam, cast, func, insert, select
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import AppError, ErrorCode
from app.models import TrackingSession, TrackPoint, User
from app.schemas.session import (
    DeletedSessionOut,
    SessionCreate,
    SessionEdit,
    SessionOut,
    SyncResponse,
    TrackPointIn,
    TrackPointOut,
)

logger = logging.getLogger(__name__)

# 再送の判定で、同じsessionかどうかを見分けるのに使う不変の項目(API設計書の特定項目*1)
IMMUTABLE_FIELDS = (
    "started_at",
    "ended_at",
    "total_distance",
    "duration_seconds",
    "elevation_gain",
    "max_altitude",
    "min_altitude",
)
# 端末で編集できる可変の項目(API設計書の特定項目*2)
MUTABLE_FIELDS = ("name", "move_method", "is_favorite")

# track_pointsを1つのINSERT文でまとめて登録する件数(1文あたりのパラメーター数の上限を超えないようにするため)
TRACK_POINT_INSERT_BATCH_SIZE = 5000


async def current_time(db: AsyncSession) -> datetime:
    """サーバー時刻。now()はトランザクションの開始時刻で固定されるので、実行した瞬間の時刻(clock_timestamp)を使う。"""
    return await db.scalar(select(func.clock_timestamp()))


async def ensure_user_exists(db: AsyncSession, user_id: uuid.UUID) -> None:
    if await db.get(User, user_id) is None:
        raise AppError(404, ErrorCode.USER_NOT_FOUND, "ユーザーが見つかりません")


def _ids_param(name: str, ids: list[uuid.UUID]):
    """IDの一覧を1つの配列パラメーターとして渡す(IN (...)だとIDの数だけパラメーターが増え、上限を超えうるため)。"""
    return any_(bindparam(name, value=ids, type_=ARRAY(UUID(as_uuid=True))))


# ---- GET(差分取得) ----------------------------------------------------------------


async def fetch_sessions(
    db: AsyncSession,
    user_id: uuid.UUID,
    last_synced_at: datetime | None,
    purge_retention_days: int,
) -> SyncResponse:
    # 検索を始める前の時刻にする(検索中に書き込まれた行を、次回の差分取得で取りこぼさないため)
    synced_at = await current_time(db)
    if last_synced_at is not None and last_synced_at > synced_at:
        raise AppError(
            422,
            ErrorCode.VALIDATION_ERROR,
            "入力が不正です",
            details=[
                {
                    "field": "query.last_synced_at",
                    "reason": "サーバー時刻より後の日時は指定できません",
                }
            ],
        )

    statement = (
        select(TrackingSession)
        .where(TrackingSession.user_id == user_id)
        .order_by(TrackingSession.started_at)
    )
    if last_synced_at is None:
        # 初回の同期: 削除済みは返さない
        statement = statement.where(TrackingSession.deleted_at.is_(None))
    else:
        # 差分: 前回以降に更新・削除されたもの(自分がpushしたものも含む)
        statement = statement.where(TrackingSession.updated_at > last_synced_at)
    sessions = (await db.scalars(statement)).all()

    alive_ids = [s.id for s in sessions if s.deleted_at is None]
    track_points = await _load_track_points(db, alive_ids)

    results: list[SessionOut | DeletedSessionOut] = []
    for s in sessions:
        if s.deleted_at is not None:
            results.append(DeletedSessionOut(id=s.id, deleted_at=s.deleted_at))
        else:
            results.append(
                SessionOut(
                    id=s.id,
                    name=s.name,
                    started_at=s.started_at,
                    ended_at=s.ended_at,
                    is_favorite=s.is_favorite,
                    move_method=s.move_method,
                    total_distance=s.total_distance,
                    duration_seconds=s.duration_seconds,
                    elevation_gain=s.elevation_gain,
                    max_altitude=s.max_altitude,
                    min_altitude=s.min_altitude,
                    updated_at=s.updated_at,
                    track_points=track_points.get(s.id, []),
                )
            )

    # パージ期間より前に同期したきりの端末は、パージ済みの削除を受け取れていない可能性がある
    request_existence_check = last_synced_at is not None and last_synced_at < synced_at - timedelta(
        days=purge_retention_days
    )
    return SyncResponse(
        synced_at=synced_at,
        request_existence_check=request_existence_check,
        sessions=results,
    )


async def _load_track_points(
    db: AsyncSession, session_ids: list[uuid.UUID]
) -> dict[uuid.UUID, list[TrackPointOut]]:
    if not session_ids:
        return {}
    # ST_X/ST_Y/ST_Zはgeometry型の関数なのでgeographyから変換する。型を指定しないと2次元(geometry(GEOMETRY,-1))への
    # 変換になり、高度(Z)を持つ点がエラーになるので、高度付きの点(POINTZ)として変換する
    geometry = cast(TrackPoint.location, Geometry(geometry_type="POINTZ", srid=4326))
    rows = await db.execute(
        select(
            TrackPoint.session_id,
            TrackPoint.recorded_at,
            func.ST_Y(geometry),
            func.ST_X(geometry),
            func.ST_Z(geometry),
        )
        .where(TrackPoint.session_id == _ids_param("session_ids", session_ids))
        .order_by(TrackPoint.session_id, TrackPoint.recorded_at)
    )
    points: dict[uuid.UUID, list[TrackPointOut]] = {}
    for session_id, recorded_at, latitude, longitude, altitude in rows:
        points.setdefault(session_id, []).append(
            TrackPointOut(
                recorded_at=recorded_at,
                latitude=latitude,
                longitude=longitude,
                altitude=altitude,
            )
        )
    return points


# ---- POST(登録) ---------------------------------------------------------------


async def register_session(
    db: AsyncSession, user_id: uuid.UUID, body: SessionCreate
) -> tuple[int, datetime]:
    """sessionを登録し、(ステータスコード, updated_at)を返す。新規なら201、同じidの再送なら200。"""
    now = await current_time(db)

    existing = await _lock_session(db, body.id)
    if existing is None:
        inserted_id = await db.scalar(
            pg_insert(TrackingSession)
            .values(
                id=body.id,
                user_id=user_id,
                name=body.name,
                started_at=body.started_at,
                ended_at=body.ended_at,
                is_favorite=body.is_favorite,
                move_method=body.move_method,
                total_distance=body.total_distance,
                duration_seconds=body.duration_seconds,
                elevation_gain=body.elevation_gain,
                max_altitude=body.max_altitude,
                min_altitude=body.min_altitude,
                updated_at=now,
            )
            .on_conflict_do_nothing(index_elements=[TrackingSession.id])
            .returning(TrackingSession.id)
        )
        if inserted_id is not None:
            await _insert_track_points(db, body.id, body.track_points)
            # sessionとtrack_pointsを1つのトランザクションで確定する
            await db.commit()
            return 201, now
        # 同じidの行が既にあった。同時に同じidのPOSTが届いて先に登録された(ON CONFLICTは相手の確定を待つので、
        # 次のSELECTで見える)か、他ユーザーの行と衝突した(RLSで見えない。一意制約はRLSに関係なく効く)
        existing = await _lock_session(db, body.id)
        if existing is None:
            _raise_id_conflicted(body.id, "other_user")
    return await _resolve_resent_session(db, user_id, body, existing, now)


async def _lock_session(db: AsyncSession, session_id: uuid.UUID) -> TrackingSession | None:
    """idでsessionを行ロック付きで取得する(RLSで他ユーザーの行は見えない。管理者は全ての行が見える)。"""
    return await db.scalar(
        select(TrackingSession)
        .where(TrackingSession.id == session_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )


def _raise_id_conflicted(session_id: uuid.UUID, reason: str) -> NoReturn:
    # 他ユーザーのuser_idはログにも出さない
    logger.info("session id conflicted", extra={"session_id": session_id, "reason": reason})
    raise AppError(409, ErrorCode.ID_CONFLICTED, "idが別のセッションと衝突しています")


async def _resolve_resent_session(
    db: AsyncSession,
    user_id: uuid.UUID,
    body: SessionCreate,
    existing: TrackingSession,
    now: datetime,
) -> tuple[int, datetime]:
    """同じidのレコードが既にある場合の判定(API設計書のPOSTの手順8)。"""
    # 他ユーザーのレコード(管理者だけが見える)、または不変の項目が違う場合は別のsession(idの衝突)とみなす。
    # 他ユーザーのレコードは中身を比べない(他ユーザーのデータの内容を探る手段にしないため)
    if existing.user_id != user_id:
        _raise_id_conflicted(body.id, "other_user")
    if any(getattr(existing, field) != getattr(body, field) for field in IMMUTABLE_FIELDS):
        _raise_id_conflicted(body.id, "different_session")

    changed = _mutable_fields_changed(existing, body)
    if existing.deleted_at is not None:
        # 削除済みのsessionへの、ローカルでの編集を含む再送は、削除と編集の競合
        if changed:
            logger.info(
                "session edit conflicted with deletion",
                extra={"session_id": existing.id, "action": "resend"},
            )
            raise AppError(409, ErrorCode.DELETED, "セッションは削除済みです")
        # 登録は成功していたので成功として返す。削除は次のGETでtombstoneとして届く
        return 200, existing.updated_at

    if not changed:
        return 200, existing.updated_at
    # レスポンスが返らない間にローカルで編集された可変の項目を反映する
    _apply_mutable_fields(existing, body)
    existing.updated_at = now
    await db.commit()
    return 200, now


async def _insert_track_points(
    db: AsyncSession, session_id: uuid.UUID, track_points: list[TrackPointIn]
) -> None:
    for start in range(0, len(track_points), TRACK_POINT_INSERT_BATCH_SIZE):
        batch = track_points[start : start + TRACK_POINT_INSERT_BATCH_SIZE]
        await db.execute(
            insert(TrackPoint).values(
                [
                    {
                        "session_id": session_id,
                        "recorded_at": point.recorded_at,
                        # geometryの点を作り、列の型(geography)へは暗黙の型変換に任せる
                        "location": func.ST_SetSRID(
                            func.ST_MakePoint(point.longitude, point.latitude, point.altitude),
                            4326,
                        ),
                    }
                    for point in batch
                ]
            )
        )


# ---- PATCH(修正)・restore(削除の取り消し) -------------------------------------


async def edit_session(
    db: AsyncSession,
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    body: SessionEdit,
    *,
    restore: bool,
) -> datetime:
    """可変の項目を反映し、updated_atを返す。restore=Trueなら削除済みのsessionの削除も取り消す。"""
    now = await current_time(db)
    target = await _find_own_session(db, user_id, session_id)

    if target.deleted_at is not None:
        if not restore:
            logger.info(
                "session edit conflicted with deletion",
                extra={"session_id": target.id, "action": "edit"},
            )
            raise AppError(409, ErrorCode.DELETED, "セッションは削除済みです")
        target.deleted_at = None
        _apply_mutable_fields(target, body)
        target.updated_at = now
        await db.commit()
        return now

    # 生きているsession(restoreでは復活済みの場合)。値が同じなら何も変えずに既存のupdated_atを返す
    if not _mutable_fields_changed(target, body):
        return target.updated_at
    _apply_mutable_fields(target, body)
    target.updated_at = now
    await db.commit()
    return now


# ---- DELETE(削除) -------------------------------------------------------------


async def delete_session(db: AsyncSession, user_id: uuid.UUID, session_id: uuid.UUID) -> None:
    target = await _find_own_session(db, user_id, session_id)
    if target.deleted_at is not None:
        # 既に削除済みなら何も変えない(パージまでの期間が延びたり、同じtombstoneが他端末に再度届いたりしないように)
        return
    now = await current_time(db)
    # tombstoneにする。データは復活と再送時の比較のために残す
    target.deleted_at = now
    target.updated_at = now
    await db.commit()


# ---- existence-check(削除の突き合わせ) ------------------------------------------


async def find_missing_session_ids(
    db: AsyncSession, user_id: uuid.UUID, session_ids: list[uuid.UUID]
) -> list[uuid.UUID]:
    """当該ユーザーの生きているsessionとして存在しないIDを返す(tombstone・他ユーザーのもの・未登録を含む)。"""
    requested = set(session_ids)
    if not requested:
        return []
    existing = await db.scalars(
        select(TrackingSession.id).where(
            TrackingSession.user_id == user_id,
            TrackingSession.id == _ids_param("session_ids", list(requested)),
            TrackingSession.deleted_at.is_(None),
        )
    )
    return list(requested - set(existing))


# ---- 共通 -----------------------------------------------------------------------


async def _find_own_session(
    db: AsyncSession, user_id: uuid.UUID, session_id: uuid.UUID
) -> TrackingSession:
    """当該ユーザーのsessionを行ロック付きで取得する。他ユーザーのもの・存在しないものは区別せず404にする。

    RLSで他ユーザーの行は見えないので、ログでも「無い」と「他ユーザーのもの」を区別しない(reasonは1つ)。
    """
    target = await db.scalar(
        select(TrackingSession)
        .where(TrackingSession.id == session_id, TrackingSession.user_id == user_id)
        .with_for_update()
    )
    if target is None:
        logger.info(
            "session not found",
            extra={"session_id": session_id, "reason": "not_found_or_not_visible"},
        )
        raise AppError(404, ErrorCode.SESSION_NOT_FOUND, "セッションが見つかりません")
    return target


def _mutable_fields_changed(target: TrackingSession, body: SessionCreate | SessionEdit) -> bool:
    return any(getattr(target, field) != getattr(body, field) for field in MUTABLE_FIELDS)


def _apply_mutable_fields(target: TrackingSession, body: SessionCreate | SessionEdit) -> None:
    for field in MUTABLE_FIELDS:
        setattr(target, field, getattr(body, field))
