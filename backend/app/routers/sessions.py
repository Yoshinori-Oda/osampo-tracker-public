"""同期API(/api/users/{user_id}/sessions)。仕様はbackend/docs/API設計ドラフト.mdを参照。

ここではHTTPの受け口(パス・メソッド・ステータスコード・依存関係)だけを扱い、業務ルールはservices層に任せる。
各エンドポイントのdocstringはOpenAPIの説明になる。
"""

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response, status
from pydantic import AwareDatetime

from app.config import settings
from app.dependencies import (
    DbSession,
    TargetUserId,
    require_json_accept,
    require_json_content_type,
)
from app.errors import ErrorCode
from app.schemas.error import error_responses
from app.schemas.session import (
    ExistenceCheckRequest,
    ExistenceCheckResponse,
    SessionCreate,
    SessionEdit,
    SyncResponse,
    UpdatedAtResponse,
)
from app.services import session_service

router = APIRouter(prefix="/api/users/{user_id}/sessions", tags=["sessions"])

# エンドポイントごとに、起こりうるエラー(ステータス → code)を組み合わせる
_USER_NOT_FOUND = [ErrorCode.USER_NOT_FOUND]
_USER_OR_SESSION_NOT_FOUND = [ErrorCode.USER_NOT_FOUND, ErrorCode.SESSION_NOT_FOUND]
_VALIDATION = {422: [ErrorCode.VALIDATION_ERROR]}
# 全てのエンドポイントでAuthorization: Bearer のアクセストークンが必要。同期はメールアドレスの確認済みが必須
_AUTH = {
    401: [ErrorCode.UNAUTHENTICATED, ErrorCode.TOKEN_EXPIRED],
    403: [ErrorCode.FORBIDDEN, ErrorCode.EMAIL_NOT_VERIFIED],
}
_BODY = {
    413: [ErrorCode.PAYLOAD_TOO_LARGE],
    415: [ErrorCode.UNSUPPORTED_MEDIA_TYPE],
}


@router.get(
    "",
    summary="差分取得",
    response_model=SyncResponse,
    dependencies=[Depends(require_json_accept)],
    responses=error_responses(
        {404: _USER_NOT_FOUND, 406: [ErrorCode.NOT_ACCEPTABLE], **_AUTH, **_VALIDATION}
    ),
)
async def fetch_sessions(
    user_id: TargetUserId,
    db: DbSession,
    last_synced_at: Annotated[
        AwareDatetime | None,
        Query(
            description=(
                "前回のレスポンスのsynced_at。省略すると初回の同期として、削除済みを除く全てのsessionを返す。"
                "サーバー時刻より後の日時は422"
            ),
            examples=["2026-10-01T17:30:00.123456Z"],
        ),
    ] = None,
) -> SyncResponse:
    """前回の同期(`last_synced_at`)以降に更新・削除されたsessionを返す。

    - 自分がpushしたsessionも含まれる(端末は同じ内容で上書きしてよい)
    - 削除済みのsessionは`id`と`deleted_at`だけを返す(`last_synced_at`を指定した場合のみ)
    - `synced_at`は検索を始める前のサーバー時刻。次回の`last_synced_at`として送る
    - `last_synced_at`がパージ期間(90日)より前なら`request_existence_check`をtrueにする
      (パージ済みの削除が含まれていない可能性があるので、existence-checkで突き合わせる)
    - sessionsは`started_at`の昇順、track_pointsは`recorded_at`の昇順
    """
    return await session_service.fetch_sessions(
        db, user_id, last_synced_at, settings.purge_retention_days
    )


