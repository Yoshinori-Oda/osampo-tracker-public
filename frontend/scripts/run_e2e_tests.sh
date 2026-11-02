#!/usr/bin/env bash
# integration_test/app_test.dart(-e/--e2e-targetで変更可)をflutter driveで実行し、結果をログファイルへ保存する。
# 実体は run_checks.sh の e2e ステップ(ログの保存先・デバイスの決定順などは run_checks.sh を参照)。
#
# 使い方:
#   scripts/run_e2e_tests.sh <run_id>                     (既定デバイスで実行)
#   scripts/run_e2e_tests.sh <run_id> -d <device_id>      (デバイスを上書き)
#   scripts/run_e2e_tests.sh --id <run_id> --device <device_id>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_checks.sh" "$@" e2e
