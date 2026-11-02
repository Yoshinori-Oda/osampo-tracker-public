"""同期APIのリクエスト/レスポンスの型と入力チェック。仕様はbackend/docs/API設計ドラフト.mdを参照。

日時はタイムゾーン付き(AwareDatetime)のみ受け付ける("Z"や"+09:00"の無い日時は422)。
各項目のdescription・examplesはOpenAPIのドキュメントになる。
"""

import uuid
from datetime import datetime
from enum import StrEnum
from typing import Annotated, Any, Self

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, StringConstraints, model_validator


class MoveMethod(StrEnum):
    """移動手段。frontendのMoveMethod(lib/models/move_method.dart)と同じ値にする。"""

    WALK = "walk"
    RUN = "run"
    BICYCLE = "bicycle"
    CAR = "car"
    TRAIN = "train"
    PLANE = "plane"
    SHIP = "ship"


SessionName = Annotated[str, StringConstraints(min_length=1, max_length=100)]

# ---- OpenAPIの例(API設計書の例と同じ値) ------------------------------------------

_SESSION_ID = "11111111-1111-1111-1111-111111111111"
_TRACK_POINT_EXAMPLE = {
    "recorded_at": "2026-10-01T17:00:00Z",
    "latitude": 37.33003773,
    "longitude": -122.02088037,
    "altitude": 12.5,
}
_SESSION_FIELDS_EXAMPLE = {
    "name": "近所のお散歩",
    "started_at": "2026-10-01T17:00:00Z",
    "ended_at": "2026-10-01T17:29:00Z",
    "is_favorite": True,
    "move_method": "walk",
    "total_distance": 2.0,
    "duration_seconds": 1740,
    "elevation_gain": 50.0,
    "max_altitude": 30.0,
    "min_altitude": 7.5,
}
_EDIT_EXAMPLE = {"name": "近所のお散歩", "move_method": "walk", "is_favorite": True}

# ---- 項目の説明(リクエストとレスポンスで共通) ------------------------------------

_DESCRIPTIONS = {
    "id": "sessionのid(UUID)。端末で生成する(オフラインで作成するため)",
    "name": "sessionの名前(1〜100文字)",
    "started_at": "記録を開始した日時(端末で記録した時刻)",
    "ended_at": "記録を終了した日時(端末で記録した時刻)。started_at以降",
    "is_favorite": "お気に入りかどうか",
    "move_method": "移動手段",
    "total_distance": "移動距離[km](0以上)",
    "duration_seconds": "記録した時間[秒](0以上)",
    "elevation_gain": "累積の獲得標高[m](0以上)",
    "max_altitude": "最高高度[m]。null可",
    "min_altitude": "最低高度[m]。null可",
    "track_points": "記録した位置の一覧",
    "recorded_at": "その位置を記録した日時(端末で記録した時刻)",
    "latitude": "緯度(-90〜90)",
    "longitude": "経度(-180〜180)",
    "altitude": "高度[m]。nullは不可(信頼度の低い高度は端末が前回の点の高度で補う)",
}


def _described(name: str, **kwargs: Any) -> Any:
    """_DESCRIPTIONSの説明付きのField(入力チェックの条件はkwargsで渡す)。"""
    return Field(description=_DESCRIPTIONS[name], **kwargs)


# ---- リクエスト ------------------------------------------------------------------


class TrackPointIn(BaseModel):
    recorded_at: AwareDatetime = _described("recorded_at")
    latitude: float = _described("latitude", ge=-90, le=90)
    longitude: float = _described("longitude", ge=-180, le=180)
    # nullは許さない(locationは高度込みの点(POINTZ)のため)
    altitude: float = _described("altitude")


class SessionCreate(BaseModel):
    """登録(POST)のbody。nullを許すのはmax_altitude・min_altitudeのみで、キーは全て必須。"""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {"id": _SESSION_ID, **_SESSION_FIELDS_EXAMPLE, "track_points": [_TRACK_POINT_EXAMPLE]}
            ]
        }
    )

    id: uuid.UUID = _described("id")
    name: SessionName = _described("name")
    started_at: AwareDatetime = _described("started_at")
    ended_at: AwareDatetime = _described("ended_at")
    is_favorite: bool = _described("is_favorite")
    move_method: MoveMethod = _described("move_method")
    total_distance: float = _described("total_distance", ge=0)
    duration_seconds: int = _described("duration_seconds", ge=0)
    elevation_gain: float = _described("elevation_gain", ge=0)
    max_altitude: float | None = _described("max_altitude")
    min_altitude: float | None = _described("min_altitude")
    track_points: list[TrackPointIn] = _described("track_points")

    @model_validator(mode="after")
    def ended_at_must_not_be_before_started_at(self) -> Self:
        if self.ended_at < self.started_at:
            raise ValueError("ended_atはstarted_at以降にしてください")
        return self


