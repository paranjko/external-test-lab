#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 8 ]] || {
  echo 'usage: verify-devshard-governance-transition.sh before|after CURRENT_PARAMS.json PROPOSAL.json GATEWAY_CREATOR none|v5 EXPECTED_V5_URL EXPECTED_V5_SHA256 POC_EXCHANGE_DURATION' >&2
  exit 2
}

mode="$1"
current_params="$2"
proposal="$3"
creator="$4"
mutable_protocol="$5"
expected_v5_url="$6"
expected_v5_sha256="$7"
poc_exchange_duration="$8"
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[[ "$mode" == before || "$mode" == after ]] || {
  echo 'DevShard governance transition mode must be before or after' >&2
  exit 2
}
[[ "$poc_exchange_duration" =~ ^[1-9][0-9]*$ ]] || {
  echo 'DevShard governance PoC exchange duration must be positive' >&2
  exit 2
}
jq -e '
  ((.proposal // .).messages | length) == 1
  and ((.proposal // .).messages[0]["@type"] == "/inference.inference.MsgUpdateParams")
  and (((.proposal // .).messages[0].params.devshard_escrow_params) | type) == "object"
' "$proposal" >/dev/null || {
  echo 'DevShard governance proposal must contain exactly one inference MsgUpdateParams message' >&2
  exit 2
}

jq '(.proposal // .).messages[0].params.devshard_escrow_params.approved_versions' \
  "$proposal" >"$tmp/requested-versions.json"
governance_state="$("$root/scripts/prepare-devshard-governance-state.sh" \
  "$current_params" "$tmp/requested-versions.json" "$creator" "$mutable_protocol")" || exit $?

if [[ "$mutable_protocol" == v5 ]]; then
  [[ "$expected_v5_url" =~ ^https:// && "$expected_v5_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'verified v5 composition artifact identity is invalid' >&2
    exit 2
  }
  jq -e --arg url "$expected_v5_url" --arg sha "$expected_v5_sha256" '
    any(.[]; .name == "v5" and .binary == $url and .sha256 == $sha)
  ' "$tmp/requested-versions.json" >/dev/null || {
    echo 'DevShard v5 proposal tuple does not match the verified composition' >&2
    exit 1
  }
fi

if [[ "$mode" == before ]]; then
  allowed_creators="$(jq -c '.allowed_creator_addresses' <<<"$governance_state")"
  approved_versions="$(jq -c '.approved_versions' <<<"$governance_state")"
  jq --argjson allowed_creators "$allowed_creators" \
    --argjson approved_versions "$approved_versions" \
    --arg exchange "$poc_exchange_duration" '
    (.params // .)
    | .devshard_escrow_params.allowed_creator_addresses = $allowed_creators
    | .devshard_escrow_params.approved_versions = $approved_versions
    | .devshard_escrow_params.devshard_requests_enabled = true
    | .epoch_params.poc_exchange_duration = $exchange
    | .epoch_params.poc_validation_delay = "10"
    | .epoch_params.poc_slot_allocation = {value:"5", exponent:-1}
  ' "$current_params" >"$tmp/expected-params.json"
else
  jq '(.params // .)' "$current_params" >"$tmp/expected-params.json"
fi

jq -e --slurpfile expected "$tmp/expected-params.json" '
  ((.proposal // .).messages[0].params) == $expected[0]
' "$proposal" >/dev/null || {
  echo "DevShard governance proposal is not the exact authorized $mode transition" >&2
  exit 1
}

printf 'PASS DevShard governance transition mode=%s mutable=%s\n' "$mode" "$mutable_protocol"
