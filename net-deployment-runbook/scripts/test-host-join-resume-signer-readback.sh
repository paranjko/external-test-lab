#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
resume="$ROOT/scripts/phase-join-resume-signer-readback.sh"

bash -n "$ROOT/gdc.sh" "$resume"
grep -Fq 'SIGNER_ACTIVATING)' "$ROOT/gdc.sh"
grep -Fq 'phase-join-resume-signer-readback.sh' "$ROOT/gdc.sh"
grep -Fq 'SIGNER_ACTIVATING restore state' "$resume"
grep -Fq 'verify-active-signer-state.sh' "$resume"
grep -Fq 'verify-tmkms-signing-state.sh' "$resume"
grep -Fq 'SIGNER_ACTIVE_VERIFIED' "$resume"
grep -Fq 'RECOVERY_ARCHIVE_VERIFIED' "$resume"
grep -Fq 'append_transition COMPLETE' "$resume"
if grep -En '(start-node\.sh|docker compose .*stop|host reset|state.sync)' "$resume"; then
  echo 'signer readback resume must not mutate the running Host' >&2
  exit 1
fi
printf 'PASS signer readback JOIN resume is receipt-bound and read-only for the running Host\n'
