#!/usr/bin/env bash
# ホスト側でflutterの各種チェック(静的解析・テスト・E2E等)を実行し、結果をすべてファイルへ保存する。
# コンテナ(Claude Code)にはFlutterが無いため、ホストで実行した結果をこのログ経由で読ませる。
#
# 使い方:
#   scripts/run_checks.sh <run_id> [step...] [-d <device_id>] [-t <test_path>]... [-e <e2e_target>]
#   scripts/run_checks.sh --id <run_id> [step...] [--device <device_id>] [--test <test_path>]... [--e2e-target <e2e_target>]
#
# step (記述順ではなく下記の順で実行する。省略時は analyze test):
#   pubget   flutter pub get (worktreeを新しく作った直後など)
#   codegen  dart run build_runner build (Driftのテーブル定義を変えた場合など)
#   analyze  flutter analyze --no-fatal-infos (既知のinfoだけではFAILEDにしない。指摘自体はログに残る)
#   test     flutter test (-t/--test で対象ファイルを絞れる。複数指定可)
#   e2e      flutter drive で integration_test/app_test.dart を実行(要シミュレータ/実機)
#            (-e/--e2e-target で別のシナリオを指定できる。例: integration_test/showcase_test.dart)
#   all      analyze test e2e
#
# run_id: 「どの依頼に対応する実行結果か」を一意に特定するための相関トークン。
#         テスト内容の説明ではなく、依頼ごとに変わるユニークな文字列を渡すこと
#         (例: Claudeが依頼時に生成した a3f9c21b のような文字列)。
#         複数セッションでテストが前後しても、run_idで検索すれば取り違えない。
#
# e2eのデバイスの決定順: -d/--device指定 > E2E_DEVICE_ID環境変数 > 下記DEFAULT_DEVICE_ID
#
# 結果は frontend/host_check_logs/<timestamp>_<run_id>_<PASSED|FAILED>/ に保存される:
#   SUMMARY.md    実行環境(ブランチ/コミット/Flutterバージョン)・ステップごとの結果・
#                 analyzeの指摘一覧・失敗したステップのログ末尾
#   <step>.log    各ステップの標準出力/標準エラーの全文
#   screenshots/  e2eで撮ったスクリーンショット(integration_test_screenshots/のコピー)
# (host_check_logs/ は.gitignore済みなのでコミット対象にはならない)
#
# macOS標準のbash 3.2でも動くように書いている(連想配列・mapfile等は使わない)

set -uo pipefail

# 普段使う実機/エミュレータのIDに書き換えておくと、-dを省略して実行できる
# (`flutter devices`で確認できる値)
DEFAULT_DEVICE_ID="A35B6C74-84CE-4CDA-9985-CAE7A066A829"

DEFAULT_E2E_TARGET="integration_test/app_test.dart"

ALL_STEPS="pubget codegen analyze test e2e"

usage() {
  echo "使い方: $(basename "$0") <run_id> [step...] [-d <device_id>] [-t <test_path>]... [-e <e2e_target>]" >&2
  echo "        step: pubget codegen analyze test e2e all (省略時は analyze test)" >&2
}

RUN_ID=""
DEVICE_ID=""
E2E_TARGET="$DEFAULT_E2E_TARGET"
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
    -d|--device)
      require_value "$1" $#
      DEVICE_ID="$2"
      shift 2
      ;;
    -e|--e2e-target)
      require_value "$1" $#
      E2E_TARGET="$2"
      shift 2
      ;;
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
          all) REQUESTED_STEPS="$REQUESTED_STEPS analyze test e2e" ;;
          pubget|codegen|analyze|test|e2e) REQUESTED_STEPS="$REQUESTED_STEPS $1" ;;
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
  REQUESTED_STEPS="analyze test"
fi

# 指定順・重複に関わらず、依存関係の順(pub get → コード生成 → 解析 → テスト → E2E)で1回ずつ実行する
STEPS=""
for step in $ALL_STEPS; do
  case " $REQUESTED_STEPS " in
    *" $step "*) STEPS="$STEPS $step" ;;
  esac
done
STEPS="${STEPS# }"

if [[ " $STEPS " == *" e2e "* ]]; then
  DEVICE_ID="${DEVICE_ID:-${E2E_DEVICE_ID:-$DEFAULT_DEVICE_ID}}"
  if [[ -z "$DEVICE_ID" ]]; then
    echo "エラー: e2eのデバイスIDが未指定です。次のいずれかで指定してください:" >&2
    echo "  1) -d/--device オプション" >&2
    echo "  2) E2E_DEVICE_ID 環境変数" >&2
    echo "  3) このスクリプト冒頭の DEFAULT_DEVICE_ID" >&2
    echo "(flutter devices で確認できます)" >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_ROOT="$FRONTEND_DIR/host_check_logs"
SCREENSHOT_DIR="$FRONTEND_DIR/integration_test_screenshots"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
# ファイル名に使えない文字を潰す
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')"
RUN_DIR="$LOG_ROOT/${TIMESTAMP}_${SAFE_RUN_ID}"
mkdir -p "$RUN_DIR"

cd "$FRONTEND_DIR"

