"""認証・ユーザーのリクエスト/レスポンスの型と入力チェック。仕様はbackend/docs/API設計ドラフト.mdの「認証のendpoints」。"""

import uuid
from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, EmailStr, Field, StringConstraints

# パスワードは8〜128文字。文字の種類は強制しない(MFAは無い。NISTの「パスワードのみなら15文字以上」の推奨とは意識的に違えている)
Password = Annotated[str, StringConstraints(min_length=8, max_length=128)]
DisplayName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=50)]
DeviceName = Annotated[str, StringConstraints(max_length=100)]

_DEVICE_ID_DESCRIPTION = "端末ID。アプリの初回起動時に生成したUUID(同じ端末として扱い続けるため、ログアウトしても変えない)"
_DEVICE_NAME_DESCRIPTION = "端末の表示名(省略可。今のアプリは送らない)"


class SignupRequest(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "email": "taro@example.com",
                    "password": "correct-horse",
                    "display_name": "たろう",
                    "device_id": "33333333-3333-3333-3333-333333333333",
                }
            ]
        },
    )

    # 長さ(254文字まで)はemail-validatorが確認する
    email: EmailStr = Field(description="メールアドレス。大文字小文字を区別せず一意")
    password: Password = Field(description="パスワード(8〜128文字)")
    display_name: DisplayName | None = Field(
        default=None, description="表示名(1〜50文字)。省略時はメールアドレスの@より前"
    )
    device_id: uuid.UUID = Field(description=_DEVICE_ID_DESCRIPTION)
    device_name: DeviceName | None = Field(default=None, description=_DEVICE_NAME_DESCRIPTION)


class LoginRequest(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "email": "taro@example.com",
                    "password": "correct-horse",
                    "device_id": "33333333-3333-3333-3333-333333333333",
                }
            ]
        },
    )

    # 形式のチェックはしない(登録済みのメールアドレスと一致するかだけを見る)
    email: str = Field(max_length=255, description="メールアドレス")
    password: str = Field(max_length=128, description="パスワード")
    device_id: uuid.UUID = Field(description=_DEVICE_ID_DESCRIPTION)
    device_name: DeviceName | None = Field(default=None, description=_DEVICE_NAME_DESCRIPTION)


class RefreshRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    refresh_token: str = Field(max_length=200, description="最後に受け取ったリフレッシュトークン")


class UpdateMeRequest(BaseModel):
    # メールアドレスの変更(11月以降)・パスワードの変更(ブロック3)は別のendpointで行うので、それ以外の項目は422にする
    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [{"display_name": "たろう"}]})

    display_name: DisplayName = Field(description="表示名(1〜50文字)")


class ChangePasswordRequest(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        json_schema_extra={
            "examples": [{"current_password": "correct-horse", "new_password": "battery-staple"}]
        },
    )

    # 形式のチェックはしない(登録済みのパスワードと一致するかだけを見る。ログインと同じ)
    current_password: str = Field(max_length=128, description="現在のパスワード")
    new_password: Password = Field(description="新しいパスワード(8〜128文字。サインアップと同じ条件)")


# 確認コードは6桁の数字(先頭の0を含む文字列)。形式が違うものは照合せず422にする(入力の失敗の回数にも数えない)
VerificationCode = Annotated[str, StringConstraints(pattern=r"^[0-9]{6}$")]


class ConfirmEmailRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [{"code": "012345"}]})

    code: VerificationCode = Field(description="メールで届いた6桁の確認コード")


class EmailVerificationSentResponse(BaseModel):
    """確認コードの送信のレスポンス。メールは送信待ちに積んだだけで、workerが数秒以内に送る。"""

    model_config = ConfigDict(json_schema_extra={"examples": [{"expires_in": 600, "resend_available_in": 60}]})

    expires_in: int = Field(description="送ったコードの有効期限までの秒数")
    resend_available_in: int = Field(
        description="次に再送できるまでの秒数(画面の再送ボタンのカウントダウンに使う)"
    )


class UserResponse(BaseModel):
    id: uuid.UUID
    email: str
    display_name: str
    email_verified: bool = Field(description="メールアドレスの確認が済んでいるか。falseなら同期APIは403(email_not_verified)")
    role: str = Field(description="user(一般ユーザー)・admin(管理者)")
    created_at: datetime | None


class TokenResponse(BaseModel):
    """signup・login・refreshのレスポンス。"""

    access_token: str = Field(description="ES256のJWT(有効期限15分)。Authorization: Bearer で送る")
    refresh_token: str = Field(
        description="リフレッシュトークン(有効期限30日)。次の更新で使い、使うたびに新しいものに取り替える"
    )
    token_type: str = Field(default="Bearer")
    expires_in: int = Field(description="アクセストークンの有効期限までの秒数")
    user: UserResponse
