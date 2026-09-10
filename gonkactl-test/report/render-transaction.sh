#!/usr/bin/env bash
set -euo pipefail

data_root=${1:?persistent data root required}
run_id=${2:?run id required}
results="$data_root/report/results/$run_id"
output="$data_root/report/render/$run_id"
scope="$data_root/history/m0-v4"
history="$scope/history.jsonl"
receipt="$scope/receipts/$run_id"
transaction="$scope/transactions/$run_id"
staging="$scope/staging/$run_id.history.jsonl"
mkdir -p "$scope/receipts" "$scope/transactions" "$scope/staging" "$data_root/report/render"

exec 9>"$scope/scope.lock"
flock 9
if test -f "$receipt"; then
  exit 0
fi
if test -f "$transaction" && rg -q '^history_committed$' "$transaction"; then
  printf 'recovered_after_history_commit\n' >"$receipt.tmp"
  mv "$receipt.tmp" "$receipt"
  exit 0
fi
printf 'prepared\n' >"$transaction.tmp"
mv "$transaction.tmp" "$transaction"
if test -f "$history"; then cp "$history" "$staging"; else : >"$staging"; fi
set +e
GONKACTL_TEST_REPORT_OUTPUT="$output" GONKACTL_TEST_HISTORY_PATH="$staging" GONKACTL_TEST_APPEND_HISTORY=false ./node_modules/.bin/allure generate --config allurerc.mjs "$results"
status=$?
set -e
if test "$status" -ne 0; then
  printf 'renderer_failed:%s\n' "$status" >"$transaction.tmp"
  mv "$transaction.tmp" "$transaction"
  exit "$status"
fi
node history-append.mjs "$output" "$staging"
mv "$staging" "$history"
printf 'history_committed\n' >"$transaction.tmp"
mv "$transaction.tmp" "$transaction"
if test "${GONKACTL_TEST_INTERRUPT_AFTER_HISTORY_COMMIT:-false}" = true; then
  exit 86
fi
printf 'committed\n' >"$receipt.tmp"
mv "$receipt.tmp" "$receipt"
