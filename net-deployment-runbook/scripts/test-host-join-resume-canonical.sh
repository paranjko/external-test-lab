#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
resume="$ROOT/scripts/phase-join-resume-canonical.sh"
shared="$ROOT/scripts/lib-join-resume.sh"

bash -n "$ROOT/gdc.sh" "$resume" "$shared"
grep -Fq 'CANONICAL_RUNNING|APPLICATION_ACTIVE)' "$ROOT/gdc.sh"
grep -Fq 'phase-join-resume-canonical.sh' "$ROOT/gdc.sh"
grep -Fq 'lacks its retained one-host role configuration' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_RESUME=true' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_ROLE_INPUT:-false}" == true && "${GDC_JOIN_RESUME:-false}" == true' "$ROOT/scripts/lib.sh"
grep -Fq 'canonical resume requires retained signerless CANONICAL_RUNNING, APPLICATION_ACTIVE, or restore MEMBERSHIP_RECONCILED state' "$shared"
grep -Fq 'if [[ "$resume_state" == CANONICAL_RUNNING ]]; then' "$shared"
grep -Fq -- '--resume-current' "$ROOT/scripts/verify-post-sync-join-state.sh"
grep -Fq 'join_start_verified_auxiliary_services "$NODE" "$PUBLIC_EDGE_NODE"' "$shared"
grep -Fq 'if [[ "$node" != "$public_edge_node" ]]; then' "$ROOT/scripts/lib-post-sync-join.sh"
grep -Fq 'jq -er .identity_fingerprints.participant_address "$head"' "$shared"
grep -Fq 'signer is already running' "$shared"
grep -Fq 'without reset or re-sync' "$resume"
grep -Fq 'verify_inactive_restore_key()' "$resume"
grep -Fq 'verify-inactive-validator-key.sh' "$resume"
grep -Fq 'restore-tmkms-signing-state.json' "$resume"
grep -Fq 'if reset_metadata="$(bash "$ROOT/scripts/resolve-reset-dai-backup.sh"' "$resume"
grep -Fq 'canonical resume uses the inactive restored validator-key fence' "$resume"
grep -Fq 'signing_wait_seconds=300' "$resume"
grep -Fq 'join_resume_append_transition SIGNER_ARMED_PENDING_ELIGIBILITY true' "$resume"
if grep -Fq 'deadline=$((SECONDS + 2400))' "$resume"; then
  echo 'canonical resume still requires a 2400-second signature wait' >&2
  exit 1
fi
if grep -En '(host reset|start-node\.sh --canary|promote-state-sync-generation)' "$resume" "$shared"; then
  echo 'canonical resume must not reset, re-sync, or promote state again' >&2
  exit 1
fi
printf 'PASS canonical JOIN resume dispatch is signerless, receipt-bound and does not reset or re-sync\n'
