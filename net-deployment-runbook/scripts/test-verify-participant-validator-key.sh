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

# The call site is the contract. The mismatch has to be refused before the
# Host is prepared: found later it leaves a prepared Host and a run that only
# manual recovery can leave.
early_line="$(grep -n 'registered_validator_key_mismatch' "$JOIN" | head -n 1 | cut -d: -f1 || true)"
prepare_line="$(grep -n 'phase-prepare.sh' "$JOIN" | head -n 1 | cut -d: -f1 || true)"
skip_line="$(grep -n 'skip duplicate registration' "$JOIN" | head -n 1 | cut -d: -f1 || true)"
call_line="$(grep -n 'verify-participant-validator-key.sh' "$JOIN" | head -n 1 | cut -d: -f1 || true)"
[[ -n "$early_line" && -n "$prepare_line" && -n "$skip_line" && -n "$call_line" ]] \
  || { echo 'phase-join.sh no longer verifies the registered validator key' >&2; exit 1; }
(( call_line < prepare_line )) \
  || { echo 'the registered validator key must be verified before the Host is prepared' >&2; exit 1; }
(( early_line < prepare_line )) \
  || { echo 'the mismatch must be refused before the Host is prepared' >&2; exit 1; }
(( call_line < skip_line )) \
  || { echo 'the registered validator key must be verified before registration is skipped' >&2; exit 1; }

# The refusal is typed, so the next JOIN classifies the Host afresh instead of
# demanding manual recovery.
grep -Fq 'refuse_before_mutation registered_validator_key_mismatch' "$JOIN" \
  || { echo 'the mismatch must be a typed refusal before mutation' >&2; exit 1; }
grep -Fq 'registered_validator_key_mismatch|registered_validator_key_unreadable)' "$JOIN" \
  || { echo 'the refusal recorder does not know the new reasons' >&2; exit 1; }

# The repair has to be a command the launcher accepts. `gdc.sh` unsets
# GDC_JOIN_REBIND_EXISTING_PARTICIPANT for every join, so naming it in the
# refusal would send the operator down a path that cannot work.
grep -Fq 'unset GDC_JOIN_REBIND_EXISTING_PARTICIPANT' "$ROOT/gdc.sh" \
  || { echo 'the launcher no longer scrubs the rebind capability; revisit the refusal text' >&2; exit 1; }
if grep -n 'GDC_JOIN_REBIND_EXISTING_PARTICIPANT=true' "$JOIN" | grep -q .; then
  echo 'phase-join.sh must not tell an operator to set the scrubbed rebind variable' >&2
  exit 1
fi
for phrase in '--mnemonic-prompt' '--mnemonic-file'; do
  [[ "$(grep -c -- "$phrase" "$JOIN")" -ge 2 ]] \
    || { echo "the refusals must name $phrase as the repair" >&2; exit 1; }
done

# The replaced identity key is evidence, not noise: without it the refusal
# cannot tell an operator that the registration carries the key this very run
# overwrote.
grep -Fq 'identity-consensus-key-replaced.json' "$JOIN" \
  || { echo 'phase-join.sh must retain the replaced identity consensus key' >&2; exit 1; }
grep -Fq 'replaced_identity_consensus_key' "$JOIN" \
  || { echo 'the refusal must be able to name the replaced key' >&2; exit 1; }

# A 200 without a participant status is not an answer. Reading it as an absent
# participant sends the run into a registration the chain never commits.
# The one lenient read left is the post-timeout readback, where an absent
# status means "not confirmed yet" and the loop retries. Every read that
# decides whether to register must be strict.
if grep -n "participant.status // empty" "$JOIN" | grep -v observed_body | grep -q .; then
  echo 'a 200 without a status must not be read as a new participant' >&2
  exit 1
fi
[[ "$(grep -c 'require_participant_status' "$JOIN")" -ge 3 ]] \
  || { echo 'both participant lookups must require a status on 200' >&2; exit 1; }
