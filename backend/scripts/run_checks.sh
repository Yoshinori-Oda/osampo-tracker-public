#!/usr/bin/env bash
# ホスト側でbackendの各種チェック(マイグレーション・スキーマの差分確認・lint・テスト)をdocker compose経由で実行し、
# 結果をすべてファイルへ保存する。コンテナ(Claude Code)からはDockerを使えないため、ホストで実行した結果を
# このログ経由で読ませる。frontend/scripts/run_checks.shのbackend版。
#
# 使い方(どこから実行してもよい):
#   backend/scripts/run_checks.sh <run_id> [step...] [-t <test_path>]...
#   backend/scripts/run_checks.sh --id <run_id> [step...] [--test <test_path>]...
#
# step (記述順ではなく下記の順で実行する。省略時は migrate check lint test):
#   lock     uv lock (pyproject.tomlの依存パッケージを変えた場合。uvのDockerイメージで実行する)
#   up       docker compose up -d --build (依存パッケージ・Dockerfile・composeを変えた場合、初回起動時)
#   migrate  開発用・テスト用の両方のデータベースに alembic upgrade head する
#   check    alembic check (モデルとDBのスキーマに差分が無いことの確認)
#   lint     ruff check
#   test     pytest (-t/--test で対象ファイル・テストを絞れる。複数指定可。例: -t tests/test_models.py)
#   https    リバースプロキシ越しのHTTPSの確認(curlで証明書・ヘッダー・上限を確かめる。mkcert・curl・opensslが必要)
#   all      up migrate check lint test https
#
# run_id: 「どの依頼に対応する実行結果か」を一意に特定するための相関トークン。
#         テスト内容の説明ではなく、依頼ごとに変わるユニークな文字列を渡すこと
#         (例: Claudeが依頼時に生成した a3f9c21b のような文字列)。
#
# 前提: backend/.env があること(項目は backend/docs/バックエンド構成.md)。up以外のstepはサービスが起動済みであること。
#       httpsとupは、backend/secrets/tls/ にmkcertで作った証明書があること(backend/docs/HTTPSとリバースプロキシ.md)
#
# 結果は backend/host_check_logs/<timestamp>_<run_id>_<PASSED|FAILED>/ に保存される:
#   SUMMARY.md    実行環境(ブランチ/コミット/docker compose)・ステップごとの結果・
#                 alembicのrevision・ruffの指摘・pytestの結果と失敗の詳細・失敗したステップのログ末尾
#   <step>.log    各ステップの標準出力/標準エラーの全文
# (host_check_logs/ は.gitignore済みなのでコミット対象にはならない)
#
# macOS標準のbash 3.2でも動くように書いている(連想配列・mapfile等は使わない)

set -uo pipefail

ALL_STEPS="lock up migrate check lint test https"

usage() {
  echo "使い方: $(basename "$0") <run_id> [step...] [-t <test_path>]..." >&2
  echo "        step: lock up migrate check lint test https all (省略時は migrate check lint test)" >&2
}

RUN_ID=""
REQUESTED_STEPS=""
TEST_TARGETS=()

require_value() {
  if [[ $2 -lt 2 ]]; then
    echo "エラー: $1 には値が必要です" >&2
    usage
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--id)
      require_value "$1" $#
      RUN_ID="$2"
      shift 2
      ;;
    -t|--test)
      require_value "$1" $#
      TEST_TARGETS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "エラー: 想定外のオプションです: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$RUN_ID" ]]; then
        RUN_ID="$1"
      else
        case "$1" in
          all) REQUESTED_STEPS="$REQUESTED_STEPS up migrate check lint test https" ;;
          lock|up|migrate|check|lint|test|https) REQUESTED_STEPS="$REQUESTED_STEPS $1" ;;
          *)
            echo "エラー: 未知のstepです: $1" >&2
            usage
            exit 1
            ;;
        esac
      fi
      shift
      ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  usage
  exit 1
fi

if [[ -z "$REQUESTED_STEPS" ]]; then
  REQUESTED_STEPS="migrate check lint test"
fi

# 指定順・重複に関わらず、依存関係の順(lock → 起動 → マイグレーション → 差分確認 → lint → テスト → HTTPS)で1回ずつ実行する
STEPS=""
for step in $ALL_STEPS; do
  case " $REQUESTED_STEPS " in
    *" $step "*) STEPS="$STEPS $step" ;;
  esac
done
STEPS="${STEPS# }"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_ROOT="$BACKEND_DIR/host_check_logs"

cd "$BACKEND_DIR"

