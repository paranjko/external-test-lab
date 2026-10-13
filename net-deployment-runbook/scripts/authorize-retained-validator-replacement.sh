#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 3 ]] || { echo 'usage: authorize-retained-validator-replacement.sh PARTICIPANTS_JSON ADDRESS RETAINED_KEY' >&2; exit 2; }
participants="$1"
address="$2"
retained_key="$3"

[[ -f "$participants" && ! -L "$participants" ]] \
  || { echo 'participant set must be a regular file' >&2; exit 1; }
[[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] \
  || { echo 'participant address is malformed' >&2; exit 1; }
[[ "$(base64 -d <<<"$retained_key" 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] \
  || { echo 'retained validator key is malformed' >&2; exit 1; }

jq -e --arg address "$address" '
  (.participant | type == "array") and
  ([.participant[] | select(.address == $address)] | length) == 1 and
  all(.participant[];
    (.address | type == "string" and length > 0) and
    (.validator_key | type == "string" and length > 0)) and
  ([.participant[].address] | length) == ([.participant[].address] | unique | length) and
  ([.participant[].validator_key] | length) == ([.participant[].validator_key] | unique | length)
' "$participants" >/dev/null || { echo 'canonical participant set is malformed or ambiguous' >&2; exit 1; }

registered_key="$(jq -er --arg address "$address" '.participant[] | select(.address == $address) | .validator_key' "$participants")"
if [[ "$retained_key" == "$registered_key" ]]; then
  mode=registered_match
elif jq -e --arg key "$retained_key" 'any(.participant[]; .validator_key == $key)' "$participants" >/dev/null; then
  echo 'retained validator key belongs to another participant' >&2
  exit 1
else
  mode=unregistered_orphan
fi

jq -cn --arg address "$address" --arg registered_key "$registered_key" \
  --arg retained_key "$retained_key" --arg mode "$mode" \
  '{schema_version:1,kind:"gdc-retained-validator-replacement-authorization",participant_address:$address,registered_key:$registered_key,retained_key:$retained_key,mode:$mode}'
