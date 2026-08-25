#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only network verdict for an independently prepared upgrade. It rejects
# stale pre-upgrade evidence and delegates topology/CPoC/inference proof to
# the same public Gate B path operators use before the proposal.
source "$(dirname "$0")/lib.sh"

PROPOSAL_ID="${1:-}"
[[ "$PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] || die 'usage: network upgrade verify <proposal-id>'
[[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || die 'network upgrade verify requires --release v2026.08.06'
CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-}"
[[ "$CHAIN_BASE" =~ ^https://[A-Za-z0-9.-]+$ ]] || die 'GDC_CHAIN_PUBLIC_BASE must be an HTTPS public chain endpoint'
CHAIN_BASE="${CHAIN_BASE%/}"
BASELINE="$GDC_HOME/receipts/gate-b/receipt.json"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/public-upgrade-verify-$PROPOSAL_ID"
export EVIDENCE_PHASE_NAME=public-upgrade-verify
mkdir -p "$RUN"
install_evidence_exit_trap 'Public upgrade verification'

blocked() {
  cat >"$RUN/verdict.md" <<EOF
# Public upgrade verification: BLOCKED

$1
EOF
  printf 'BLOCKED %s; evidence: %s\n' "$1" "$RUN" >&2
  exit 3
}
[[ -s "$BASELINE" ]] || blocked 'pre-upgrade Gate B receipt is absent from the managed receipt inbox'
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" || die 'cannot capture current canonical Genesis'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
CHAIN_ID="$(jq -er .chain_id "$RUN/genesis.json")"
write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"
jq -e --arg hash "$GENESIS_SHA256" '.verdict == "PASS" and .genesis_sha256 == $hash and .effective_validator_count == 5' "$BASELINE" >/dev/null \
  || blocked 'pre-upgrade Gate B evidence belongs to a different Genesis or did not prove five effective validators'

step "Verify immutable passed proposal $PROPOSAL_ID"
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-api/cosmos/gov/v1/proposals/$PROPOSAL_ID" >"$RUN/proposal.json"
plan_height="$("$ROOT/scripts/verify-upgrade-proposal-binding.sh" "$RUN/proposal.json" "v$GONKA_RELEASE" \
  "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256" "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256")" \
  || die "proposal $PROPOSAL_ID is not the passed immutable v$GONKA_RELEASE target"
protection_window="$(jq -er '.app_state.inference.params.confirmation_poc_params.upgrade_protection_window | tonumber' "$RUN/genesis.json")" \
  || blocked 'canonical Genesis lacks a numeric confirmation-PoC upgrade protection window'
current_height="$(curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
(( current_height > plan_height + protection_window )) \
  || blocked "post-upgrade confirmation-PoC cannot be evaluated before protection window end height $((plan_height + protection_window))"

step 'Require all five public Hosts to report the pinned target runtime'
TOPOLOGY="$STATE/lineage/current-topology.json"
[[ -s "$TOPOLOGY" ]] || blocked 'current topology manifest is absent'
while IFS= read -r participant; do
  endpoint="https://$(jq -er .public_host <<<"$participant")"
  address="$(jq -er .address <<<"$participant")"
  curl -fsS --connect-timeout 5 --max-time 15 "$endpoint/v1/versions" >"$RUN/version-$address.json"
  jq -e --arg commit "$GONKA_COMMIT" '(.node_version.version | ltrimstr("v")) == "0.2.15" and .node_version.commit == $commit' "$RUN/version-$address.json" >/dev/null \
    || die "$address does not report the pinned v0.2.15 runtime"
done < <(jq -c '.participants[]' "$TOPOLOGY")

step 'Require the same public Gate B contract after the upgrade protection window'
set +e
GDC_CHAIN_PUBLIC_BASE="$CHAIN_BASE" GDC_RELEASE_PROFILE=v2026.08.06 GDC_RUN_ID="${GDC_RUN_ID:-manual}-post-upgrade" \
  "$ROOT/scripts/phase-public-network-verify.sh"
gate_rc=$?
set -e
post_bundle="$GDC_HOME/runs/${GDC_RUN_ID:-manual}-post-upgrade/public-network-verify"
[[ -s "$post_bundle/receipt.json" ]] || die 'post-upgrade Gate B emitted no receipt'
cp "$post_bundle/receipt.json" "$RUN/post-upgrade-gate-b.json"
[[ "$gate_rc" -eq 0 ]] || exit "$gate_rc"

jq -n --arg proposal_id "$PROPOSAL_ID" --argjson plan_height "$plan_height" \
  --arg genesis_sha256 "$GENESIS_SHA256" --arg baseline "$BASELINE" --arg post_upgrade_gate_b "$post_bundle" \
  '{schema_version:1,verdict:"PASS",proposal_id:$proposal_id,plan_height:$plan_height,
    genesis_sha256:$genesis_sha256,baseline_gate_b:$baseline,post_upgrade_gate_b:$post_upgrade_gate_b}' >"$RUN/receipt.json"
cat >"$RUN/verdict.md" <<EOF
# Public upgrade verification: PASS

Proposal $PROPOSAL_ID preserved the Genesis lineage, and all five public Hosts
reported the pinned target runtime before the complete post-upgrade Gate B,
confirmation-PoC, and authenticated inference contract passed.
EOF
printf 'PASS public upgrade verification: %s\n' "$RUN"