if [[ ! -f .env ]]; then
  echo "エラー: $BACKEND_DIR/.env がありません(項目は backend/docs/バックエンド構成.md)" >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
# ファイル名に使えない文字を潰す
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')"
RUN_DIR="$LOG_ROOT/${TIMESTAMP}_${SAFE_RUN_ID}"
mkdir -p "$RUN_DIR"

echo "run_id: $RUN_ID"
echo "steps: $STEPS"
echo "log dir: $RUN_DIR"

# ---- 実行環境 ----------------------------------------------------------------
# gitが使えない場合(コンテナ側で作ったworktreeをホストから開いていて、.gitの参照先パスが
# ホストに存在しない等)は「なし」と誤表示せず、取得失敗であることとその理由を残す
if GIT_STATUS_OUTPUT="$(git status --porcelain 2>&1)"; then
  GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  GIT_COMMIT="$(git rev-parse --short HEAD)"
  if [[ -n "$GIT_STATUS_OUTPUT" ]]; then
    GIT_DIRTY="あり"
  else
    GIT_DIRTY="なし"
  fi
  GIT_INFO="\`$GIT_BRANCH\` / \`$GIT_COMMIT\` (未コミットの変更: $GIT_DIRTY)"
else
  GIT_INFO="取得失敗 ($(printf '%s' "$GIT_STATUS_OUTPUT" | head -n 1))"
fi
COMPOSE_VERSION="$(docker compose version 2>&1 | head -n 1)"

# ---- ステップ実行 ------------------------------------------------------------
# 結果は "step|PASSED|exit_code|seconds" の形で1行ずつ貯める
RESULTS=""
OVERALL=0

run_step() {
  local step="$1"
  shift
  local log_file="$RUN_DIR/$step.log"

  echo
  echo "===== [$step] $* ====="
  {
    echo "\$ $*"
    echo
  } > "$log_file"

  local start end code
  start=$(date +%s)
  "$@" 2>&1 | tee -a "$log_file"
  code=${PIPESTATUS[0]}
  end=$(date +%s)

  local label=PASSED
  if [[ $code -ne 0 ]]; then
    label=FAILED
    OVERALL=1
  fi
  RESULTS="${RESULTS}${step}|${label}|${code}|$((end - start))"$'\n'
  echo "===== [$step] $label (exit $code, $((end - start))s) ====="
}

# docker compose run: -T で疑似端末を割り当てない(出力をteeでファイルに流すため)
compose_run() {
  docker compose run --rm -T api "$@"
}

lock_dependencies() {
  docker run --rm -v "$BACKEND_DIR":/app -w /app ghcr.io/astral-sh/uv:python3.12-bookworm-slim uv lock
}

migrate_all() {
  echo "--- 開発用のデータベース ---"
  compose_run alembic upgrade head || return $?
  compose_run alembic current || return $?
  echo
  echo "--- テスト用のデータベース ---"
  compose_run alembic -x db=test upgrade head || return $?
  compose_run alembic -x db=test current
}

# ---- https: リバースプロキシ越しの確認 ----------------------------------------
# 各項目を "OK: ..." / "NG: ..." の1行で出し、NGが1つでもあれば失敗にする
HTTPS_BASE="https://localhost"
HTTPS_NG=0

https_ok() { echo "OK: $*"; }
https_ng() { echo "NG: $*"; HTTPS_NG=1; }

# curlで1回リクエストし、ステータスコードを返す。ヘッダーは $HTTPS_TMP/headers、bodyは $HTTPS_TMP/body に入る
https_curl() {
  curl -sS -o "$HTTPS_TMP/body" -D "$HTTPS_TMP/headers" -w '%{http_code}' --cacert "$HTTPS_CA" "$@"
}

# 応答のヘッダーの値(大文字小文字を区別しない。最初の1つ)
https_header() {
  grep -i "^$1:" "$HTTPS_TMP/headers" | head -n 1 | sed -E 's/^[^:]+: *//' | tr -d '\r'
}

https_expect() {
  # $1: 説明, $2: 期待するステータス, $3: 期待するcode(空なら確かめない), $4: 実際のステータス
  local body
  body="$(cat "$HTTPS_TMP/body" 2>/dev/null)"
  if [[ "$4" == "$2" ]] && { [[ -z "$3" ]] || [[ "$body" == *"\"code\":\"$3\""* ]]; }; then
    https_ok "$1 ($4 $3)"
  else
    https_ng "$1 (期待: $2 $3 / 実際: $4 $body)"
  fi
}