# shellcheck source=/dev/null
source <(sed -n '/^require_participant_status()/,/^}/p' "$JOIN")
NODE=node-a
die() { printf 'FAILED %s\n' "$*" >&2; exit 1; }
for body in '{}' '{"participant":{}}' '{"participant":{"status":null}}' '{"participant":{"status":{}}}' '{"participant":"ACTIVE"}'; do
  if ( require_participant_status "$body" https://seed.test/v2 ) >/dev/null 2>&1; then
    echo "a 200 body without a usable status was accepted: $body" >&2
    exit 1
  fi
done
[[ "$( ( require_participant_status '{"participant":{"status":"ACTIVE"}}' https://seed.test/v2 ) )" == ACTIVE ]] \
  || { echo 'a valid string status must be returned' >&2; exit 1; }
[[ "$( ( require_participant_status '{"participant":{"status":1}}' https://seed.test/v2 ) )" == 1 ]] \
  || { echo 'a valid numeric status must be returned' >&2; exit 1; }

# Every refusal summary reaches the diagnostic envelope, which caps text at
# 240 characters and fails the write above it. A summary that overruns turns
# the refusal into a plain death: no terminal result, no REFUSED receipt, and
# the next JOIN demands manual recovery instead of classifying the Host afresh.
mapfile -t new_summaries < <(grep -A1 -E "refuse_before_mutation registered_validator_key_(mismatch|unreadable)" "$JOIN" \
  | sed -n "s/^[[:space:]]*'\(.*\)'[[:space:]]*\\\\$/\1/p")
(( ${#new_summaries[@]} >= 3 )) \
  || { echo 'the new refusal summaries could not be read from phase-join.sh' >&2; exit 1; }
# shellcheck source=/dev/null
source <(sed -n '/^refuse_before_mutation()/,/^}/p' "$JOIN")
# The envelope writer reads file modes with GNU stat, so the behavioural half
# of this check belongs to the Linux runs; the length rule still applies here.
envelope_runs=true
stat -c %a . >/dev/null 2>&1 || envelope_runs=false
for summary in "${new_summaries[@]}"; do
  (( ${#summary} <= 240 )) \
    || { echo "a refusal summary of ${#summary} characters cannot reach the envelope: ${summary:0:70}" >&2; exit 1; }
  [[ "$envelope_runs" == true ]] || continue
  run_dir="$tmp/refusal"
  rm -rf "$run_dir"; mkdir -p "$run_dir"
  rc=0
  (
    # shellcheck disable=SC2034
    NODE=node-a
    # shellcheck disable=SC2034
    RUN="$run_dir"
    ROOT="$ROOT"
    # shellcheck disable=SC2034
    join_profile_sha256="$(printf '%064d' 7)"
    # shellcheck disable=SC2034
    GDC_JOIN_RESULT_OUTPUT="$run_dir/join-result.v1.json"
    die() { printf 'error: %s\n' "$*" >&2; exit 1; }
    record_join_transition() { :; }
    refuse_before_mutation registered_validator_key_mismatch "$summary" 'refusal message'
  ) >"$tmp/refusal.out" 2>"$tmp/refusal.err" || rc=$?
  [[ "$rc" == 1 ]] \
    || { echo "a refusal must exit 1, got $rc" >&2; exit 1; }
  grep -Fq 'error: refusal message' "$tmp/refusal.err" \
    || { echo "the refusal died before its own message: $(cat "$tmp/refusal.err")" >&2; exit 1; }
  jq -e '.outcome == "refused" and .mutation == "none" and .category == "identity"' \
    "$run_dir/join-result.v1.json" >/dev/null \
    || { echo 'the refusal did not retain a terminal result the next JOIN can classify' >&2; exit 1; }
done
[[ "$envelope_runs" == true ]] \
  || printf 'SKIP refusal envelope write needs GNU stat; length rule checked\n'

printf 'PASS registered validator key decides whether JOIN may skip registration\n'
