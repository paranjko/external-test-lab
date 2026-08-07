#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 6 )); then
  printf 'usage: %s PROPOSAL_JSON UPGRADE_NAME INFERENCED_URL INFERENCED_SHA256 DAPI_URL DAPI_SHA256\n' "$0" >&2
  exit 2
fi

proposal_file="$1"
upgrade_name="$2"
inferenced_url="$3"
inferenced_sha256="$4"
dapi_url="$5"
dapi_sha256="$6"

[[ -s "$proposal_file" ]] || { printf 'proposal JSON is missing or empty: %s\n' "$proposal_file" >&2; exit 1; }
[[ "$upgrade_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]] \
  || { printf 'invalid upgrade name: %s\n' "$upgrade_name" >&2; exit 1; }
[[ "$inferenced_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || { printf 'invalid inferenced SHA-256\n' >&2; exit 1; }
[[ "$dapi_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || { printf 'invalid DAPI SHA-256\n' >&2; exit 1; }

expected_inferenced="$inferenced_url?checksum=sha256:$inferenced_sha256"
expected_dapi="$dapi_url?checksum=sha256:$dapi_sha256"

jq -er \
  --arg name "$upgrade_name" \
  --arg inferenced "$expected_inferenced" \
  --arg dapi "$expected_dapi" '
  if .proposal.status != "PROPOSAL_STATUS_PASSED" then
    error("upgrade proposal has not passed")
  else . end
  | [.. | objects
      | select(."@type"? == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade")
      | .plan] as $plans
  | if ($plans | length) != 1 then
      error("proposal must contain exactly one software-upgrade plan")
    else $plans[0] end
  | if .name != $name then
      error("software-upgrade plan name does not match the release profile")
    else . end
  | (.info | fromjson) as $info
  | {binaries:{"linux/amd64":$inferenced},api_binaries:{"linux/amd64":$dapi}} as $expected
  | if $info != $expected then
      error("software-upgrade plan info does not match the pinned release artifacts")
    else . end
  | (.height | tonumber)
  | if . < 1 or . != floor then
      error("software-upgrade plan height is invalid")
    else . end
' "$proposal_file"
