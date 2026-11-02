from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.errors import ErrorCode


class ErrorDetail(BaseModel):
    """入力チェックの失敗(422)で、どの項目がなぜ不正かを表す。"""

    field: str = Field(
        description=(
            "不正だった項目の場所。受け取った場所(body/query/path/header)と項目名をドットでつなぐ"
            "(例: body.move_method、query.last_synced_at、body.track_points.0.latitude)"
        ),
    )
    reason: str = Field(description="不正な理由(人が読むための説明)")


class ErrorResponse(BaseModel):
    """全てのエラーレスポンス(4xx・5xx)のbody。"""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {"code": "session_not_found", "message": "セッションが見つかりません"},
                {
                    "code": "validation_error",
                    "message": "入力が不正です",
                    "details": [{"field": "body.move_method", "reason": "Input should be 'walk', ..."}],
                },
            ]
        }
    )

    code: str = Field(description="エラーの種類。クライアントはこれで処理を分岐する")
    message: str = Field(description="人が読むための説明。クライアントは分岐に使わない")
    details: list[ErrorDetail] | None = Field(
        default=None,
        description="422のときだけ含める(それ以外のエラーではキー自体を含めない)",
    )


# OpenAPIのレスポンスの説明に載せる、codeごとの意味(API設計書の「codeの一覧」と同じ内容)
ERROR_CODE_DESCRIPTIONS: dict[ErrorCode, str] = {
    ErrorCode.UNAUTHENTICATED: "トークンが無い・不正・持ち主がいない",
    ErrorCode.TOKEN_EXPIRED: "アクセストークンの有効期限切れ(トークンを更新してやり直す)",
    ErrorCode.FORBIDDEN: "その操作の権限が無い",
    ErrorCode.INVALID_CREDENTIALS: "メールアドレスまたはパスワードが違う",
    ErrorCode.INVALID_REFRESH_TOKEN: "リフレッシュトークンが無効(再ログインする)",
    ErrorCode.ACCOUNT_DISABLED: "アカウントが停止されている",
    ErrorCode.EMAIL_NOT_VERIFIED: "メールアドレスが未確認なので同期できない",
    ErrorCode.EMAIL_ALREADY_REGISTERED: "メールアドレスが登録済み",
    ErrorCode.INVALID_CURRENT_PASSWORD: "現在のパスワードが違う",
    ErrorCode.EMAIL_ALREADY_VERIFIED: "メールアドレスは確認済み(確認コードを送らない)",
    ErrorCode.INVALID_VERIFICATION_CODE: "確認コードが違う(入力し直す)",
    ErrorCode.VERIFICATION_CODE_EXPIRED: "有効な確認コードが無い(期限切れ・失敗の上限に達した・未送信。再送する)",
    ErrorCode.TOO_MANY_REQUESTS: (
        "送信の間隔・回数、またはログイン・パスワードの確認の試行回数の上限に達した(Retry-Afterヘッダーの秒数だけ待つ)"
    ),
    ErrorCode.USER_NOT_FOUND: "パスのuser_idのユーザーが存在しない",
    ErrorCode.SESSION_NOT_FOUND: "当該ユーザーのsessionとして存在しない(パージ済み・未登録・他ユーザーのもの)",
    ErrorCode.NOT_FOUND: "存在しないパス",
    ErrorCode.METHOD_NOT_ALLOWED: "そのパスでは使えないメソッド",
    ErrorCode.NOT_ACCEPTABLE: "Acceptでapplication/jsonを受け付けていない",
    ErrorCode.ID_CONFLICTED: "idが別のsessionと衝突している(idを振り直して登録し直す)",
    ErrorCode.DELETED: "sessionが削除済み(tombstone)で、編集内容と競合している",
    ErrorCode.PAYLOAD_TOO_LARGE: "bodyがサイズの上限(10MB)を超えている",
    ErrorCode.UNSUPPORTED_MEDIA_TYPE: "Content-Typeがapplication/jsonでない",
    ErrorCode.VALIDATION_ERROR: "入力チェックの失敗(detailsにどの項目がなぜ不正かを入れる)",
    ErrorCode.INTERNAL_ERROR: "想定外のエラー",
}


def error_responses(errors: dict[int, list[ErrorCode]]) -> dict[int | str, dict[str, Any]]:
    """エンドポイントの`responses`に渡す、ステータスごとのエラーの説明を作る。

    例: error_responses({404: [ErrorCode.USER_NOT_FOUND], 422: [ErrorCode.VALIDATION_ERROR]})
    descriptionには、そのステータスで返るcodeとその意味を列挙する。
    """
    return {
        status_code: {
            "model": ErrorResponse,
            "description": "<br>".join(
                f"`{code}`: {ERROR_CODE_DESCRIPTIONS[code]}" for code in codes
            ),
        }
        for status_code, codes in errors.items()
    }
