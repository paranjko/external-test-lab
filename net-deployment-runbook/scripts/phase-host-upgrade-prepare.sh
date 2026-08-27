#!/usr/bin/env bash
set -Eeuo pipefail

# Host-scoped target preparation: exactly one SSH alias, one operator home,
# and one immutable passed proposal. No fleet controller or foreign keyring is
# involved.
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 || -n "${UPGRADE_FROM_PROFILE:-}" ]] || die 'host upgrade prepare requires an upgrade-capable release profile'

NODE="$(node_name "${1:-}")"
PROPOSAL_ID="${2:-}"
[[ "$PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] || die 'usage: host upgrade prepare <ssh-alias> <proposal-id>'
topology_contains_node "$NODE" || die "unknown Host alias: $NODE"
record_phase_profile "host-upgrade-prepare-$NODE"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/host-upgrade-prepare-$NODE-$PROPOSAL_ID"
export EVIDENCE_PHASE_NAME="host-upgrade-prepare-$NODE"
mkdir -p "$RUN"
install_evidence_exit_trap 'Host upgrade preparation'
CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"
CHAIN_BASE="${CHAIN_BASE%/}"
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" || die 'cannot read canonical Genesis'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
CHAIN_ID="$(jq -er .chain_id "$RUN/genesis.json")"
write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"

step "Verify immutable passed upgrade proposal $PROPOSAL_ID"
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-api/cosmos/gov/v1/proposals/$PROPOSAL_ID" >"$RUN/proposal.json"
upgrade_name="v$GONKA_RELEASE"
plan_height="$("$ROOT/scripts/verify-upgrade-proposal-binding.sh" "$RUN/proposal.json" "$upgrade_name" \
  "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256" "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256")" \
  || die "proposal $PROPOSAL_ID is not a passed immutable $upgrade_name target"
current_height="$(curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
minimum_lead="${GDC_UPGRADE_MIN_LEAD_BLOCKS:-60}"
[[ "$minimum_lead" =~ ^[1-9][0-9]*$ ]] || die 'GDC_UPGRADE_MIN_LEAD_BLOCKS must be positive'
(( plan_height >= current_height + minimum_lead )) \
  || die "proposal $PROPOSAL_ID activation height $plan_height is unsafe; require at least $minimum_lead blocks after $current_height"

STATE_FILE="$STATE/upgrade/$NODE-$PROPOSAL_ID.env"
CACHE_DIR="/srv/dai/$NODE/gdc-upgrade-cache/$PROPOSAL_ID"
mkdir -p "$(dirname "$STATE_FILE")"
if [[ -s "$STATE_FILE" ]]; then
  require_host_upgrade_state_target "$STATE_FILE" "$NODE" "$PROPOSAL_ID" \
    "$plan_height" "$GENESIS_SHA256" "$CHAIN_ID"
else
  step "Pre-fetch only the pinned target artifacts on $NODE"
  ssh_ready "$NODE" || die "$NODE is unreachable"
  ssh "$NODE" "sudo install -d -m 0700 '$CACHE_DIR'"
  ssh "$NODE" "sudo curl -fsSL '$INFERENCED_UPGRADE_URL' -o '$CACHE_DIR/inferenced.zip'"
  ssh "$NODE" "sudo curl -fsSL '$DAPI_UPGRADE_URL' -o '$CACHE_DIR/decentralized-api.zip'"
  ssh "$NODE" "printf '%s  %s\\n%s  %s\\n' '$INFERENCED_UPGRADE_SHA256' '$CACHE_DIR/inferenced.zip' '$DAPI_UPGRADE_SHA256' '$CACHE_DIR/decentralized-api.zip' | sudo sha256sum -c -"
  {
    printf 'state=PREPARED\n'
    printf 'prepared_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'node=%s\nproposal_id=%s\nplan_height=%s\n' "$NODE" "$PROPOSAL_ID" "$plan_height"
    printf 'genesis_sha256=%s\nchain_id=%s\n' "$GENESIS_SHA256" "$CHAIN_ID"
    printf 'release_profile=%s\nprofile_hash=%s\n' "$GDC_RELEASE_PROFILE" "$(profile_hash)"
    printf 'inferenced_url=%s\ninferenced_sha256=%s\n' "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256"
    printf 'dapi_url=%s\ndapi_sha256=%s\nremote_cache=%s\n' "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256" "$CACHE_DIR"
  } >"$STATE_FILE"
fi

jq -n --arg state PREPARED --arg node "$NODE" --arg proposal_id "$PROPOSAL_ID" \
  --argjson plan_height "$plan_height" --arg genesis_sha256 "$GENESIS_SHA256" --arg chain_id "$CHAIN_ID" \
  --arg profile_hash "$(profile_hash)" --arg remote_cache "$CACHE_DIR" \
  '{schema_version:1,state:$state,node:$node,proposal_id:$proposal_id,plan_height:$plan_height,
    genesis_sha256:$genesis_sha256,chain_id:$chain_id,profile_hash:$profile_hash,remote_cache:$remote_cache}' >"$RUN/receipt.json"
cat >"$RUN/verdict.md" <<EOF
# Host upgrade preparation: PREPARED

$NODE independently verified the immutable proposal, current Genesis lineage,
and pinned artifact digests, then prepared only its own Host. Resume with:
./gdc.sh --release $GDC_RELEASE_PROFILE host upgrade watch $NODE $PROPOSAL_ID
EOF
printf 'PREPARED Host upgrade evidence: %s\n' "$RUN"
