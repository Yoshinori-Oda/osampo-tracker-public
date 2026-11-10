# コマンド集

開発でよく使うコマンドを場面ごとにまとめる。手順の意味・前提は`docs/development.md`を参照。
`<run_id>`は実行を識別する任意の文字列(`docs/development.md`の「テスト」)。

## 初回の準備

`backend`ディレクトリで実行する。`backend/secrets/`はコミットしない。

```bash
# アクセストークンを署名するES256の鍵のペア(初回のみ)
mkdir -p secrets
openssl ecparam -name prime256v1 -genkey -noout -out secrets/jwt_private.pem
openssl ec -in secrets/jwt_private.pem -pubout -out secrets/jwt_public.pem

# HTTPSの証明書(初回と、約2年後の期限切れの前。mkcert -installは実行しない)
mkdir -p secrets/tls
mkcert -cert-file secrets/tls/cert.pem -key-file secrets/tls/key.pem localhost 127.0.0.1 10.0.2.2

# iOSシミュレータにmkcertのCAを入れる(シミュレータを起動した状態で。作り直し・初期化したら入れ直す)
xcrun simctl keychain booted add-root-cert "$(mkcert -CAROOT)/rootCA.pem"
```

## 起動

```bash
# backend(backendディレクトリで)。イメージのビルドとマイグレーション
scripts/run_checks.sh <run_id> up migrate
# backend。依存パッケージ・Dockerfile・composeを変えていなければ
docker compose up -d
# backendの停止(DBのボリュームは残る)
docker compose down
# HTTPSでつながるかの確認
curl --cacert "$(mkcert -CAROOT)/rootCA.pem" https://localhost/api/

# frontend(frontendディレクトリで)。同期先は既定でhttps://localhost/api(iOSシミュレータ)
flutter pub get
flutter run
```

## DBの作り直し・シード

`backend`ディレクトリで実行する。

```bash
# DBのボリュームごと作り直す(データは消える)
docker compose down -v
scripts/run_checks.sh <run_id> up migrate
# 開発用のダミーデータ(テーブルの所有者のロールで入れる)
docker compose exec -T db psql -U osampo_migrator -d location_db < db/seed.sql
# 開発用のユーザー(管理者・テストユーザー1111...・メール未確認のユーザー)のパスワード等を設定する。ログイン情報が表示される
docker compose run --rm api python -m app.cli seed-dev
```

## チェック (run_checks.sh)

結果は`host_check_logs/<timestamp>_<run_id>_<結果>/`に残る。まず`SUMMARY.md`を読む。

```bash
# frontend(frontendディレクトリで)
# 静的解析 + ユニット/ウィジェットテスト(既定)
scripts/run_checks.sh <run_id>
# テスト対象を絞る
scripts/run_checks.sh <run_id> analyze test -t test/xxx_test.dart
# コード生成(Driftのテーブル定義を変えたとき)を含める。worktreeを作った直後はpubgetも
scripts/run_checks.sh <run_id> pubget codegen analyze test
# E2Eまで全部(シミュレータ/実機の起動後に)
scripts/run_checks.sh <run_id> all
# E2Eのみ(デバイスを既定と変える場合のみ -d)
scripts/run_e2e_tests.sh <run_id> -d <device_id>
# 機能紹介用のスクリーンショット
scripts/run_checks.sh <run_id> e2e -e integration_test/showcase_test.dart

# backend(どこから実行してもよい。サービスは起動済みの前提)
# マイグレーション + スキーマの差分確認 + lint + テスト(既定)
scripts/run_checks.sh <run_id>
# 起動(イメージの作り直し)から全部
scripts/run_checks.sh <run_id> all
# 依存パッケージを変えた場合
scripts/run_checks.sh <run_id> lock up migrate check lint test
# テスト対象を絞る
scripts/run_checks.sh <run_id> test -t tests/test_models.py
```

## ログ

`backend`ディレクトリで実行する。

```bash
docker compose logs proxy
docker compose logs api
docker compose logs worker
# 端末のログに出たリクエストIDで、proxyとapiのログを突き合わせる
docker compose logs proxy api | grep <リクエストID>
```

## 管理用のコマンド

`backend`ディレクトリで実行する。

```bash
# アカウントの停止・解除(管理者の画面ができるまでの手段)
docker compose run --rm api python -m app.cli disable-user <email>
docker compose run --rm api python -m app.cli enable-user <email>
# テストメールをoutboxに積む(workerが数秒以内にmailpitへ送る。http://localhost:8025 で確認)
docker compose run --rm api python -m app.cli send-test-mail test@example.com
# JWTの鍵がapiのコンテナから見えるかの確認
docker compose exec api ls -la /app/secrets
```
