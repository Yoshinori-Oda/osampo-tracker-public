"""エラーのcodeとアプリ独自の例外。

レスポンスの形式・codeの意味はbackend/docs/API設計ドラフト.mdの「共通事項」を参照。
services層などで処理を続けられない場合はAppErrorを投げる。AppErrorはapp/error_handlers.pyのハンドラーで
`{"code": ..., "message": ..., "details": [...]}`のJSONレスポンスに変換される(SpringのControllerAdviceに相当)。
"""

from enum import StrEnum


class ErrorCode(StrEnum):
    """エラーの種類。クライアントはこれで処理を分岐する(messageは人が読むためのもので分岐に使わない)。"""

    # 認証と権限
    UNAUTHENTICATED = "unauthenticated"  # 401: トークンが無い・不正・持ち主がいない
    TOKEN_EXPIRED = "token_expired"  # 401: アクセストークンの有効期限切れ(クライアントはトークンを更新する)
    FORBIDDEN = "forbidden"  # 403: 認証はできたが、その操作の権限が無い
    INVALID_CREDENTIALS = "invalid_credentials"  # 401: ログインの失敗(ユーザーが無い・パスワードが違うを区別しない)
    INVALID_REFRESH_TOKEN = "invalid_refresh_token"  # 401: リフレッシュトークンが無効(クライアントは再ログインする)
    ACCOUNT_DISABLED = "account_disabled"  # 403: アカウントが停止されている(パスワードが合っていた場合のみ)
    EMAIL_NOT_VERIFIED = "email_not_verified"  # 403: メールアドレスが未確認なので同期APIを使えない
    EMAIL_ALREADY_REGISTERED = "email_already_registered"  # 409: サインアップのメールアドレスが登録済み
    # 400: パスワードの変更で、現在のパスワードが違う(401にすると、クライアントがログイン状態の無効と区別できない)
    INVALID_CURRENT_PASSWORD = "invalid_current_password"

    # メールアドレスの確認コード
    EMAIL_ALREADY_VERIFIED = "email_already_verified"  # 409: 確認済みなので確認コードを送らない
    INVALID_VERIFICATION_CODE = "invalid_verification_code"  # 400: 確認コードが違う(入力し直せる)
    VERIFICATION_CODE_EXPIRED = "verification_code_expired"  # 400: 有効な確認コードが無い(再送が必要)
    # 429: 送信の間隔・回数の上限、ログイン・パスワードの確認の試行回数の上限。Retry-Afterの秒数だけ待つ
    TOO_MANY_REQUESTS = "too_many_requests"

    # リソース
    USER_NOT_FOUND = "user_not_found"  # 404: パスパラメーターのuser_idのユーザーが存在しない
    SESSION_NOT_FOUND = "session_not_found"  # 404: 当該ユーザーのsessionとして存在しない
    ID_CONFLICTED = "id_conflicted"  # 409: 登録しようとしたidが別のsessionと衝突している
    DELETED = "deleted"  # 409: 対象のsessionが削除済み(tombstone)で、編集内容と競合している

    # リクエストの形式(FastAPI・Starletteが既定で返すエラーもこれらに変換する)
    NOT_FOUND = "not_found"  # 404: 存在しないパス
    METHOD_NOT_ALLOWED = "method_not_allowed"  # 405
    NOT_ACCEPTABLE = "not_acceptable"  # 406: Acceptでapplication/jsonを受け付けていない
    PAYLOAD_TOO_LARGE = "payload_too_large"  # 413: bodyがサイズの上限を超えている
    UNSUPPORTED_MEDIA_TYPE = "unsupported_media_type"  # 415: Content-Typeがapplication/jsonでない
    VALIDATION_ERROR = "validation_error"  # 422: 入力チェックの失敗。detailsにどの項目がなぜ不正かを入れる

    # その他
    HTTP_ERROR = "http_error"  # 上記に当てはまらないHTTPのエラー
    INTERNAL_ERROR = "internal_error"  # 500: 想定外のエラー(詳細はログにのみ出す)


class AppError(Exception):
    """クライアントに返すエラー。投げるとハンドラーがcodeとmessageのJSONレスポンスに変換する。"""

    def __init__(
        self,
        status_code: int,
        code: ErrorCode,
        message: str,
        details: list[dict[str, str]] | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details
        # レスポンスに付けるヘッダー(429のRetry-After等)
        self.headers = headers
