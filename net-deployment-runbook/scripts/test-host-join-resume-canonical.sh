#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
resume="$ROOT/scripts/phase-join-resume-canonical.sh"

bash -n "$ROOT/gdc.sh" "$resume"
grep -Fq 'CANONICAL_RUNNING|APPLICATION_ACTIVE)' "$ROOT/gdc.sh"
grep -Fq 'phase-join-resume-canonical.sh' "$ROOT/gdc.sh"
grep -Fq 'lacks its retained one-host role configuration' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_RESUME=true' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_ROLE_INPUT:-false}" == true && "${GDC_JOIN_RESUME:-false}" == true' "$ROOT/scripts/lib.sh"
grep -Fq 'canonical resume requires retained signerless CANONICAL_RUNNING or APPLICATION_ACTIVE state' "$resume"
grep -Fq 'if [[ "$resume_state" == CANONICAL_RUNNING ]]; then' "$resume"
grep -Fq -- '--resume-current' "$resume"
grep -Fq 'if [[ "$NODE" != "$PUBLIC_EDGE_NODE" ]]; then' "$resume"
grep -Fq 'jq -er .identity_fingerprints.participant_address "$head"' "$resume"
grep -Fq 'signer is already running' "$resume"
grep -Fq 'without reset or re-sync' "$resume"
grep -Fq 'verify_inactive_restore_key()' "$resume"
grep -Fq 'verify-inactive-validator-key.sh' "$resume"
grep -Fq 'restore-tmkms-signing-state.json' "$resume"
grep -Fq 'if reset_metadata="$(bash "$ROOT/scripts/resolve-reset-dai-backup.sh"' "$resume"
grep -Fq 'canonical resume uses the inactive restored validator-key fence' "$resume"
grep -Fq 'signing_wait_seconds=300' "$resume"
grep -Fq 'append_transition SIGNER_ARMED_PENDING_ELIGIBILITY true' "$resume"
if grep -Fq 'deadline=$((SECONDS + 2400))' "$resume"; then
  echo 'canonical resume still requires a 2400-second signature wait' >&2
  exit 1
fi
if grep -En '(host reset|start-node\.sh --canary|promote-state-sync-generation)' "$resume"; then
  echo 'canonical resume must not reset, re-sync, or promote state again' >&2
  exit 1
fi
printf 'PASS canonical JOIN resume dispatch is signerless, receipt-bound and does not reset or re-sync\n'
