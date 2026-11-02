"""同期API(/api/users/{user_id}/sessions)のテスト。API設計書(backend/docs/API設計ドラフト.md)の処理の手順ごとに確認する。

各テストはconftestのdb_sessionのトランザクションの中で動き、最後にロールバックされる。
"""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient

from app.models import User

STARTED_AT = "2026-10-01T08:00:00Z"
ENDED_AT = "2026-10-01T08:30:00Z"


def sessions_url(user_id: uuid.UUID) -> str:
    return f"/api/users/{user_id}/sessions"


def session_url(user_id: uuid.UUID, session_id: uuid.UUID | str) -> str:
    return f"{sessions_url(user_id)}/{session_id}"


def new_session_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "id": str(uuid.uuid4()),
        "name": "近所のお散歩",
        "started_at": STARTED_AT,
        "ended_at": ENDED_AT,
        "is_favorite": False,
        "move_method": "walk",
        "total_distance": 2.0,
        "duration_seconds": 1800,
        "elevation_gain": 12.345678901234,
        "max_altitude": 30.5,
        "min_altitude": None,
        "track_points": [
            {
                "recorded_at": "2026-10-01T08:00:00Z",
                "latitude": 35.681236,
                "longitude": 139.767125,
                "altitude": 10.5,
            },
            {
                "recorded_at": "2026-10-01T08:00:05Z",
                "latitude": 35.6813,
                "longitude": 139.7672,
                "altitude": 11.25,
            },
        ],
    }
    payload.update(overrides)
    return payload


def edit_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {"name": "近所のお散歩", "move_method": "walk", "is_favorite": False}
    payload.update(overrides)
    return payload


async def register(client: AsyncClient, user: User, **overrides: Any) -> dict[str, Any]:
    payload = new_session_payload(**overrides)
    response = await client.post(sessions_url(user.id), json=payload)
    assert response.status_code == 201, response.text
    return payload


