#!/usr/bin/env bash
# The chain is the only record of which validator key a participant was
# registered with. Holding a signer proves nothing about it: a run before the
# registration fix sent the node's throwaway init key, and every later run that
# read only `status` called that participant healthy while it could never sign.
set -Eeuo pipefail
die() { printf 'FAILED %s\n' "$1" >&2; exit 1; }

[[ $# == 3 ]] \
  || die 'usage: verify-participant-validator-key.sh ADDRESS EXPECTED_VALIDATOR_KEY PARTICIPANT_EVIDENCE'
address="$1"
expected_key="$2"
evidence="$3"

[[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] || die "participant address is malformed: $address"
[[ "$expected_key" =~ ^[A-Za-z0-9+/]+=*$ ]] || die 'expected validator key is not base64'
[[ "$(base64 -d <<<"$expected_key" 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] \
  || die 'expected validator key is not a 32-byte consensus key'
[[ -s "$evidence" ]] || die 'participant evidence is empty'

jq -e '(.participant | type) == "object"
  and (.participant.address | type) == "string"
  and (.participant.validator_key | type) == "string"' "$evidence" >/dev/null 2>&1 \
  || die 'participant evidence carries no participant object with an address and a validator_key'

published_address="$(jq -r '.participant.address' "$evidence")"
published_key="$(jq -r '.participant.validator_key' "$evidence")"

[[ "$published_address" == "$address" ]] \
  || die "participant evidence belongs to $published_address, not to $address"
[[ "$published_key" == "$expected_key" ]] \
  || die "participant $address is registered with validator key $published_key, not with $expected_key"

printf 'PASS participant %s is registered with the expected validator key\n' "$address"
