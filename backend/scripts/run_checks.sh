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
#   all      up migrate check lint test
#
# run_id: 「どの依頼に対応する実行結果か」を一意に特定するための相関トークン。
#         テスト内容の説明ではなく、依頼ごとに変わるユニークな文字列を渡すこと
#         (例: Claudeが依頼時に生成した a3f9c21b のような文字列)。
#
# 前提: backend/.env があること(項目は backend/docs/バックエンド構成.md)。up以外のstepはサービスが起動済みであること
#
# 結果は backend/host_check_logs/<timestamp>_<run_id>_<PASSED|FAILED>/ に保存される:
#   SUMMARY.md    実行環境(ブランチ/コミット/docker compose)・ステップごとの結果・
#                 alembicのrevision・ruffの指摘・pytestの結果と失敗の詳細・失敗したステップのログ末尾
#   <step>.log    各ステップの標準出力/標準エラーの全文
# (host_check_logs/ は.gitignore済みなのでコミット対象にはならない)
#
# macOS標準のbash 3.2でも動くように書いている(連想配列・mapfile等は使わない)

set -uo pipefail

ALL_STEPS="lock up migrate check lint test"

usage() {
  echo "使い方: $(basename "$0") <run_id> [step...] [-t <test_path>]..." >&2
  echo "        step: lock up migrate check lint test all (省略時は migrate check lint test)" >&2
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
          all) REQUESTED_STEPS="$REQUESTED_STEPS up migrate check lint test" ;;
          lock|up|migrate|check|lint|test) REQUESTED_STEPS="$REQUESTED_STEPS $1" ;;
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

# 指定順・重複に関わらず、依存関係の順(lock → 起動 → マイグレーション → 差分確認 → lint → テスト)で1回ずつ実行する
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
