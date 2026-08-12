#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-validation-weight-evidence.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

address=gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other=gonka1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq -n --arg address "$address" --arg other "$other" '{epoch_group_data:{total_weight:"30",validation_weights:[{member_address:$address,weight:"10"},{member_address:$other,weight:"20"}]}}' >"$tmp/accepted.json"
"$CHECK" "$tmp/accepted.json" "$address" >"$tmp/accepted-result.json"
jq -e '.distribution_integrity and .participant_eligible and .participant_weight == 10 and .accepted_weight_sum == 30 and .committed_total == 30' "$tmp/accepted-result.json" >/dev/null

jq -n --arg address "$address" --arg other "$other" '{epoch_group_data:{total_weight:"31",validation_weights:[{member_address:$address,weight:"10"},{member_address:$other,weight:"20"}]}}' >"$tmp/rejected.json"
"$CHECK" "$tmp/rejected.json" "$address" >"$tmp/rejected-result.json"
jq -e '(.distribution_integrity | not) and (.participant_eligible | not) and .accepted_weight_sum == 30 and .committed_total == 31' "$tmp/rejected-result.json" >/dev/null

echo 'PASS validation-weight evidence rejects committed-total mismatch'
