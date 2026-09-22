#!/usr/bin/env bash
# A participant that already exists may hold any validator key, including one
# no Host can sign with. These contracts pin the verdict that decides whether
# JOIN may skip registration for it.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/verify-participant-validator-key.sh"
JOIN="$ROOT/scripts/phase-join.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ADDRESS='gonka1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9'
OTHER_ADDRESS='gonka1y36qy55u9tup0sr20373qrk2mnfjeml3j20ag4'
SIGNER_KEY="$(printf '%032d' 1 | base64)"
STALE_KEY="$(printf '%032d' 2 | base64)"

evidence() {
  local file="$tmp/$1" address="$2" key="$3"
  jq -n --arg address "$address" --arg key "$key" \
    '{participant: {address: $address, validator_key: $key, status: "ACTIVE"}}' >"$file"
  printf '%s\n' "$file"
}
expect_pass() {
  "$CHECK" "$ADDRESS" "$SIGNER_KEY" "$1" >"$tmp/out" 2>"$tmp/err" \
    || { echo "expected the check to pass: $(cat "$tmp/err")" >&2; exit 1; }
  grep -Fq 'PASS participant' "$tmp/out" \
    || { echo 'a passing check must say so on stdout' >&2; exit 1; }
}
expect_refusal() {
  local evidence_file="$1" expected="$2" address="${3:-$ADDRESS}" key="${4:-$SIGNER_KEY}"
  if "$CHECK" "$address" "$key" "$evidence_file" >"$tmp/out" 2>"$tmp/err"; then
    echo "expected a refusal for: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/err" \
    || { echo "refusal did not name '$expected': $(cat "$tmp/err")" >&2; exit 1; }
}

# The key the Host signs with is the one on chain: the only case that may skip
# registration.
expect_pass "$(evidence match.json "$ADDRESS" "$SIGNER_KEY")"

# The defect this guards: the chain holds a key this Host cannot sign with.
# The refusal names both keys, because an operator has to decide which Host owns
# the registration before rebinding anything.
stale="$(evidence stale.json "$ADDRESS" "$STALE_KEY")"
expect_refusal "$stale" "is registered with validator key $STALE_KEY"
expect_refusal "$stale" "not with $SIGNER_KEY"

# Evidence about somebody else proves nothing about this participant.
expect_refusal "$(evidence foreign.json "$OTHER_ADDRESS" "$SIGNER_KEY")" \
  "belongs to $OTHER_ADDRESS"

# Shapes that must never be read as agreement.
printf '%s\n' '{}' >"$tmp/empty-object.json"
expect_refusal "$tmp/empty-object.json" 'carries no participant object'
printf '%s\n' '{"participant":{"address":"'"$ADDRESS"'"}}' >"$tmp/no-key.json"
expect_refusal "$tmp/no-key.json" 'carries no participant object'
printf '%s\n' '{"participant":{"address":"'"$ADDRESS"'","validator_key":1}}' >"$tmp/numeric-key.json"
expect_refusal "$tmp/numeric-key.json" 'carries no participant object'
printf '%s\n' 'not json' >"$tmp/garbage.json"
expect_refusal "$tmp/garbage.json" 'carries no participant object'
: >"$tmp/blank.json"
expect_refusal "$tmp/blank.json" 'participant evidence is empty'

# A malformed expectation is a refusal too: a truncated or absent signer key
# must never be compared against the chain and reported as a match.
match="$(evidence match2.json "$ADDRESS" "$SIGNER_KEY")"
expect_refusal "$match" 'not a 32-byte consensus key' "$ADDRESS" "$(printf 'short' | base64)"
expect_refusal "$match" 'is not base64' "$ADDRESS" 'not base64!!'
expect_refusal "$match" 'participant address is malformed' 'cosmos1abc'

if "$CHECK" "$ADDRESS" "$SIGNER_KEY" >/dev/null 2>&1; then
  echo 'the check must refuse a call without evidence' >&2
  exit 1
fi

# The call site is the contract: the verdict has to stand between the decision
# that the participant exists and the line that skips registration for it.
call_line="$(grep -n 'verify-participant-validator-key.sh' "$JOIN" | head -n 1 | cut -d: -f1 || true)"
skip_line="$(grep -n 'skip duplicate registration' "$JOIN" | head -n 1 | cut -d: -f1 || true)"
guard_line="$(grep -n 'already_registered" == true && "\$rebind_existing_participant" != true' "$JOIN" | head -n 1 | cut -d: -f1 || true)"
[[ -n "$call_line" && -n "$skip_line" && -n "$guard_line" ]] \
  || { echo 'phase-join.sh no longer verifies the registered validator key' >&2; exit 1; }
(( guard_line < call_line && call_line < skip_line )) \
  || { echo 'the registered validator key must be verified before registration is skipped' >&2; exit 1; }
grep -Fq 'GDC_JOIN_REBIND_EXISTING_PARTICIPANT=true' "$JOIN" \
  || { echo 'the refusal must name the supported repair' >&2; exit 1; }

# The replaced identity key is evidence, not noise: without it the refusal
# cannot tell an operator that the registration carries the key this very run
# overwrote.
grep -Fq 'identity-consensus-key-replaced.json' "$JOIN" \
  || { echo 'phase-join.sh must retain the replaced identity consensus key' >&2; exit 1; }
grep -Fq 'replaced_identity_consensus_key' "$JOIN" \
  || { echo 'the refusal must be able to name the replaced key' >&2; exit 1; }

# The lookup that decides the skip must be the retrying one: a transient
# failure answering `new` sends the run into a registration the DAPI accepts
# with 200 and never commits.
awk '/^step "Create \$NODE validator recovery archive before registration"/,/^expected_registration_key=/' "$JOIN" >"$tmp/decision.sh"
grep -Fq 'lookup_participant "$participant_endpoint"' "$tmp/decision.sh" \
  || { echo 'the registration decision must use the retrying participant lookup' >&2; exit 1; }
grep -Fq '|| true' "$tmp/decision.sh" \
  && { echo 'the registration decision must not fall through a failed lookup' >&2; exit 1; }

printf 'PASS registered validator key decides whether JOIN may skip registration\n'