class SessionEdit(BaseModel):
    """修正(PATCH)・削除の取り消し(restore)のbody。可変の3項目のみで全て必須。それ以外の項目が含まれていれば422にする。"""

    # 端末のバグで不変の項目(started_at等)を変えようとしても気づけるよう、知らない項目は拒否する
    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [_EDIT_EXAMPLE]})

    name: SessionName = _described("name")
    move_method: MoveMethod = _described("move_method")
    is_favorite: bool = _described("is_favorite")


class ExistenceCheckRequest(BaseModel):
    model_config = ConfigDict(json_schema_extra={"examples": [{"session_ids": [_SESSION_ID]}]})

    session_ids: list[uuid.UUID] = Field(
        description=(
            "突き合わせるsessionのid。端末の同期済みのsessionから、直前のGETで受け取ったものを除いたもの。"
            "重複は1つにまとめて扱う"
        ),
    )


# ---- レスポンス ------------------------------------------------------------------


class TrackPointOut(BaseModel):
    recorded_at: datetime = _described("recorded_at")
    latitude: float = _described("latitude")
    longitude: float = _described("longitude")
    altitude: float = _described("altitude")


class SessionOut(BaseModel):
    """GETで返す生きているsession。"""

    id: uuid.UUID = _described("id")
    name: str = _described("name")
    started_at: datetime = _described("started_at")
    ended_at: datetime = _described("ended_at")
    is_favorite: bool = _described("is_favorite")
    move_method: MoveMethod = _described("move_method")
    total_distance: float = _described("total_distance")
    duration_seconds: int = _described("duration_seconds")
    elevation_gain: float = _described("elevation_gain")
    max_altitude: float | None = _described("max_altitude")
    min_altitude: float | None = _described("min_altitude")
    updated_at: datetime = Field(description="最後に更新された日時(サーバー時刻)")
    track_points: list[TrackPointOut] = Field(description="記録した位置の一覧(recorded_atの昇順)")


class DeletedSessionOut(BaseModel):
    """GETで返す削除済みのsession(tombstone)。last_synced_atを指定した場合のみ返す。"""

    id: uuid.UUID = _described("id")
    deleted_at: datetime = Field(description="削除した日時(サーバー時刻)")


class SyncResponse(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "synced_at": "2026-10-01T17:30:00.123456Z",
                    "request_existence_check": False,
                    "sessions": [
                        {
                            "id": _SESSION_ID,
                            **_SESSION_FIELDS_EXAMPLE,
                            "updated_at": "2026-10-01T17:30:00Z",
                            "track_points": [_TRACK_POINT_EXAMPLE],
                        },
                        {
                            "id": "22222222-2222-2222-2222-222222222222",
                            "deleted_at": "2026-09-30T15:00:00Z",
                        },
                    ],
                }
            ]
        }
    )

    synced_at: datetime = Field(
        description="検索を始める前のサーバー時刻。次回のGETでlast_synced_atとして送る",
    )
    request_existence_check: bool = Field(
        description=(
            "trueのときは、パージ済みの削除がsessionsに含まれていない可能性があるので、existence-checkで突き合わせる"
            "(突き合わせが成功するまでlast_synced_atを更新しない)"
        ),
    )
    sessions: list[SessionOut | DeletedSessionOut] = Field(
        description="更新・削除されたsession(started_atの昇順)。削除済みはidとdeleted_atのみ",
    )


class UpdatedAtResponse(BaseModel):
    """登録(POST)・修正(PATCH)・削除の取り消し(restore)のレスポンス。"""

    model_config = ConfigDict(json_schema_extra={"examples": [{"updated_at": "2026-10-01T17:30:00Z"}]})

    updated_at: datetime = Field(
        description=(
            "そのsessionのupdated_at(サーバー時刻)。端末はこの値をsessionのupdated_atとして保存する"
            "(last_synced_atには使わない)"
        ),
    )


class ExistenceCheckResponse(BaseModel):
    model_config = ConfigDict(json_schema_extra={"examples": [{"missing_session_ids": [_SESSION_ID]}]})

    missing_session_ids: list[uuid.UUID] = Field(
        description=(
            "当該ユーザーの生きているsessionとして存在しないid(tombstone・他ユーザーのもの・未登録を含む)。"
            "並び順は保証しない"
        ),
    )
