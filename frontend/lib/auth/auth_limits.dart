// 入力の長さの制限。サーバーの入力チェック(backend/app/schemas/auth.py)と揃える
// (新規登録・パスワードの変更・表示名の編集で共通)
const int minPasswordLength = 8;
const int maxPasswordLength = 128;
const int maxDisplayNameLength = 50;
