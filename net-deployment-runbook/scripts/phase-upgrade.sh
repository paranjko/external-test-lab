#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == testnet-0.2.15 ]] || die 'upgrade target must be testnet-0.2.15'

BASELINE="$STATE/phase-profiles/genesis.env"
[[ -s "$BASELINE" ]] || die 'no baseline Genesis profile recorded; run the 0.2.14 baseline first'
grep -qx 'release_profile=testnet-0.2.14' "$BASELINE" || die 'Genesis was not formed from testnet-0.2.14'
grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$BASELINE" || die 'model overlay differs from baseline; model migration is a separate exercise'
require_current_baseline_pass
baseline_pass_bundle="$(latest_baseline_pass_bundle)"
[[ -s "$baseline_pass_bundle/current-epoch-group.json" ]] \
  || die 'accepted baseline PASS has no complete epoch-group evidence'
record_phase_profile upgrade

exec 9>"$STATE/upgrade.lock"
flock -n 9 || die 'another upgrade invocation is already active; inspect its run log before resuming'

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-upgrade"
mkdir -p "$RUN"
upgrade_stage=preflight
on_upgrade_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ ! -s "$RUN/verdict.md" ]]; then
    set +e
    write_upgrade_blocked_verdict "$RUN/verdict.md" "$upgrade_stage" none none "$rc"
    printf 'BLOCKED upgrade evidence: %s (stage=%s status=%s)\n' "$RUN" "$upgrade_stage" "$rc" >&2
  fi
}
trap on_upgrade_exit EXIT

mapfile -t nodes < <(configured_node_indexes)
(( ${#nodes[@]} > 0 )) || die 'no joined participants to upgrade'

chain_rpc() {
  ssh gdc-node0 "curl -fsS http://127.0.0.1:26657/$1"
}

capture_chain_state() {
  local prefix="$1" account address balance
  chain_rpc status >"$RUN/$prefix-status.json"
  chain_rpc validators >"$RUN/$prefix-validators.json"
  curl -fsS "https://$NODE0_PUBLIC_HOST/v1/models" >"$RUN/$prefix-models.json"
  ssh gdc-node0 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant' >"$RUN/$prefix-participants.json"
  ssh gdc-node0 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data' >"$RUN/$prefix-epoch-group.json"
  printf '[]' >"$RUN/$prefix-balances.json"
  for account in "$ACCOUNTS"/gdc-node*-cold.json "$ACCOUNTS/gdc-gateway-cold.json"; do
    address="$(jq -er .address "$account")"
    balance="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$address")"
    jq --arg address "$address" --argjson balance "$balance" '. + [{address:$address,balance:$balance}]' \
      "$RUN/$prefix-balances.json" >"$RUN/$prefix-balances.tmp"
    mv "$RUN/$prefix-balances.tmp" "$RUN/$prefix-balances.json"
  done
}

capture_compose_state() {
  local prefix="$1" index node
  mkdir -p "$RUN/$prefix-services"
  for index in "${nodes[@]}"; do
    node="gdc-node$index"
    ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env ps --format json" \
      | jq -s '[.[] | {service:.Service,image:.Image,state:.State,health:.Health}] | sort_by(.service)' \
      >"$RUN/$prefix-services/$node.json"
    ssh "$node" "cat /srv/dai/deploy/$node/.gdc-release" >"$RUN/$prefix-services/$node.release"
  done
}

capture_runtime_state() {
  local index node runtime_file node_current api_current node_process api_process
  mkdir -p "$RUN/runtime"
  for index in "${nodes[@]}"; do
    node="gdc-node$index"
    runtime_file="$RUN/runtime/$node.json"
    curl -fsS "$(node_url "$node")/v1/versions" >"$runtime_file"
    jq -e --arg commit "$GONKA_COMMIT" '
      (.node_version.version | ltrimstr("v")) == "0.2.15"
      and .node_version.commit == $commit
    ' "$runtime_file" >/dev/null || die "$node does not report the pinned 0.2.15 chain runtime"

    node_current="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T node readlink -f /root/.inference/cosmovisor/current")"
    api_current="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T api readlink -f /root/.dapi/cosmovisor/current")"
    node_process="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T node sh -lc 'ps -eo args | awk '\''\$1 ~ /cosmovisor\\/upgrades\\/v0.2.15\\/bin\\/inferenced\$/ {print \$1; exit}'\'''")"
    api_process="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T api sh -lc 'ps -eo args | awk '\''\$1 ~ /cosmovisor\\/upgrades\\/v0.2.15\\/bin\\/decentralized-api\$/ {print \$1; exit}'\'''")"
    [[ "$node_current" == /root/.inference/cosmovisor/upgrades/v0.2.15 ]] || die "$node chain cosmovisor link is not v0.2.15"
    [[ "$api_current" == /root/.dapi/cosmovisor/upgrades/v0.2.15 ]] || die "$node DAPI cosmovisor link is not v0.2.15"
    [[ "$node_process" == /root/.inference/cosmovisor/upgrades/v0.2.15/bin/inferenced ]] || die "$node chain process is not the v0.2.15 binary"
    [[ "$api_process" == /root/.dapi/cosmovisor/upgrades/v0.2.15/bin/decentralized-api ]] || die "$node DAPI process is not the v0.2.15 binary"
    jq -n --arg node_current "$node_current" --arg api_current "$api_current" \
      --arg node_process "$node_process" --arg api_process "$api_process" \
      '{node_current:$node_current,api_current:$api_current,node_process:$node_process,api_process:$api_process}' \
      >"$RUN/runtime/$node-cosmovisor.json"
  done
}