https_checks() {
  HTTPS_TMP="$(mktemp -d)"
  local caroot
  if ! caroot="$(mkcert -CAROOT 2>/dev/null)"; then
    echo "NG: mkcertがありません(brew install mkcert)"
    return 1
  fi
  HTTPS_CA="$caroot/rootCA.pem"

  echo "--- proxyの状態(起動していない・unhealthyならログで原因を見る) ---"
  docker compose ps proxy
  docker compose logs --no-log-prefix --tail 20 proxy

  echo
  echo "--- 証明書 ---"
  # macOSのopenssl(LibreSSL)には -ext が無いので、SANは -text から取り出す
  if openssl x509 -noout -subject -enddate -in secrets/tls/cert.pem; then
    openssl x509 -noout -text -in secrets/tls/cert.pem | grep -A 1 'Subject Alternative Name' | tail -n 1 | sed -E 's/^ +/SAN: /'
  else
    https_ng "secrets/tls/cert.pem を読めない"
  fi

  echo
  echo "--- 接続とTLS ---"
  local status
  status="$(https_curl "$HTTPS_BASE/api/")"
  https_expect "localhostにmkcertのCAで検証してつながる(apiの404)" 404 not_found "$status"
  local headers_file="$HTTPS_TMP/headers.localhost"
  cp "$HTTPS_TMP/headers" "$headers_file"
  status="$(https_curl "https://127.0.0.1/api/")"
  https_expect "127.0.0.1でもつながる" 404 not_found "$status"
  if curl -sS -o /dev/null --cacert "$HTTPS_CA" --tls-max 1.1 "$HTTPS_BASE/api/" 2>/dev/null; then
    https_ng "TLS 1.1以下でつながってしまう"
  else
    https_ok "TLS 1.1以下ではつながらない"
  fi
  if curl -sS -o /dev/null -m 5 "http://localhost:80/" 2>/dev/null; then
    https_ng "80番(HTTP)につながってしまう"
  else
    https_ok "80番(HTTP)にはつながらない"
  fi
  if curl -sS -o /dev/null -m 5 "http://localhost:8080/" 2>/dev/null; then
    https_ng "8080番(apiの直接)につながってしまう"
  else
    https_ok "8080番(apiの直接)にはつながらない"
  fi
  local http2
  http2="$(curl -sS -o /dev/null -w '%{http_version}' --http2 --cacert "$HTTPS_CA" "$HTTPS_BASE/api/" 2>/dev/null)"
  if [[ "$http2" == "1.1" ]]; then
    https_ok "HTTP/2を求めてもHTTP/1.1で応える"
  else
    https_ng "HTTP/1.1以外で応えた: $http2"
  fi

  echo
  echo "--- 公開するパス ---"
  status="$(https_curl "$HTTPS_BASE/docs")"
  https_expect "/docs は公開しない" 404 not_found "$status"
  status="$(https_curl "$HTTPS_BASE/health")"
  https_expect "/health は公開しない" 404 not_found "$status"

  echo
  echo "--- 応答のヘッダー(/api/ の応答) ---"
  cp "$headers_file" "$HTTPS_TMP/headers"
  local value count
  value="$(https_header X-Request-ID)"
  count="$(grep -ci '^x-request-id:' "$HTTPS_TMP/headers")"
  if [[ "$value" =~ ^[0-9a-f]{32}$ ]] && [[ "$count" == 1 ]]; then
    https_ok "X-Request-IDがproxyの形式で1つだけ付く ($value)"
  else
    https_ng "X-Request-ID: $value (件数 $count)"
  fi
  value="$(https_header Strict-Transport-Security)"
  [[ "$value" == max-age=* ]] && https_ok "HSTS ($value)" || https_ng "HSTSが無い"
  value="$(https_header X-Content-Type-Options)"
  [[ "$value" == nosniff ]] && https_ok "X-Content-Type-Options: nosniff" || https_ng "X-Content-Type-Options: $value"
  value="$(https_header Cache-Control)"
  [[ "$value" == no-store ]] && https_ok "Cache-Control: no-store" || https_ng "Cache-Control: $value"
  value="$(https_header Server)"
  [[ "$value" == nginx ]] && https_ok "Serverにバージョンが無い ($value)" || https_ng "Server: $value"

  echo
  echo "--- リクエストIDと送信元のIP ---"
  status="$(https_curl -H 'X-Request-ID: client-supplied-request-id' -H 'X-Forwarded-For: 203.0.113.99' \
    "$HTTPS_BASE/api/users/11111111-1111-1111-1111-111111111111/sessions?last_synced_at=2026-01-01T00:00:00Z")"
  https_expect "認証の無い同期APIは401" 401 unauthenticated "$status"
  local request_id
  request_id="$(https_header X-Request-ID)"
  if [[ "$request_id" != client-supplied-request-id ]] && [[ "$request_id" =~ ^[0-9a-f]{32}$ ]]; then
    https_ok "クライアントが送ったX-Request-IDは使わない ($request_id)"
  else
    https_ng "クライアントが送ったX-Request-IDが使われた: $request_id"
  fi
  sleep 1
  local api_line="" proxy_line=""
  # IDが取れなかったら探さない(空の文字列のgrepは全ての行に当たる)
  if [[ -n "$request_id" ]]; then
    api_line="$(docker compose logs --no-log-prefix --since 2m api 2>/dev/null | grep "app.access" | grep "$request_id" | tail -n 1)"
    proxy_line="$(docker compose logs --no-log-prefix --since 2m proxy 2>/dev/null | grep "proxy.access" | grep "$request_id" | tail -n 1)"
  fi
  echo "api:   $api_line"
  echo "proxy: $proxy_line"
  # IPが偽のX-Forwarded-Forでなく(proxyが上書きした)、proxyのIPでもない(apiがproxyのX-Forwarded-Forを信用した)こと
  if [[ -n "$api_line" ]] && [[ "$api_line" != *203.0.113.99* ]] && [[ "$api_line" != *"ip=172.31.89.10 "* ]] \
    && [[ "$api_line" == *" ip="[0-9]* ]]; then
    https_ok "apiのログに同じリクエストIDがあり、IPは偽のX-Forwarded-ForでもproxyのIPでもない"
  else
    https_ng "apiのログのリクエストID・IP"
  fi
  if [[ -n "$proxy_line" ]] && [[ "$proxy_line" == *"path=/api/users/{user_id}/sessions "* ]] \
    && [[ "$proxy_line" != *11111111-1111* ]] && [[ "$proxy_line" != *last_synced_at* ]]; then
    https_ok "proxyのログに同じリクエストIDがあり、パスは型でクエリ文字列が無い"
  else
    https_ng "proxyのログのリクエストID・パス"
  fi

  echo
  echo "--- bodyの大きさ ---"
  # 10MiB + 1KiB。認証の前にproxyが止める
  head -c 10486784 /dev/zero > "$HTTPS_TMP/large_body"
  status="$(https_curl -X POST -H 'Content-Type: application/json' --data-binary "@$HTTPS_TMP/large_body" "$HTTPS_BASE/api/auth/refresh")"
  https_expect "10MiBを超えるbodyは413" 413 payload_too_large "$status"

  echo
  echo "--- 流量の制限(他の確認に影響しないよう最後に行う) ---"
  # パスワードを照合する操作(平均1回/秒、瞬間的に10回まで)。bodyが空なので、apiに届いても入力チェックの422で終わる(照合しない)
  local i limited=0 retry_after=""
  for i in $(seq 1 20); do
    status="$(https_curl -X POST -H 'Content-Type: application/json' -d '{}' "$HTTPS_BASE/api/auth/login")"
    if [[ "$status" == 429 ]]; then
      limited=$i
      retry_after="$(https_header Retry-After)"
      break
    fi
  done
  if [[ $limited -gt 0 ]]; then
    https_expect "続けてログインすると${limited}回目で429" 429 too_many_requests "$status"
    [[ "$retry_after" == 1 ]] && https_ok "429にRetry-After: 1が付く" || https_ng "Retry-After: $retry_after"
  else
    https_ng "20回続けてログインしても429にならない"
  fi

  rm -rf "$HTTPS_TMP"
  return $HTTPS_NG
}