echo "run_id: $RUN_ID"
echo "steps: $STEPS"
[[ -n "$DEVICE_ID" ]] && echo "device: $DEVICE_ID"
[[ " $STEPS " == *" e2e "* ]] && echo "e2e target: $E2E_TARGET"
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
FLUTTER_VERSION="$(flutter --version 2>&1 | head -n 1)"

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

for step in $STEPS; do
  case "$step" in
    pubget)
      run_step pubget flutter pub get
      ;;
    codegen)
      run_step codegen dart run build_runner build
      ;;
    analyze)
      run_step analyze flutter analyze --no-fatal-infos
      ;;
    test)
      run_step test flutter test --reporter expanded ${TEST_TARGETS[@]+"${TEST_TARGETS[@]}"}
      ;;
    e2e)
      # 前回の実行のスクリーンショットが紛れ込まないよう、撮影前に空にしておく
      rm -rf "$SCREENSHOT_DIR"
      run_step e2e flutter drive \
        --driver=test_driver/integration_test.dart \
        --target="$E2E_TARGET" \
        -d "$DEVICE_ID"
      if [[ -d "$SCREENSHOT_DIR" ]]; then
        cp -R "$SCREENSHOT_DIR" "$RUN_DIR/screenshots"
      fi
      ;;
  esac
done

if [[ $OVERALL -eq 0 ]]; then
  STATUS_LABEL=PASSED
else
  STATUS_LABEL=FAILED
fi

# ---- SUMMARY.md --------------------------------------------------------------
# flutter test / flutter drive のログから "EXCEPTION CAUGHT BY ..." のブロックを抜き出す(最大5件)。
# 長いスタックトレースはフレームワーク内部の行を落とし、プロジェクトのテストコード
# (test/・integration_test/)を指すフレームだけ残す(失敗箇所の行番号が分かれば十分なため)。
# macOS標準のawk(BSD awk)でも動くよう、罫線文字は正規表現の繰り返しを使わず固定文字列で判定する
extract_test_failures() {
  awk '
    index($0, "EXCEPTION CAUGHT BY") { inblock = 1; blocks++; if (blocks > 5) exit }
    inblock {
      line = $0
      # flutter driveの出力は行頭に"flutter: "(空行は"flutter:"のみ)が付くので外す
      sub(/^flutter:( |$)/, "", line)
      # package:flutter_test/... は "test/" を含むので、file:///のプロジェクト内パスに限定する
      if (line ~ /^#[0-9]+ / && line !~ /file:\/\/\/[^ ]*\/(integration_)?test\/[^ ]*\.dart/) next
      if (line ~ /^<asynchronous suspension>/ || line ~ /^\(elided /) next
      print line
      if (index(line, "════════════════════") == 1 && !index(line, "EXCEPTION CAUGHT BY")) {
        inblock = 0
        print ""
      }
    }
    END { if (blocks == 0) print "(EXCEPTION CAUGHTのブロックなし。ログ末尾/全文を参照)" }
  ' "$1"
}

SUMMARY="$RUN_DIR/SUMMARY.md"
{
  echo "# ホスト側チェック結果: $STATUS_LABEL"
  echo
  echo "- run_id: \`$RUN_ID\`"
  echo "- 実行日時: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "- ブランチ / コミット: $GIT_INFO"
  echo "- Flutter: $FLUTTER_VERSION"
  [[ " $STEPS " == *" e2e "* ]] && echo "- E2Eデバイス: \`$DEVICE_ID\`"
  [[ " $STEPS " == *" e2e "* ]] && echo "- E2Eシナリオ: \`$E2E_TARGET\`"
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

  if [[ -f "$RUN_DIR/analyze.log" ]]; then
    echo
    echo "## flutter analyze の指摘"
    echo
    echo '```text'
    # "  info • ... • lib/xxx.dart:1:2 • rule" 形式の行だけを抜き出す
    # (Flutter/Dartのバージョンによっては "info - ..." 区切りのこともあるため両方拾う)
    grep -E '^ *(info|warning|error) (•|-) ' "$RUN_DIR/analyze.log" || echo "(指摘なし)"
    echo '```'
  fi

  for step in test e2e; do
    [[ -f "$RUN_DIR/$step.log" ]] || continue
    echo
    echo "## $step のテスト結果"
    echo
    echo '```text'
    # 失敗したテスト名と最終行(All tests passed! / Some tests failed.)。
    # flutter driveの出力は行頭に"flutter: "が付くが、行末/部分一致で拾えるようにしてある
    grep -E '\[E\]$|All tests passed|Some tests failed' "$RUN_DIR/$step.log" || tail -n 5 "$RUN_DIR/$step.log"
    echo '```'
  done

  if [[ -d "$RUN_DIR/screenshots" ]]; then
    echo
    echo "## E2Eスクリーンショット"
    echo
    for png in "$RUN_DIR"/screenshots/*.png; do
      [[ -e "$png" ]] || continue
      echo "- [$(basename "$png")](screenshots/$(basename "$png"))"
    done
  fi

  printf '%s' "$RESULTS" | while IFS='|' read -r step label code secs; do
    [[ "$label" == FAILED ]] || continue
    if [[ "$step" == test || "$step" == e2e ]]; then
      echo
      echo "## $step の失敗の詳細"
      echo
      echo '```text'
      extract_test_failures "$RUN_DIR/$step.log"
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
