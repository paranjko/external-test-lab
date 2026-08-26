#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECOVERY="$ROOT/scripts/recover-running-host-state.sh"
PUBLISHER="$ROOT/scripts/publish-running-host-recovery.sh"

line_of() {
  local pattern="$1" file="$2"
  grep -n -F "$pattern" "$file" | head -n1 | cut -d: -f1
}

decision_line="$(grep -n -x 'capture_decision_fence' "$RECOVERY" | head -n1 | cut -d: -f1)"
receipt_line="$(line_of 'receipt_staged="$(mktemp' "$RECOVERY")"
publish_line="$(line_of '"$ROOT/scripts/publish-running-host-recovery.sh"' "$RECOVERY")"
pass_line="$(line_of "printf 'PASS existing" "$RECOVERY")"
[[ -n "$decision_line" && -n "$receipt_line" && -n "$publish_line" && -n "$pass_line" ]]
((decision_line < receipt_line && receipt_line < publish_line && publish_line < pass_line))

grep -Fq 'decision-boundary participant stability readback' "$RECOVERY"
grep -Fq 'capture_common_state synchronization' "$RECOVERY"
grep -Fq 'GDC_RECOVERY_SNAPSHOT_MAX_AGE_SECONDS' "$RECOVERY"
grep -Fq 'participant identity changed across the recovery decision boundary' "$RECOVERY"
grep -Fq 'validator-pages' "$RECOVERY"
grep -Fq 'consensus validator set page 1 stability readback' "$RECOVERY"
grep -Fq 'consensus validator set changed during bounded pagination' "$RECOVERY"
grep -Fq 'VALIDATOR_HEIGHT="$FINAL_CHAIN_HEIGHT"' "$RECOVERY"
grep -Fq 'decision-height' "$RECOVERY"
grep -Fq '/chain-rpc/commit?height=$commit_height' "$RECOVERY"
grep -Fq 'latest commit height=%s is not canonical until the next block' "$RECOVERY"
grep -Fq 'historical consensus commit $commit_height is unexpectedly non-canonical' "$RECOVERY"
grep -Fq 'decision snapshot has malformed public catching-up state' "$RECOVERY"
grep -Fq 'decision snapshot has malformed local catching-up state' "$RECOVERY"
grep -Fq 'freshness' "$RECOVERY"
grep -Fq 'verify-cometbft-commit.py' "$ROOT/scripts/evaluate-running-host-recovery.sh"
grep -Fq 'canonical_header_hash' "$ROOT/scripts/evaluate-running-host-recovery.sh"
grep -Fq 'decision_evidence:$decision_evidence[0]' "$RECOVERY"
grep -Fq 'The joined marker is the only commit point' "$PUBLISHER"
grep -Fq 'flock -n 9' "$PUBLISHER"
grep -Fq 'remote_identity_write == false' "$PUBLISHER"
grep -Fq '.decision_evidence == $freshness[0]' "$PUBLISHER"
grep -Fq 'hash does not match freshness evidence' "$PUBLISHER"
grep -Fq 'validate_freshness_window' "$PUBLISHER"
grep -Fq 'freshness expired before publication' "$PUBLISHER"

if grep -Fq 'record_runtime_identity "$NODE"' "$RECOVERY" \
  || grep -Fq 'record_join_state "$NODE" ACTIVE' "$RECOVERY" \
  || grep -Fq 'touch "$STATE/joined/$NODE"' "$RECOVERY"; then
  echo 'running Host recovery bypasses its transactional publication helper' >&2
  exit 1
fi

echo 'running Host recovery orchestration tests passed'
