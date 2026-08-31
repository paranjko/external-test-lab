#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 4 ]] || {
  echo 'usage: verify-devshard-governance-snapshot.sh before|after PROPOSAL.json CURRENT_PARAMS.json none|v5' >&2
  exit 2
}

mode="$1"
proposal_file="$2"
current_params_file="$3"
expected_mutable_protocol="$4"
[[ "$mode" == before || "$mode" == after ]] || {
  echo 'DevShard governance snapshot mode must be before or after' >&2
  exit 2
}
[[ "$expected_mutable_protocol" == none || "$expected_mutable_protocol" == v5 ]] || {
  echo 'expected mutable DevShard protocol must be none or v5' >&2
  exit 2
}
[[ -s "$proposal_file" ]] || { echo "DevShard proposal is missing: $proposal_file" >&2; exit 2; }
[[ -s "$current_params_file" ]] || { echo "current inference parameters are missing: $current_params_file" >&2; exit 2; }

proposal_metadata="$(jq -er '(.proposal // .).metadata' "$proposal_file")"
metadata_pattern='^gdc-devshard-v1:mutable=(none|v5);before-sha256=([0-9a-f]{64});message-sha256=([0-9a-f]{64})$'
[[ "$proposal_metadata" =~ $metadata_pattern ]] || {
  echo 'DevShard proposal state-binding metadata is malformed' >&2
  exit 2
}
expected_before_hash="${BASH_REMATCH[2]}"
expected_message_hash="${BASH_REMATCH[3]}"
[[ "${BASH_REMATCH[1]}" == "$expected_mutable_protocol" ]] || {
  echo 'DevShard proposal mutable scope does not match the verified local composition' >&2
  exit 1
}
actual_message_hash="$(jq -cS '(.proposal // .).messages' "$proposal_file" | sha256sum | awk '{print $1}')"
[[ "$actual_message_hash" == "$expected_message_hash" ]] || {
  echo 'DevShard proposal messages do not match their state-binding metadata' >&2
  exit 1
}

current_params_hash="$(jq -cS '(.params // .)' "$current_params_file" | sha256sum | awk '{print $1}')"
if [[ "$mode" == before ]]; then
  expected_params_hash="$expected_before_hash"
else
  expected_params_hash="$(jq -cS '(.proposal // .).messages[0].params' "$proposal_file" | sha256sum | awk '{print $1}')"
fi
[[ "$current_params_hash" == "$expected_params_hash" ]] || {
  echo "DevShard governance snapshot mismatch mode=$mode expected=$expected_params_hash current=$current_params_hash evidence=$current_params_file" >&2
  exit 1
}

printf 'PASS DevShard governance snapshot mode=%s sha256=%s\n' "$mode" "$current_params_hash"
