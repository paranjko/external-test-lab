#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-upgrade-proposal-binding.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

inferenced_url='https://example.invalid/inferenced-amd64.zip'
inferenced_sha='1111111111111111111111111111111111111111111111111111111111111111'
dapi_url='https://example.invalid/decentralized-api-amd64.zip'
dapi_sha='2222222222222222222222222222222222222222222222222222222222222222'

jq -n \
  --arg inferenced "$inferenced_url?checksum=sha256:$inferenced_sha" \
  --arg dapi "$dapi_url?checksum=sha256:$dapi_sha" '
  {proposal:{status:"PROPOSAL_STATUS_PASSED",messages:[{
    "@type":"/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
    plan:{name:"v0.2.15",height:"1280",info:({
      binaries:{"linux/amd64":$inferenced},
      api_binaries:{"linux/amd64":$dapi}
    } | tojson)}
  }]}}
' >"$TMP/proposal.json"

height="$($VERIFY "$TMP/proposal.json" v0.2.15 "$inferenced_url" "$inferenced_sha" "$dapi_url" "$dapi_sha")"
[[ "$height" == 1280 ]]

jq '(.proposal.messages[0].plan.info | fromjson
    | .api_binaries["linux/amd64"] = "https://example.invalid/decentralized-api-amd64.zip?checksum=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    | tojson) as $info
    | .proposal.messages[0].plan.info = $info' \
  "$TMP/proposal.json" >"$TMP/wrong-dapi.json"
if "$VERIFY" "$TMP/wrong-dapi.json" v0.2.15 "$inferenced_url" "$inferenced_sha" "$dapi_url" "$dapi_sha" >/dev/null 2>&1; then
  printf 'error: proposal with an unpinned DAPI artifact was accepted\n' >&2
  exit 1
fi

jq '.proposal.messages += [.proposal.messages[0]]' "$TMP/proposal.json" >"$TMP/duplicate.json"
if "$VERIFY" "$TMP/duplicate.json" v0.2.15 "$inferenced_url" "$inferenced_sha" "$dapi_url" "$dapi_sha" >/dev/null 2>&1; then
  printf 'error: proposal with duplicate upgrade plans was accepted\n' >&2
  exit 1
fi

jq '.proposal.messages[0].plan.info = "not-json"' "$TMP/proposal.json" >"$TMP/malformed.json"
if "$VERIFY" "$TMP/malformed.json" v0.2.15 "$inferenced_url" "$inferenced_sha" "$dapi_url" "$dapi_sha" >/dev/null 2>&1; then
  printf 'error: proposal with malformed plan info was accepted\n' >&2
  exit 1
fi

if "$VERIFY" "$TMP/proposal.json" v0.2.16 "$inferenced_url" "$inferenced_sha" "$dapi_url" "$dapi_sha" >/dev/null 2>&1; then
  printf 'error: proposal for another release was accepted\n' >&2
  exit 1
fi

printf 'PASS immutable upgrade proposal binding contract\n'
