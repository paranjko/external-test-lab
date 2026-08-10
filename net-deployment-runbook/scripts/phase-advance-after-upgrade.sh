#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]] || die 'follow-up target must be v2026.08.06'

proposal_id="${1:-}"
[[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || die 'usage: advance-after-upgrade <upgrade-proposal-id>'
upgrade_unit="gdc-upgrade-proposal-${proposal_id}.service"
run="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-advance-after-upgrade"
mkdir -p "$run"
record_phase_profile advance-after-upgrade

# This worker must never treat an inactive upgrade unit as success: it waits
# for the independently written PASS verdict. A failed or timed-out upgrade
# therefore leaves governance and every economic action untouched.
deadline=$((SECONDS + ${GDC_ADVANCE_AFTER_UPGRADE_WAIT_SECONDS:-28800}))
upgrade_verdict=''
latest_passed_upgrade_verdict() {
  local candidate proposal
  while IFS= read -r candidate; do
    proposal="$(dirname "$candidate")/upgrade-proposal.json"
    if grep -qx '# DevNet upgrade: PASS' "$candidate" \
      && jq -e --arg id "$proposal_id" '(.proposal.id | tostring) == $id' "$proposal" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$GDC_HOME/runs" -mindepth 2 -maxdepth 2 -path '*-upgrade/verdict.md' -type f -print 2>/dev/null | LC_ALL=C sort -r)
  return 1
}
while (( SECONDS < deadline )); do
  upgrade_verdict="$(latest_passed_upgrade_verdict || true)"
  [[ -n "$upgrade_verdict" ]] && break
  if systemctl --user is-failed --quiet "$upgrade_unit"; then
    printf '# Post-upgrade advance: BLOCKED\n\nUpgrade worker %s failed; no governance or gateway action was sent.\n' "$upgrade_unit" >"$run/verdict.md"
    exit 3
  fi
  printf 'WAIT  upgrade PASS evidence for proposal %s\n' "$proposal_id"
  sleep 15
done
[[ -n "$upgrade_verdict" ]] || die "upgrade PASS evidence was not observed before follow-up deadline"
cp "$upgrade_verdict" "$run/upgrade-verdict.md"

step 'Submit the preflighted DevShard v3/v4 governance proposal'
known_statuses="$run/governance-statuses-before.txt"
find "$GDC_HOME/runs" -mindepth 2 -maxdepth 2 -path '*-governance-devshard/proposal-status.json' -type f -print 2>/dev/null | LC_ALL=C sort >"$known_statuses"
GDC_GOVERNANCE_SUBMIT=true "$ROOT/gdc.sh" --release v2026.08.06 governance devshard || true
gov_status="$(comm -13 "$known_statuses" <(find "$GDC_HOME/runs" -mindepth 2 -maxdepth 2 -path '*-governance-devshard/proposal-status.json' -type f -print 2>/dev/null | LC_ALL=C sort) | tail -n 1)"
[[ -s "$gov_status" ]] || die 'governance submission did not produce a proposal status artifact'
gov_id="$(jq -er '.proposal.id | tonumber' "$gov_status")"

step "Vote yes on DevShard governance proposal $gov_id"
"$ROOT/gdc.sh" --release v2026.08.06 vote "$gov_id" yes

step "Wait for passed DevShard governance proposal $gov_id"
rpc="http://127.0.0.1:1317/cosmos/gov/v1/proposals/$gov_id"
while (( SECONDS < deadline )); do
  proposal="$(ssh "$GENESIS_NODE" "curl -fsS $rpc")"
  status="$(jq -r '.proposal.status' <<<"$proposal")"
  [[ "$status" == PROPOSAL_STATUS_PASSED ]] && break
  case "$status" in
    PROPOSAL_STATUS_REJECTED|PROPOSAL_STATUS_FAILED|PROPOSAL_STATUS_INVALID) die "DevShard proposal $gov_id ended as $status" ;;
  esac
  printf 'WAIT  DevShard proposal %s status=%s\n' "$gov_id" "$status"
  sleep 15
done
[[ "${status:-}" == PROPOSAL_STATUS_PASSED ]] || die "DevShard proposal $gov_id did not pass before follow-up deadline"
printf '%s\n' "$proposal" >"$run/governance-proposal-passed.json"

step 'Verify governance state and settle DevShard v3'
GDC_GOVERNANCE_PROPOSAL_ID="$gov_id" "$ROOT/gdc.sh" --release v2026.08.06 governance devshard
GDC_GATEWAY_VERSION=v3 "$ROOT/gdc.sh" --release v2026.08.06 ops gateway
GDC_GATEWAY_VERSION=v3 "$ROOT/gdc.sh" --release v2026.08.06 settle

step 'Settle DevShard v4 after independent gateway deployment'
GDC_GATEWAY_VERSION=v4 "$ROOT/gdc.sh" --release v2026.08.06 ops gateway
GDC_GATEWAY_VERSION=v4 "$ROOT/gdc.sh" --release v2026.08.06 settle

step 'Prove v4 high availability after the v4 settlement'
"$ROOT/gdc.sh" --release v2026.08.06 ha v4
cat >"$run/verdict.md" <<EOF
# Post-upgrade advance: PASS

Upgrade proposal $proposal_id completed before governed DevShard v3/v4
settlement and v4 HA evidence.
EOF
printf 'PASS post-upgrade advance evidence: %s\n' "$run"
