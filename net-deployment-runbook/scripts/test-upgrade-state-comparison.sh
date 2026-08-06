#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/participants-before.json" <<'JSON'
{"participant":[
  {"address":"gonka1a","validator_key":"key-a","status":"ACTIVE"},
  {"address":"gonka1b","validator_key":"key-b","status":"ACTIVE"}
]}
JSON
cp "$TMP/participants-before.json" "$TMP/participants-after.json"

cat >"$TMP/baseline-group.json" <<'JSON'
{"epoch_group_data":{"sub_group_models":["Qwen/Qwen3-0.6B"],"total_weight":"300","validation_weights":[
  {"member_address":"gonka1a","weight":"100"},
  {"member_address":"gonka1b","weight":"200"}
]}}
JSON
cat >"$TMP/post-group.json" <<'JSON'
{"epoch_group_data":{"sub_group_models":["Qwen/Qwen3-0.6B"],"total_weight":"330","validation_weights":[
  {"member_address":"gonka1a","weight":"110"},
  {"member_address":"gonka1b","weight":"220"}
]}}
JSON

"$ROOT/scripts/compare-upgrade-state.sh" \
  "$TMP/baseline-group.json" "$TMP/participants-before.json" \
  "$TMP/post-group.json" "$TMP/participants-after.json" \
  "$TMP/pass" 'Qwen/Qwen3-0.6B' 50 >/dev/null
jq -e '.same_active_participants' "$TMP/pass/participant-comparison.json" >/dev/null
jq -e '.same_prepared_set and .all_positive and .total_before == 300 and .total_after == 330' \
  "$TMP/pass/power-comparison.json" >/dev/null

# A point-in-time pre-upgrade epoch can legitimately omit a rotating member;
# the comparison deliberately does not consume it. The accepted baseline does.
cat >"$TMP/transient-pre-group.json" <<'JSON'
{"epoch_group_data":{"sub_group_models":["Qwen/Qwen3-0.6B"],"total_weight":"200","validation_weights":[
  {"member_address":"gonka1b","weight":"200"}
]}}
JSON
"$ROOT/scripts/compare-upgrade-state.sh" \
  "$TMP/baseline-group.json" "$TMP/participants-before.json" \
  "$TMP/post-group.json" "$TMP/participants-after.json" \
  "$TMP/transient-pass" 'Qwen/Qwen3-0.6B' 50 >/dev/null

jq 'del(.epoch_group_data.validation_weights[0]) | .epoch_group_data.total_weight="220"' \
  "$TMP/post-group.json" >"$TMP/post-missing.json"
if "$ROOT/scripts/compare-upgrade-state.sh" \
  "$TMP/baseline-group.json" "$TMP/participants-before.json" \
  "$TMP/post-missing.json" "$TMP/participants-after.json" \
  "$TMP/missing" 'Qwen/Qwen3-0.6B' 50 >/dev/null 2>&1; then
  echo 'error: missing prepared participant was accepted' >&2
  exit 1
fi

jq '(.participant[] | select(.address=="gonka1b").validator_key)="changed"' \
  "$TMP/participants-after.json" >"$TMP/participants-changed.json"
if "$ROOT/scripts/compare-upgrade-state.sh" \
  "$TMP/baseline-group.json" "$TMP/participants-before.json" \
  "$TMP/post-group.json" "$TMP/participants-changed.json" \
  "$TMP/changed" 'Qwen/Qwen3-0.6B' 50 >/dev/null 2>&1; then
  echo 'error: changed participant identity was accepted' >&2
  exit 1
fi

printf 'PASS upgrade state comparison contract\n'