[[ -n "${GDC_UPGRADE_PROPOSAL_ID:-}" && "$GDC_UPGRADE_PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] \
  || die 'GDC_UPGRADE_PROPOSAL_ID is required'
upgrade_stage='proposal-verification'
step "Verify passed software-upgrade proposal $GDC_UPGRADE_PROPOSAL_ID"
proposal="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$GDC_UPGRADE_PROPOSAL_ID")"
printf '%s\n' "$proposal" >"$RUN/upgrade-proposal.json"
jq -e '.proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/upgrade-proposal.json" >/dev/null || die 'upgrade proposal has not passed'
upgrade_name="v$GONKA_RELEASE"
plan_height="$(jq -er --arg name "$upgrade_name" '
  [.. | objects | select(.["@type"]? == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade")
   | .plan? | select(.name == $name) | .height | tonumber][0]
' "$RUN/upgrade-proposal.json")"
[[ "$plan_height" =~ ^[1-9][0-9]*$ ]] || die 'passed proposal has no valid target height'

step 'Locate pre-upgrade evidence from before the approved plan height'
pre_source=''
while IFS= read -r candidate; do
  [[ -s "$candidate/upgrade-proposal.json" && -s "$candidate/pre-status.json" && -s "$candidate/live-genesis.json" ]] || continue
  [[ "$(jq -r '.proposal.id // empty' "$candidate/upgrade-proposal.json")" == "$GDC_UPGRADE_PROPOSAL_ID" ]] || continue
  candidate_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$candidate/pre-status.json")"
  if (( candidate_height < plan_height )); then pre_source="$candidate"; break; fi
done < <(find "$ROOT/artifacts/runs" -mindepth 2 -maxdepth 2 -name pre-status.json -printf '%h\n' 2>/dev/null | LC_ALL=C sort -r)

current_height="$(chain_rpc status | jq -er '.result.sync_info.latest_block_height | tonumber')"
if [[ -z "$pre_source" ]]; then
  (( current_height < plan_height )) || die 'upgrade already activated, but no pre-upgrade evidence bundle exists'
  capture_chain_state pre
  capture_compose_state pre
  capture_canonical_genesis "https://$NODE0_PUBLIC_HOST/chain-rpc/genesis" "$RUN/live-genesis.json"
  pre_source="$RUN"
else
  for name in status validators models participants epoch-group balances; do
    cp "$pre_source/pre-$name.json" "$RUN/pre-$name.json"
  done
  cp "$pre_source/live-genesis.json" "$RUN/live-genesis.json"
  [[ -d "$pre_source/pre-services" ]] && cp -a "$pre_source/pre-services" "$RUN/pre-services"
fi
printf '%s\n' "$pre_source" >"$RUN/pre-evidence-source.txt"
printf '%s\n' "$baseline_pass_bundle" >"$RUN/baseline-pass-source.txt"
cp "$baseline_pass_bundle/current-epoch-group.json" "$RUN/baseline-epoch-group.json"
live_genesis_hash="$(genesis_sha256 "$RUN/live-genesis.json")"
{
  profile_summary
  printf 'profile_hash=%s\n' "$(profile_hash)"
  printf 'chain_id=%s\n' "$CHAIN_ID"
  printf 'genesis_sha256=%s\n' "$live_genesis_hash"
  printf 'proposal_id=%s\n' "$GDC_UPGRADE_PROPOSAL_ID"
  printf 'plan_height=%s\n' "$plan_height"
} >"$RUN/target-profile.env"

upgrade_stage='cosmovisor-activation'
step "Wait for Cosmovisor to apply chain and DAPI binaries at height $plan_height"
deadline=$((SECONDS + ${GDC_UPGRADE_WAIT_SECONDS:-21600}))
mkdir -p "$RUN/last-upgrade-height"
while (( SECONDS < deadline )); do
  applied=0
  for index in "${nodes[@]}"; do
    node="gdc-node$index"
    body="$(curl -fsS --max-time 8 "$(node_url "$node")/chain-api/productscience/inference/inference/last_upgrade_height" 2>/dev/null || true)"
    height="$(jq -r '.last_upgrade_height // "0"' <<<"$body" 2>/dev/null || true)"
    found="$(jq -r '.found // false' <<<"$body" 2>/dev/null || true)"
    if [[ "$found" == true && "$height" == "$plan_height" ]]; then
      printf '%s\n' "$body" >"$RUN/last-upgrade-height/$node.json"
      applied=$((applied + 1))
    fi
  done
  (( applied == ${#nodes[@]} )) && break
  observed="$(curl -fsS --max-time 5 "https://$NODE4_PUBLIC_HOST/chain-rpc/status" 2>/dev/null | jq -r '.result.sync_info.latest_block_height // "unavailable"' 2>/dev/null || true)"
  printf 'WAIT  cosmovisor upgrade applied=%s/%s observed-height=%s target=%s\n' "$applied" "${#nodes[@]}" "${observed:-unavailable}" "$plan_height"
  sleep 5
done
(( applied == ${#nodes[@]} )) || die "not every joined node applied upgrade height $plan_height"
capture_runtime_state

step 'Record the active Cosmovisor release marker on every upgraded participant'
for index in "${nodes[@]}"; do
  node="gdc-node$index"
  printf '%s %s\n' "$GDC_RELEASE_PROFILE" "$(profile_hash)" \
    | ssh "$node" "sudo tee /srv/dai/deploy/$node/.gdc-release >/dev/null && sudo chmod 600 /srv/dai/deploy/$node/.gdc-release"
done

upgrade_stage='post-upgrade-epoch'
post_upgrade_boundary=$((plan_height + GENESIS_EPOCH_LENGTH))
step "Wait for one full post-upgrade epoch beyond height $post_upgrade_boundary"
deadline=$((SECONDS + ${GDC_UPGRADE_POST_EPOCH_WAIT_SECONDS:-3600}))
current=0
while (( SECONDS < deadline )); do
  status="$(curl -fsS --max-time 8 "https://$NODE4_PUBLIC_HOST/chain-rpc/status" 2>/dev/null || true)"
  observed="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"$status" 2>/dev/null || true)"
  [[ "$observed" =~ ^[0-9]+$ ]] && current="$observed"
  (( current > post_upgrade_boundary )) && break
  printf 'WAIT  post-upgrade height=%s epoch-boundary=%s\n' "$current" "$post_upgrade_boundary"
  sleep 10
done
(( current > post_upgrade_boundary )) || die 'chain did not advance through one full post-upgrade epoch'

step 'Capture and compare post-upgrade state'
capture_chain_state post
capture_compose_state post
capture_canonical_genesis "https://$NODE0_PUBLIC_HOST/chain-rpc/genesis" "$RUN/post-genesis.json"
[[ "$(genesis_sha256 "$RUN/post-genesis.json")" == "$live_genesis_hash" ]] || die 'Genesis changed during upgrade'
[[ "$(jq -r .result.node_info.network "$RUN/pre-status.json")" == "$(jq -r .result.node_info.network "$RUN/post-status.json")" ]] || die 'chain ID changed during upgrade'
jq -e --slurpfile before "$RUN/pre-participants.json" '
  ([.participant[] | {address,status,validator_key}] | sort_by(.address))
  == ([$before[0].participant[] | {address,status,validator_key}] | sort_by(.address))
' "$RUN/post-participants.json" >/dev/null || die 'participant identity or status changed across upgrade'
jq -e --arg model "$MODEL_ID" '.data | map(.id) | index($model) != null' "$RUN/post-models.json" >/dev/null || die "model $MODEL_ID is missing after upgrade"
"$ROOT/scripts/compare-upgrade-state.sh" \
  "$RUN/baseline-epoch-group.json" "$RUN/pre-participants.json" \
  "$RUN/post-epoch-group.json" "$RUN/post-participants.json" \
  "$RUN" "$MODEL_ID" "${GDC_UPGRADE_MAX_POWER_CHANGE_PERCENT:-50}" \
  || die 'prepared participant set or PoC power did not survive the upgrade'
# Preserve the dynamic Comet sets as evidence without pretending that two
# different epoch snapshots must be byte-identical.
jq -n --slurpfile before "$RUN/pre-validators.json" --slurpfile after "$RUN/post-validators.json" \
  '{before_height:$before[0].result.block_height,
    after_height:$after[0].result.block_height,
    before:$before[0].result.validators,
    after:$after[0].result.validators,
    interpretation:"Comet voting power is derived again each PoC; stable identity and bounded prepared-miner PoC power are asserted separately."}' \
  >"$RUN/consensus-set-observation.json"
jq -e --slurpfile before "$RUN/pre-balances.json" '([.[].address]|sort) == ([$before[0][].address]|sort)' "$RUN/post-balances.json" >/dev/null || die 'account set changed during upgrade'
jq -n --slurpfile before "$RUN/pre-status.json" --slurpfile after "$RUN/post-status.json" \
  --slurpfile before_balances "$RUN/pre-balances.json" --slurpfile after_balances "$RUN/post-balances.json" \
  --arg baseline_source "$baseline_pass_bundle" --arg pre_source "$pre_source" \
  '{appHashBefore:$before[0].result.sync_info.latest_app_hash,
    appHashAfter:$after[0].result.sync_info.latest_app_hash,
    heightBefore:$before[0].result.sync_info.latest_block_height,
    heightAfter:$after[0].result.sync_info.latest_block_height,
    balanceBefore:$before_balances[0],balanceAfter:$after_balances[0],
    baselineSource:$baseline_source,preStateSource:$pre_source,
    interpretation:"Genesis, chain ID, participant identities and prepared PoC power are compared by the phase-specific evidence files."}' \
  >"$RUN/state-comparison.json"

step 'Prove authenticated inference after the upgraded epoch'
client_key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
"$ROOT/04-ops/test-inference-until-ready.sh" "https://$API_HOST" "$client_key" \
  "$RUN/inference-smoke" "$RUN/post-upgrade-chat.json" \
  "${GDC_UPGRADE_INFERENCE_WAIT_SECONDS:-300}"

cat >"$RUN/verdict.md" <<EOF
# DevNet upgrade: PASS

Governance proposal $GDC_UPGRADE_PROPOSAL_ID applied the Cosmovisor-managed
chain and DAPI binaries at height $plan_height on all ${#nodes[@]} joined
nodes. The chain advanced through the full post-upgrade epoch boundary
$post_upgrade_boundary to $current with the original Genesis, ACTIVE participant
identity set, complete prepared model group and bounded PoC-power change.
Authenticated inference passed
after the upgraded epoch. Base container replacement was neither required nor
used.
EOF
printf 'PASS upgrade evidence: %s\n' "$RUN"