@router.post(
    "",
    summary="登録",
    response_model=UpdatedAtResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_json_content_type)],
    responses={
        200: {
            "model": UpdatedAtResponse,
            "description": "同じidの再送(登録済み)。可変の項目が変わっていれば反映する",
        },
        **error_responses(
            {
                404: _USER_NOT_FOUND,
                409: [ErrorCode.ID_CONFLICTED, ErrorCode.DELETED],
                **_BODY,
                **_AUTH, **_VALIDATION,
            }
        ),
    },
)
async def register_session(
    user_id: TargetUserId,
    body: SessionCreate,
    db: DbSession,
    response: Response,
) -> UpdatedAtResponse:
    """sessionをtrack_points込みで登録する。新規なら201、同じidの再送なら200。

    同じidのレコードが既にある場合:
    - 他ユーザーのもの、または不変の項目(started_at・ended_at・距離・時間・高度)が違えば409 `id_conflicted`
    - 削除済みで、可変の項目(name・move_method・is_favorite)が違えば409 `deleted`(同じなら200)
    - 生きていれば200。可変の項目が違えば反映してupdated_atを更新する

    レスポンスの`updated_at`はそのsessionのupdated_at用。`last_synced_at`はGETの`synced_at`からのみ更新する。
    """
    status_code, updated_at = await session_service.register_session(db, user_id, body)
    response.status_code = status_code
    return UpdatedAtResponse(updated_at=updated_at)


# "/existence-check"は"/{session_id}"より先に定義する(パスの照合は定義順に行われるため)
@router.post(
    "/existence-check",
    summary="削除の突き合わせ",
    response_model=ExistenceCheckResponse,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses({404: _USER_NOT_FOUND, **_BODY, **_AUTH, **_VALIDATION}),
)
async def check_existence(
    user_id: TargetUserId,
    body: ExistenceCheckRequest,
    db: DbSession,
) -> ExistenceCheckResponse:
    """送られたIDのうち、当該ユーザーの生きているsessionとして存在しないものを返す。

    GETで`request_existence_check`がtrueだった場合に、パージ済みで差分に含まれなかった削除を補うために使う。
    tombstone・他ユーザーのもの・未登録のIDも「存在しない」として返す。DBは変更しない。
    """
    missing = await session_service.find_missing_session_ids(db, user_id, body.session_ids)
    return ExistenceCheckResponse(missing_session_ids=missing)


@router.patch(
    "/{session_id}",
    summary="修正",
    response_model=UpdatedAtResponse,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses(
        {
            404: _USER_OR_SESSION_NOT_FOUND,
            409: [ErrorCode.DELETED],
            **_BODY,
            **_AUTH, **_VALIDATION,
        }
    ),
)
async def edit_session(
    user_id: TargetUserId,
    session_id: uuid.UUID,
    body: SessionEdit,
    db: DbSession,
) -> UpdatedAtResponse:
    """可変の項目(name・move_method・is_favorite)を反映する。3項目とも必須で、それ以外の項目は422。

    - 値が全て同じなら何も変えずに既存のupdated_atを返す
    - 削除済み(パージ前)なら409 `deleted`。パージ済み・他ユーザーのものなら404 `session_not_found`
    """
    updated_at = await session_service.edit_session(db, user_id, session_id, body, restore=False)
    return UpdatedAtResponse(updated_at=updated_at)


@router.delete(
    "/{session_id}",
    summary="削除",
    status_code=status.HTTP_204_NO_CONTENT,
    responses=error_responses({404: _USER_OR_SESSION_NOT_FOUND, **_AUTH, **_VALIDATION}),
)
async def delete_session(
    user_id: TargetUserId,
    session_id: uuid.UUID,
    db: DbSession,
) -> Response:
    """sessionを削除済み(tombstone)にする。既に削除済みなら何も変えずに204。

    tombstoneはパージ期間(90日)の後にworkerが物理削除する。それまではデータを残す(復活・再送時の比較のため)。
    """
    await session_service.delete_session(db, user_id, session_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/{session_id}/restore",
    summary="削除の取り消し",
    response_model=UpdatedAtResponse,
    dependencies=[Depends(require_json_content_type)],
    responses=error_responses({404: _USER_OR_SESSION_NOT_FOUND, **_BODY, **_AUTH, **_VALIDATION}),
)
async def restore_session(
    user_id: TargetUserId,
    session_id: uuid.UUID,
    body: SessionEdit,
    db: DbSession,
) -> UpdatedAtResponse:
    """削除済みのsessionを復活させ、可変の項目も同時に反映する(削除と編集が競合したときに使う)。

    - 既に復活済みなら修正(PATCH)と同じ扱いで200
    - パージ済みなら404 `session_not_found`(復活させる対象が無いので、登録のPOSTで作り直す)
    """
    updated_at = await session_service.edit_session(db, user_id, session_id, body, restore=True)
    return UpdatedAtResponse(updated_at=updated_at)
