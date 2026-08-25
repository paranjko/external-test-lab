#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]] || die 'upgrade proposal target must be v2026.08.06'

BASELINE="$STATE/phase-profiles/genesis.env"
[[ -s "$BASELINE" ]] || die 'no baseline Genesis profile recorded; run the 0.2.14 baseline first'
grep -qx 'release_profile=v2026.07.23' "$BASELINE" || die 'Genesis was not formed from v2026.07.23'
grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$BASELINE" || die 'model overlay differs from baseline; model migration is a separate exercise'
require_current_baseline_pass

require GDC_UPGRADE_HEIGHT GDC_UPGRADE_DEPOSIT
[[ "$GDC_UPGRADE_HEIGHT" =~ ^[1-9][0-9]*$ ]] || die 'GDC_UPGRADE_HEIGHT must be a positive integer'
[[ "$GDC_UPGRADE_DEPOSIT" =~ ^[1-9][0-9]*ngonka$ ]] || die 'GDC_UPGRADE_DEPOSIT must be a positive ngonka amount, for example 100000ngonka'
[[ "$INFERENCED_UPGRADE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'invalid pinned inferenced upgrade SHA-256'
[[ "$DAPI_UPGRADE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'invalid pinned DAPI upgrade SHA-256'

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-propose-upgrade"
mkdir -p "$RUN"
install_evidence_exit_trap 'Software upgrade proposal'
record_phase_profile propose-upgrade
# The operator CLI uses JSON-RPC POSTs. Route those through the public edge,
# whose `handle_path` strips `/chain-rpc/`; the protocol callback
# proxy intentionally retains the original path for DAPI peers.
rpc="https://$PUBLIC_EDGE_HOST/chain-rpc/"
upgrade_name="v$GONKA_RELEASE"
metadata="https://github.com/gonka-ai/gonka/releases/tag/release%2Fv$GONKA_RELEASE"

step 'Capture chain height and render the immutable software-upgrade proposal'
curl -fsS "$rpc/status" >"$RUN/pre-status.json"
ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/params/deposit' >"$RUN/gov-params.json"
min_deposit="$(jq -er '(.params.min_deposit // .deposit_params.min_deposit)[0] | .amount + .denom' "$RUN/gov-params.json")"
(( ${GDC_UPGRADE_DEPOSIT%ngonka} >= ${min_deposit%ngonka} )) || die "upgrade deposit $GDC_UPGRADE_DEPOSIT is below live governance minimum $min_deposit"
current_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/pre-status.json")"
min_lead_blocks="${GDC_UPGRADE_MIN_LEAD_BLOCKS:-60}"
[[ "$min_lead_blocks" =~ ^[1-9][0-9]*$ ]] || die 'GDC_UPGRADE_MIN_LEAD_BLOCKS must be a positive integer'
(( GDC_UPGRADE_HEIGHT >= current_height + min_lead_blocks )) || die "upgrade height $GDC_UPGRADE_HEIGHT is too soon; need at least $min_lead_blocks blocks after current height $current_height"

jq -cn \
  --arg inferenced "$INFERENCED_UPGRADE_URL?checksum=sha256:$INFERENCED_UPGRADE_SHA256" \
  --arg dapi "$DAPI_UPGRADE_URL?checksum=sha256:$DAPI_UPGRADE_SHA256" \
  '{binaries:{"linux/amd64":$inferenced},api_binaries:{"linux/amd64":$dapi}}' >"$RUN/upgrade-info.json"
jq -n \
  --arg name "$upgrade_name" \
  --argjson height "$GDC_UPGRADE_HEIGHT" \
  --rawfile info "$RUN/upgrade-info.json" \
  --arg metadata "$metadata" \
  --arg deposit "$GDC_UPGRADE_DEPOSIT" \
  '{messages:[{"@type":"/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",authority:"gonka10d07y265gmmuvt4z0w9aw880jnsr700j2h5m33",plan:{name:$name,height:($height|tostring),info:$info}}],metadata:$metadata,title:("GDC: software upgrade " + $name),summary:("Upgrade GDC validators and decentralized API to " + $name + " at height " + ($height|tostring) + "."),deposit:$deposit}' >"$RUN/proposal.json"
jq -e --arg name "$upgrade_name" --argjson height "$GDC_UPGRADE_HEIGHT" --slurpfile info "$RUN/upgrade-info.json" '
  .messages | length == 1
  and .[0]["@type"] == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade"
  and .[0].plan.name == $name
  and (. [0].plan.height | tonumber) == $height
  and (. [0].plan.info | fromjson) == $info[0]
' "$RUN/proposal.json" >/dev/null

proposal_id="${GDC_UPGRADE_PROPOSAL_ID:-}"
if [[ -z "$proposal_id" && "${GDC_UPGRADE_SUBMIT:-false}" == true ]]; then
  step 'Submit software-upgrade proposal from the dedicated operator account'
  password="$(<"$SECRETS/operator.keyring")"
  tx="$(printf '%s\n' "$password" | "$ROOT/scripts/inferenced.sh" tx gov submit-proposal "$RUN/proposal.json" \
    --from "$GENESIS_NODE-cold" --keyring-backend file --chain-id "$CHAIN_ID" --node "$rpc" \
    --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"
  printf '%s\n' "$tx" >"$RUN/submit-tx.json"
  txhash="$(jq -er '.txhash // .tx_response.txhash' "$RUN/submit-tx.json")"
  for _ in $(seq 1 60); do
    result="$("$ROOT/scripts/inferenced.sh" query tx "$txhash" --node "$rpc" --output json 2>/dev/null || true)"
    proposal_id="$(jq -r '[..|objects|select(.key? == "proposal_id")|.value][0] // empty' <<<"$result")"
    [[ "$proposal_id" =~ ^[0-9]+$ ]] && break
    printf 'WAIT  proposal id from tx %s\n' "$txhash"
    sleep 2
  done
fi

if [[ ! "$proposal_id" =~ ^[0-9]+$ ]]; then
  cat >"$RUN/verdict.md" <<EOF
# Software upgrade proposal: READY FOR SUBMISSION

The complete proposal is rendered at \`proposal.json\`. Review its target
height, immutable archive URLs, SHA-256 checksums, and deposit. Submit only
with \`GDC_UPGRADE_SUBMIT=true\`; the subsequent upgrade phase remains gated
on this proposal reaching \`PROPOSAL_STATUS_PASSED\`.
EOF
  printf 'READY upgrade proposal evidence: %s\n' "$RUN"
  exit 0
fi

step "Record submitted upgrade proposal $proposal_id"
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-status.json"
jq -e --arg name "$upgrade_name" --argjson height "$GDC_UPGRADE_HEIGHT" --slurpfile info "$RUN/upgrade-info.json" '
  [.. | objects | select(.["@type"]? == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade") | .plan? | select(.name == $name and (.height | tonumber) == $height and (.info | fromjson) == $info[0])] | length > 0
' "$RUN/proposal-status.json" >/dev/null || die "proposal $proposal_id does not match the rendered software-upgrade plan"
cat >"$RUN/verdict.md" <<EOF
# Software upgrade proposal: SUBMITTED

Proposal $proposal_id was submitted for $upgrade_name at height
$GDC_UPGRADE_HEIGHT. The actual cutover remains gated on a passed vote.
EOF
printf 'SUBMITTED upgrade proposal evidence: %s (proposal=%s)\n' "$RUN" "$proposal_id"