async def fetch(client: AsyncClient, user: User, last_synced_at: str | None = None) -> dict:
    params = {} if last_synced_at is None else {"last_synced_at": last_synced_at}
    response = await client.get(sessions_url(user.id), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def parse_time(value: str) -> datetime:
    # Python 3.11以降のfromisoformatは"Z"(UTC)をそのまま読める
    return datetime.fromisoformat(value)


# ---- GET(差分取得) ---------------------------------------------------------------


async def test_initial_fetch_returns_alive_sessions_with_track_points(
    api_client: AsyncClient, user: User
):
    later = await register(
        api_client, user, started_at="2026-10-02T08:00:00Z", ended_at="2026-10-02T09:00:00Z"
    )
    earlier = await register(api_client, user)
    deleted = await register(api_client, user)
    await api_client.delete(session_url(user.id, deleted["id"]))

    body = await fetch(api_client, user)

    assert body["request_existence_check"] is False
    assert parse_time(body["synced_at"]).tzinfo is not None
    # 初回の同期では削除済みを返さず、started_atの昇順に並ぶ
    assert [s["id"] for s in body["sessions"]] == [earlier["id"], later["id"]]
    session = body["sessions"][0]
    assert session["elevation_gain"] == earlier["elevation_gain"]
    assert session["min_altitude"] is None
    assert session["track_points"] == [
        {
            "recorded_at": "2026-10-01T08:00:00Z",
            "latitude": 35.681236,
            "longitude": 139.767125,
            "altitude": 10.5,
        },
        {
            "recorded_at": "2026-10-01T08:00:05Z",
            "latitude": 35.6813,
            "longitude": 139.7672,
            "altitude": 11.25,
        },
    ]


async def test_fetch_does_not_return_other_users_sessions(
    api_client: AsyncClient, user: User, other_api_client: AsyncClient, other_user: User
):
    await register(other_api_client, other_user)

    body = await fetch(api_client, user)

    assert body["sessions"] == []


async def test_diff_fetch_returns_changes_since_last_synced_at_including_tombstones(
    api_client: AsyncClient, user: User
):
    unchanged = await register(api_client, user)
    edited = await register(api_client, user)
    deleted = await register(api_client, user)
    synced_at = (await fetch(api_client, user))["synced_at"]

    await api_client.patch(session_url(user.id, edited["id"]), json=edit_payload(name="変更後"))
    await api_client.delete(session_url(user.id, deleted["id"]))
    body = await fetch(api_client, user, last_synced_at=synced_at)

    by_id = {s["id"]: s for s in body["sessions"]}
    assert unchanged["id"] not in by_id
    assert by_id[edited["id"]]["name"] == "変更後"
    # 削除済みはidとdeleted_atだけを返す
    assert set(by_id[deleted["id"]]) == {"id", "deleted_at"}
    assert body["request_existence_check"] is False


async def test_fetch_with_last_synced_at_older_than_retention_requests_existence_check(
    api_client: AsyncClient, user: User
):
    old = (datetime.now(UTC) - timedelta(days=91)).isoformat().replace("+00:00", "Z")

    body = await fetch(api_client, user, last_synced_at=old)

    assert body["request_existence_check"] is True


async def test_fetch_with_future_last_synced_at_is_validation_error(
    api_client: AsyncClient, user: User
):
    future = (datetime.now(UTC) + timedelta(days=1)).isoformat().replace("+00:00", "Z")

    response = await api_client.get(sessions_url(user.id), params={"last_synced_at": future})

    assert response.status_code == 422
    assert response.json()["details"][0]["field"] == "query.last_synced_at"


async def test_fetch_with_naive_last_synced_at_is_validation_error(
    api_client: AsyncClient, user: User
):
    # タイムゾーンの無い日時は受け付けない(端末とサーバーで解釈がずれるため)
    response = await api_client.get(
        sessions_url(user.id), params={"last_synced_at": "2026-10-01T08:00:00"}
    )

    assert response.status_code == 422
    assert response.json()["code"] == "validation_error"


async def test_fetch_other_or_unknown_user_as_user_is_forbidden(
    api_client: AsyncClient, other_user: User
):
    # 一般ユーザーは自分以外のuser_idを指定すると403で止まる(他ユーザーの有無は分からない)
    for target in (other_user.id, uuid.uuid4()):
        response = await api_client.get(sessions_url(target))
        assert response.status_code == 403
        assert response.json()["code"] == "forbidden"


async def test_fetch_as_admin(client_factory, admin_user: User, other_user: User):
    admin_client = await client_factory(admin_user)

    # 管理者は他ユーザーのsessionsを操作でき、存在しないuser_idなら404
    assert (await admin_client.get(sessions_url(other_user.id))).status_code == 200
    response = await admin_client.get(sessions_url(uuid.uuid4()))
    assert response.status_code == 404
    assert response.json()["code"] == "user_not_found"


async def test_admin_can_read_and_edit_other_users_sessions(
    client_factory, admin_user: User, other_api_client: AsyncClient, other_user: User
):
    """RLSのポリシーで、管理者は他ユーザーの行も読み書きできる(監査ログのcommitを挟んでも今のユーザーが渡る)。"""
    payload = await register(other_api_client, other_user)
    admin_client = await client_factory(admin_user)

    body = await fetch(admin_client, other_user)
    assert [s["id"] for s in body["sessions"]] == [payload["id"]]
    assert len(body["sessions"][0]["track_points"]) == 2

    response = await admin_client.patch(
        session_url(other_user.id, payload["id"]), json=edit_payload(name="管理者が修正")
    )
    assert response.status_code == 200, response.text
    assert (await fetch(other_api_client, other_user))["sessions"][0]["name"] == "管理者が修正"


async def test_fetch_with_non_json_accept_returns_not_acceptable(
    api_client: AsyncClient, user: User
):
    response = await api_client.get(sessions_url(user.id), headers={"Accept": "text/html"})

    assert response.status_code == 406
    assert response.json()["code"] == "not_acceptable"


# ---- POST(登録) -----------------------------------------------------------------


async def test_register_returns_201_and_server_time(api_client: AsyncClient, user: User):
    before = datetime.now(UTC) - timedelta(minutes=1)

    response = await api_client.post(sessions_url(user.id), json=new_session_payload())

    assert response.status_code == 201
    # updated_atはサーバー時刻(端末が送った値ではない)
    assert parse_time(response.json()["updated_at"]) > before


async def test_resend_with_same_content_returns_200_without_changing_updated_at(
    api_client: AsyncClient, user: User
):
    payload = new_session_payload()
    first = await api_client.post(sessions_url(user.id), json=payload)

    second = await api_client.post(sessions_url(user.id), json=payload)

    assert second.status_code == 200
    assert second.json()["updated_at"] == first.json()["updated_at"]


async def test_resend_with_edited_mutable_fields_updates_them(api_client: AsyncClient, user: User):
    payload = await register(api_client, user)

    # レスポンスが返らない間にローカルで編集されてから再送された場合
    response = await api_client.post(
        sessions_url(user.id), json={**payload, "name": "再送前に編集", "is_favorite": True}
    )

    assert response.status_code == 200
    session = (await fetch(api_client, user))["sessions"][0]
    assert session["name"] == "再送前に編集"
    assert session["is_favorite"] is True
    assert session["updated_at"] == response.json()["updated_at"]


async def test_resend_with_different_immutable_fields_is_id_conflict(
    api_client: AsyncClient, user: User
):
    payload = await register(api_client, user)

    response = await api_client.post(sessions_url(user.id), json={**payload, "total_distance": 3.0})

    assert response.status_code == 409
    assert response.json()["code"] == "id_conflicted"


async def test_register_with_other_users_session_id_is_id_conflict(
    api_client: AsyncClient, user: User, other_api_client: AsyncClient, other_user: User
):
    payload = await register(other_api_client, other_user)

    # 中身が同じでも、他ユーザーのsessionのidなら衝突として扱う
    response = await api_client.post(sessions_url(user.id), json=payload)

    assert response.status_code == 409
    assert response.json()["code"] == "id_conflicted"


async def test_resend_of_deleted_session_without_edit_returns_200(
    api_client: AsyncClient, user: User
):
    payload = await register(api_client, user)
    await api_client.delete(session_url(user.id, payload["id"]))

    response = await api_client.post(sessions_url(user.id), json=payload)

    assert response.status_code == 200


async def test_resend_of_deleted_session_with_edit_is_deleted_conflict(
    api_client: AsyncClient, user: User
):
    payload = await register(api_client, user)
    await api_client.delete(session_url(user.id, payload["id"]))

    response = await api_client.post(sessions_url(user.id), json={**payload, "name": "編集済み"})

    assert response.status_code == 409
    assert response.json()["code"] == "deleted"


async def test_register_validation_errors(api_client: AsyncClient, user: User):
    cases = {
        "body": new_session_payload(ended_at="2026-10-01T07:00:00Z"),  # ended_at < started_at
        "body.move_method": new_session_payload(move_method="rocket"),
        "body.name": new_session_payload(name=""),
        "body.total_distance": new_session_payload(total_distance=-1),
        "body.track_points.0.latitude": new_session_payload(
            track_points=[
                {
                    "recorded_at": STARTED_AT,
                    "latitude": 91,
                    "longitude": 0,
                    "altitude": 10.0,
                }
            ]
        ),
        # 高度はnullを許さない(frontendが信頼度の低い高度を前回の値で補ってから送る前提)
        "body.track_points.0.altitude": new_session_payload(
            track_points=[
                {
                    "recorded_at": STARTED_AT,
                    "latitude": 35.0,
                    "longitude": 139.0,
                    "altitude": None,
                }
            ]
        ),
    }
    for expected_field, payload in cases.items():
        response = await api_client.post(sessions_url(user.id), json=payload)
        assert response.status_code == 422, expected_field
        fields = [detail["field"] for detail in response.json()["details"]]
        assert expected_field in fields, (expected_field, fields)


async def test_register_with_non_json_content_type_is_unsupported_media_type(
    api_client: AsyncClient, user: User
):
    response = await api_client.post(
        sessions_url(user.id), content="id=1", headers={"Content-Type": "text/plain"}
    )

    assert response.status_code == 415
    assert response.json()["code"] == "unsupported_media_type"


# ---- PATCH(修正) ----------------------------------------------------------------


async def test_edit_updates_mutable_fields_and_updated_at(api_client: AsyncClient, user: User):
    payload = await register(api_client, user)
    registered_at = (await fetch(api_client, user))["sessions"][0]["updated_at"]

    response = await api_client.patch(
        session_url(user.id, payload["id"]),
        json=edit_payload(name="変更後", move_method="run", is_favorite=True),
    )

    assert response.status_code == 200
    assert parse_time(response.json()["updated_at"]) > parse_time(registered_at)
    session = (await fetch(api_client, user))["sessions"][0]
    assert (session["name"], session["move_method"], session["is_favorite"]) == (
        "変更後",
        "run",
        True,
    )


async def test_edit_with_same_values_does_not_change_updated_at(
    api_client: AsyncClient, user: User
):
    payload = await register(api_client, user)
    registered_at = (await fetch(api_client, user))["sessions"][0]["updated_at"]

    response = await api_client.patch(session_url(user.id, payload["id"]), json=edit_payload())

    assert response.status_code == 200
    assert response.json()["updated_at"] == registered_at


async def test_edit_deleted_session_is_deleted_conflict(api_client: AsyncClient, user: User):
    payload = await register(api_client, user)
    await api_client.delete(session_url(user.id, payload["id"]))

    response = await api_client.patch(session_url(user.id, payload["id"]), json=edit_payload())

    assert response.status_code == 409
    assert response.json()["code"] == "deleted"


async def test_edit_other_users_or_unknown_session_returns_session_not_found(
    api_client: AsyncClient, user: User, other_api_client: AsyncClient, other_user: User
):
    others = await register(other_api_client, other_user)

    for session_id in (others["id"], str(uuid.uuid4())):
        response = await api_client.patch(session_url(user.id, session_id), json=edit_payload())
        assert response.status_code == 404
        assert response.json()["code"] == "session_not_found"


async def test_edit_with_immutable_field_is_validation_error(api_client: AsyncClient, user: User):
    payload = await register(api_client, user)

    response = await api_client.patch(
        session_url(user.id, payload["id"]), json={**edit_payload(), "started_at": STARTED_AT}
    )

    assert response.status_code == 422
    assert [d["field"] for d in response.json()["details"]] == ["body.started_at"]


# ---- DELETE(削除) ----------------------------------------------------------------


async def test_delete_makes_tombstone_and_repeated_delete_keeps_deleted_at(
    api_client: AsyncClient, user: User
):
    payload = await register(api_client, user)
    synced_at = (await fetch(api_client, user))["synced_at"]

    first = await api_client.delete(session_url(user.id, payload["id"]))
    tombstone = (await fetch(api_client, user, last_synced_at=synced_at))["sessions"][0]
    second = await api_client.delete(session_url(user.id, payload["id"]))
    tombstone_after = (await fetch(api_client, user, last_synced_at=synced_at))["sessions"][0]

    assert first.status_code == 204
    assert second.status_code == 204
    assert tombstone["id"] == payload["id"]
    # 既に削除済みならdeleted_atを更新しない
    assert tombstone_after["deleted_at"] == tombstone["deleted_at"]


async def test_delete_unknown_session_returns_session_not_found(
    api_client: AsyncClient, user: User
):
    response = await api_client.delete(session_url(user.id, uuid.uuid4()))

    assert response.status_code == 404
    assert response.json()["code"] == "session_not_found"


# ---- restore(削除の取り消し) ------------------------------------------------------


async def test_restore_brings_back_deleted_session_with_edits(api_client: AsyncClient, user: User):
    payload = await register(api_client, user)
    await api_client.delete(session_url(user.id, payload["id"]))

    response = await api_client.post(
        f"{session_url(user.id, payload['id'])}/restore", json=edit_payload(name="復活時の編集")
    )

    assert response.status_code == 200
    sessions = (await fetch(api_client, user))["sessions"]
    assert [s["id"] for s in sessions] == [payload["id"]]
    assert sessions[0]["name"] == "復活時の編集"
    assert len(sessions[0]["track_points"]) == 2


async def test_restore_alive_session_behaves_like_edit(api_client: AsyncClient, user: User):
    payload = await register(api_client, user)
    registered_at = (await fetch(api_client, user))["sessions"][0]["updated_at"]

    same = await api_client.post(
        f"{session_url(user.id, payload['id'])}/restore", json=edit_payload()
    )

    assert same.status_code == 200
    assert same.json()["updated_at"] == registered_at


async def test_restore_unknown_session_returns_session_not_found(
    api_client: AsyncClient, user: User
):
    response = await api_client.post(
        f"{session_url(user.id, uuid.uuid4())}/restore", json=edit_payload()
    )

    assert response.status_code == 404
    assert response.json()["code"] == "session_not_found"


# ---- existence-check(削除の突き合わせ) ----------------------------------------------


async def test_existence_check_returns_ids_not_alive_for_the_user(
    api_client: AsyncClient, user: User, other_api_client: AsyncClient, other_user: User
):
    alive = await register(api_client, user)
    deleted = await register(api_client, user)
    await api_client.delete(session_url(user.id, deleted["id"]))
    others = await register(other_api_client, other_user)
    unknown = str(uuid.uuid4())

    response = await api_client.post(
        f"{sessions_url(user.id)}/existence-check",
        json={"session_ids": [alive["id"], deleted["id"], others["id"], unknown, unknown]},
    )

    assert response.status_code == 200
    # tombstone・他ユーザーのもの・未登録は「存在しない」。重複は1つにまとめる
    assert sorted(response.json()["missing_session_ids"]) == sorted(
        [deleted["id"], others["id"], unknown]
    )


async def test_existence_check_with_empty_ids_returns_empty(api_client: AsyncClient, user: User):
    response = await api_client.post(
        f"{sessions_url(user.id)}/existence-check", json={"session_ids": []}
    )

    assert response.status_code == 200
    assert response.json() == {"missing_session_ids": []}
