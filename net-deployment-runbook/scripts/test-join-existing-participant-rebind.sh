#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$ROOT/gdc.sh" "$ROOT/scripts/phase-join.sh"

grep -Fq '[--mnemonic-prompt | --mnemonic-file <PATH>]' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_REBIND_EXISTING_PARTICIPANT=true' "$ROOT/gdc.sh"
grep -Fq -- 'mnemonic recovery cannot be combined with --restore' "$ROOT/gdc.sh"
grep -Fq 'read-join-mnemonic.sh' "$ROOT/gdc.sh"
grep -Fq 'cold account owns an existing participant' "$ROOT/scripts/phase-join.sh"
grep -Fq 'recovered a new cold account; continuing with ordinary participant registration' "$ROOT/scripts/phase-join.sh"
grep -Fq 'tx inference submit-new-participant' "$ROOT/scripts/phase-join.sh"
grep -Fq 'tx inference submit-new-participant "$URL"' "$ROOT/scripts/phase-join.sh"
if grep -Fq 'tx inference submit-new-participant "$PUBLIC_URL"' "$ROOT/scripts/phase-join.sh"; then
  echo 'participant rebind must use the canonical node URL, not an undefined PUBLIC_URL' >&2
  exit 1
fi
grep -Fq -- '--from "$NODE-cold" --keyring-backend file --chain-id "$CHAIN_ID"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'participant-key rebind transaction did not commit' "$ROOT/scripts/phase-join.sh"
grep -Fq 'participant validator key now matches the durable TMKMS signer' "$ROOT/scripts/phase-join.sh"
grep -Fq '.participant.validator_key == $expected' "$ROOT/scripts/phase-join.sh"
grep -Fq 'rebind_existing_participant' "$ROOT/scripts/phase-join.sh"
if grep -Eq 'network participant exclude|participant_exclusion|phase-participant-exclude' \
  "$ROOT/gdc.sh" "$ROOT/scripts/phase-vote-proposal.sh"; then
  echo 'obsolete participant-exclusion path remains reachable' >&2
  exit 1
fi

printf 'PASS JOIN rebind contract uses a signed participant update and durable key readback without a governance exclusion path\n'
