#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

key="$(printf '01234567890123456789012345678901' | base64 | tr -d '\n')"
jq -n --arg key "$key" '{consensus_pubkey:$key}' >"$tmp/identity.json"
jq -n --arg other "$(printf 'abcdefghijklmnopqrstuvwxyzABCDEF' | base64 | tr -d '\n')" \
  '{result:{block_height:"42",total:"1",count:"1",validators:[{pub_key:{value:$other},voting_power:"10"}]}}' >"$tmp/validators.json"
"$ROOT/scripts/verify-inactive-validator-key.sh" --identity "$tmp/identity.json" --validators "$tmp/validators.json" --output "$tmp/receipt.json" >"$tmp/out"
jq -e --arg key "$key" '.kind == "gdc-inactive-validator-key-fence" and .consensus_pubkey == $key and .validator_set_height == "42"' "$tmp/receipt.json" >/dev/null

jq --arg key "$key" '.result.validators[0].pub_key.value = $key' "$tmp/validators.json" >"$tmp/present.json"
if "$ROOT/scripts/verify-inactive-validator-key.sh" --identity "$tmp/identity.json" --validators "$tmp/present.json" --output "$tmp/present-receipt.json" >/dev/null 2>&1; then
  echo 'inactive validator verifier accepted a present key' >&2; exit 1
fi
jq '.result.total = "2"' "$tmp/validators.json" >"$tmp/partial.json"
if "$ROOT/scripts/verify-inactive-validator-key.sh" --identity "$tmp/identity.json" --validators "$tmp/partial.json" --output "$tmp/partial-receipt.json" >/dev/null 2>&1; then
  echo 'inactive validator verifier accepted a partial validator page' >&2; exit 1
fi
printf 'PASS inactive validator-key restore fence verifier\n'