for step in $STEPS; do
  case "$step" in
    lock)
      run_step lock lock_dependencies
      ;;
    up)
      run_step up docker compose up -d --build --wait
      ;;
    migrate)
      run_step migrate migrate_all
      ;;
    check)
      run_step check compose_run alembic check
      ;;
    lint)
      run_step lint compose_run ruff check .
      ;;
    test)
      # -rfE: 失敗(F)・エラー(E)したテストの一覧を最後にまとめて出す
      run_step test compose_run pytest -v -rfE ${TEST_TARGETS[@]+"${TEST_TARGETS[@]}"}
      ;;
    https)
      run_step https https_checks
      ;;
  esac
done

if [[ $OVERALL -eq 0 ]]; then
  STATUS_LABEL=PASSED
else
  STATUS_LABEL=FAILED
fi

# ---- SUMMARY.md --------------------------------------------------------------
SUMMARY="$RUN_DIR/SUMMARY.md"
{
  echo "# ホスト側チェック結果 (backend): $STATUS_LABEL"
  echo
  echo "- run_id: \`$RUN_ID\`"
  echo "- 実行日時: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "- ブランチ / コミット: $GIT_INFO"
  echo "- docker compose: $COMPOSE_VERSION"
  if [[ ${#TEST_TARGETS[@]} -gt 0 ]]; then
    echo "- テスト対象: ${TEST_TARGETS[*]}"
  fi
  echo
  echo "| ステップ | 結果 | 終了コード | 所要時間 | ログ |"
  echo "| --- | --- | --- | --- | --- |"
  printf '%s' "$RESULTS" | while IFS='|' read -r step label code secs; do
    [[ -z "$step" ]] && continue
    echo "| $step | $label | $code | ${secs}s | [$step.log]($step.log) |"
  done

  if [[ -f "$RUN_DIR/migrate.log" ]]; then
    echo
    echo "## マイグレーション"
    echo
    echo '```text'
    # 適用したマイグレーション("Running upgrade ...")と、適用後のrevision("0002 (head)"等)
    grep -E 'Running upgrade|Running downgrade|\(head\)|^--- ' "$RUN_DIR/migrate.log" || echo "(該当行なし。ログ全文を参照)"
    echo '```'
  fi

  if [[ -f "$RUN_DIR/check.log" ]]; then
    echo
    echo "## alembic check"
    echo
    echo '```text'
    # "Detected sequence ... assuming SERIAL" は差分ではなく連番の扱いの情報なので除外する
    grep -E 'No new upgrade operations detected|New upgrade operations detected|Detected ' "$RUN_DIR/check.log" \
      | grep -v 'assuming SERIAL' \
      || tail -n 5 "$RUN_DIR/check.log"
    echo '```'
  fi

  if [[ -f "$RUN_DIR/lint.log" ]]; then
    echo
    echo "## ruff の指摘"
    echo
    echo '```text'
    # 指摘の行と、最後の件数の行。ruffの出力形式は2通りあるので両方拾う:
    #   旧形式 "path:line:col: CODE message"
    #   新形式 "CODE message" の次の行に " --> path:line:col"
    grep -E '^[^ ]+\.py:[0-9]+:[0-9]+: |^[A-Z]+[0-9]+ |^ *--> |^Found [0-9]+ error|All checks passed' \
      "$RUN_DIR/lint.log" \
      || tail -n 10 "$RUN_DIR/lint.log"
    echo '```'
  fi

  if [[ -f "$RUN_DIR/test.log" ]]; then
    echo
    echo "## pytest の結果"
    echo
    echo '```text'
    # 失敗・エラーの一覧("short test summary info"以降)。無ければ最終行(passed/failedの件数)
    if grep -q 'short test summary info' "$RUN_DIR/test.log"; then
      sed -n '/short test summary info/,$p' "$RUN_DIR/test.log"
    else
      grep -E '^=+ .*(passed|failed|error|no tests ran).* =+$' "$RUN_DIR/test.log" || tail -n 5 "$RUN_DIR/test.log"
    fi
    echo '```'
  fi

  if [[ -f "$RUN_DIR/https.log" ]]; then
    echo
    echo "## HTTPS(リバースプロキシ)の確認"
    echo
    echo '```text'
    grep -E '^(OK|NG): |notAfter=' "$RUN_DIR/https.log" || tail -n 10 "$RUN_DIR/https.log"
    echo '```'
  fi

  printf '%s' "$RESULTS" | while IFS='|' read -r step label code secs; do
    [[ "$label" == FAILED ]] || continue
    # macOS標準のgrep/sed(BSD版)でも動くよう、選択(|)は-Eの拡張正規表現で書く
    if [[ "$step" == test ]] && grep -qE '^=+ (FAILURES|ERRORS) =+$' "$RUN_DIR/test.log"; then
      echo
      echo "## test の失敗の詳細 (先頭200行)"
      echo
      echo '```text'
      # "= FAILURES =" / "= ERRORS =" から "short test summary info" まで
      sed -E -n '/^=+ (FAILURES|ERRORS) =+$/,/short test summary info/p' "$RUN_DIR/test.log" | head -n 200
      echo '```'
    fi
    echo
    echo "## $step のログ末尾 (失敗)"
    echo
    echo '```text'
    tail -n 30 "$RUN_DIR/$step.log"
    echo '```'
  done
} > "$SUMMARY"

FINAL_RUN_DIR="${RUN_DIR}_${STATUS_LABEL}"
mv "$RUN_DIR" "$FINAL_RUN_DIR"

echo
echo "結果: $STATUS_LABEL -> $FINAL_RUN_DIR/SUMMARY.md"
exit "$OVERALL"
