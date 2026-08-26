#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 || -n "${UPGRADE_FROM_PROFILE:-}" ]] || die 'upgrade target must be an upgrade-capable release profile'
upgrade_source_profile="${UPGRADE_FROM_PROFILE:-v2026.07.23}"

BASELINE="$STATE/phase-profiles/genesis.env"
[[ -s "$BASELINE" ]] || die 'no baseline Genesis profile recorded; run the 0.2.14 baseline first'
grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$BASELINE" || die 'model overlay differs from baseline; model migration is a separate exercise'

# A repaired/repeated evidence pass may run after the chain has already
# activated the approved target. In that state current nodes no longer carry
# source-profile markers, so require the immutable pre-upgrade PASS bundle rather
# than incorrectly demanding that a completed upgrade look like its baseline.
target_runtime_active=true
while IFS= read -r target_node; do
  target_versions="$(curl -fsS --connect-timeout 3 --max-time 8 "$(node_url "$target_node")/v1/versions" 2>/dev/null || true)"
  jq -e --arg version "$GONKA_RELEASE" --arg commit "$GONKA_COMMIT" '
    (.node_version.version | ltrimstr("v")) == $version
    and .node_version.commit == $commit
  ' <<<"$target_versions" >/dev/null 2>&1 || target_runtime_active=false
done < <(configured_nodes)
if [[ "$target_runtime_active" == true ]]; then
  step "Reuse immutable $upgrade_source_profile baseline evidence for the already activated target runtime"
else
  require_current_baseline_pass "$upgrade_source_profile"
fi
baseline_pass_bundle="$(latest_baseline_pass_bundle "$upgrade_source_profile")"
[[ -s "$baseline_pass_bundle/current-epoch-group.json" ]] \
  || die 'accepted baseline PASS has no complete epoch-group evidence'
record_phase_profile upgrade

exec 9>"$STATE/upgrade.lock"
flock -n 9 || die 'another upgrade invocation is already active; inspect its run log before resuming'

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-upgrade"
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

mapfile -t nodes < <(configured_nodes)
(( ${#nodes[@]} > 0 )) || die 'no joined participants to upgrade'

chain_rpc() {
  ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:26657/$1"
}

capture_chain_state() {
  local prefix="$1" account address balance
  chain_rpc status >"$RUN/$prefix-status.json"
  chain_rpc validators >"$RUN/$prefix-validators.json"
  curl -fsS "https://$GENESIS_PUBLIC_HOST/v1/models" >"$RUN/$prefix-models.json"
  ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant' >"$RUN/$prefix-participants.json"
  ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data' >"$RUN/$prefix-epoch-group.json"
  printf '[]' >"$RUN/$prefix-balances.json"
  for node in "${nodes[@]}"; do
    account="$ACCOUNTS/$node-cold.json"
    address="$(jq -er .address "$account")"
    balance="$(ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$address")"
    jq --arg address "$address" --argjson balance "$balance" '. + [{address:$address,balance:$balance}]' \
      "$RUN/$prefix-balances.json" >"$RUN/$prefix-balances.tmp"
    mv "$RUN/$prefix-balances.tmp" "$RUN/$prefix-balances.json"
  done
  account="$ACCOUNTS/gdc-gateway-cold.json"
  address="$(jq -er .address "$account")"
  balance="$(ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$address")"
  jq --arg address "$address" --argjson balance "$balance" '. + [{address:$address,balance:$balance}]' "$RUN/$prefix-balances.json" >"$RUN/$prefix-balances.tmp"
  mv "$RUN/$prefix-balances.tmp" "$RUN/$prefix-balances.json"
}

capture_compose_state() {
  local prefix="$1" node
  mkdir -p "$RUN/$prefix-services"
  for node in "${nodes[@]}"; do
    ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env ps --format json" \
      | jq -s '[.[] | {service:.Service,image:.Image,state:.State,health:.Health}] | sort_by(.service)' \
      >"$RUN/$prefix-services/$node.json"
    ssh "$node" "cat /srv/dai/deploy/$node/.gdc-release" >"$RUN/$prefix-services/$node.release"
    ssh "$node" "cat /srv/dai/deploy/$node/.gdc-binary-upgrade 2>/dev/null || true" \
      >"$RUN/$prefix-services/$node.binary-upgrade"
  done
}

fetch_node_versions() {
  local node="$1" runtime_file="$2" candidate deadline
  candidate="${runtime_file}.tmp"
  deadline=$((SECONDS + ${GDC_UPGRADE_RUNTIME_READY_WAIT_SECONDS:-180}))
  while (( SECONDS < deadline )); do
    if curl -fsS --connect-timeout 3 --max-time 8 "$(node_url "$node")/v1/versions" >"$candidate" 2>/dev/null \
      && jq -e '.node_version.version | type == "string"' "$candidate" >/dev/null 2>&1; then
      mv "$candidate" "$runtime_file"
      return 0
    fi
    rm -f "$candidate"
    printf 'WAIT  %s public version endpoint after Cosmovisor restart\n' "$node"
    sleep 3
  done
  rm -f "$candidate"
  die "$node public version endpoint did not recover after Cosmovisor restart"
}

capture_runtime_state() {
  local node runtime_file node_current api_current node_process api_process node_expected api_expected
  mkdir -p "$RUN/runtime"
  for node in "${nodes[@]}"; do
    runtime_file="$RUN/runtime/$node.json"
    # A node's public Caddy proxy can return a short 502 while the API
    # container is being restarted by Cosmovisor. That is a transition to
    # wait through, not evidence that the upgrade itself failed.
    fetch_node_versions "$node" "$runtime_file"
    jq -e --arg version "$GONKA_RELEASE" --arg commit "$GONKA_COMMIT" '
      (.node_version.version | ltrimstr("v")) == $version
      and .node_version.commit == $commit
    ' "$runtime_file" >/dev/null || die "$node does not report the pinned v$GONKA_RELEASE chain runtime"

    node_current="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T node readlink -f /root/.inference/cosmovisor/current")"
    api_current="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T api readlink -f /root/.dapi/cosmovisor/current")"
    node_expected="/root/.inference/cosmovisor/upgrades/v$GONKA_RELEASE/bin/inferenced"
    api_expected="/root/.dapi/cosmovisor/upgrades/v$GONKA_RELEASE/bin/decentralized-api"
    node_process="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T node ps -eo args" | awk -v expected="$node_expected" '$1 == expected {print $1; exit}')"
    api_process="$(ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env exec -T api ps -eo args" | awk -v expected="$api_expected" '$1 == expected {print $1; exit}')"
    [[ "$node_current" == "/root/.inference/cosmovisor/upgrades/v$GONKA_RELEASE" ]] || die "$node chain cosmovisor link is not v$GONKA_RELEASE"
    [[ "$api_current" == "/root/.dapi/cosmovisor/upgrades/v$GONKA_RELEASE" ]] || die "$node DAPI cosmovisor link is not v$GONKA_RELEASE"
    [[ "$node_process" == "$node_expected" ]] || die "$node chain process is not the v$GONKA_RELEASE binary"
    [[ "$api_process" == "$api_expected" ]] || die "$node DAPI process is not the v$GONKA_RELEASE binary"
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
proposal="$(ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$GDC_UPGRADE_PROPOSAL_ID")"
printf '%s\n' "$proposal" >"$RUN/upgrade-proposal.json"
jq -e '.proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/upgrade-proposal.json" >/dev/null || die 'upgrade proposal has not passed'
upgrade_name="v$GONKA_RELEASE"
plan_height="$("$ROOT/scripts/verify-upgrade-proposal-binding.sh" \
  "$RUN/upgrade-proposal.json" "$upgrade_name" \
  "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256" \
  "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256")" \
  || die 'passed proposal is not immutably bound to the pinned target release artifacts'

step 'Locate pre-upgrade evidence from before the approved plan height'
pre_source=''
while IFS= read -r candidate; do
  [[ -s "$candidate/upgrade-proposal.json" && -s "$candidate/pre-status.json" && -s "$candidate/live-genesis.json" ]] || continue
  [[ "$(jq -r '.proposal.id // empty' "$candidate/upgrade-proposal.json")" == "$GDC_UPGRADE_PROPOSAL_ID" ]] || continue
  candidate_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$candidate/pre-status.json")"
  if (( candidate_height < plan_height )); then pre_source="$candidate"; break; fi
done < <(find "$GDC_HOME/runs" -mindepth 2 -maxdepth 2 -name pre-status.json -printf '%h\n' 2>/dev/null | LC_ALL=C sort -r)

current_height="$(chain_rpc status | jq -er '.result.sync_info.latest_block_height | tonumber')"
if [[ -z "$pre_source" ]]; then
  (( current_height < plan_height )) || die 'upgrade already activated, but no pre-upgrade evidence bundle exists'
  capture_chain_state pre
  capture_compose_state pre
  # The public edge is canonical. The Genesis hostname is a participant
  # callback route and can retain a stale edge configuration across a reset.
  capture_canonical_genesis "https://$PUBLIC_EDGE_HOST/chain-rpc/genesis" "$RUN/live-genesis.json"
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
  for node in "${nodes[@]}"; do
    body="$(curl -fsS --max-time 8 "$(node_url "$node")/chain-api/productscience/inference/inference/last_upgrade_height" 2>/dev/null || true)"
    height="$(jq -r '.last_upgrade_height // "0"' <<<"$body" 2>/dev/null || true)"
    found="$(jq -r '.found // false' <<<"$body" 2>/dev/null || true)"
    if [[ "$found" == true && "$height" == "$plan_height" ]]; then
      printf '%s\n' "$body" >"$RUN/last-upgrade-height/$node.json"
      applied=$((applied + 1))
      continue
    fi
    # The chain endpoint records the activation only while its transient
    # upgrade record is retained.  A resumed evidence pass can run after that
    # record has expired; the pinned running version and commit then provide
    # the durable proof that this node applied the already-passed plan.
    version_body="$(curl -fsS --connect-timeout 3 --max-time 8 "$(node_url "$node")/v1/versions" 2>/dev/null || true)"
    if jq -e --arg version "$GONKA_RELEASE" --arg commit "$GONKA_COMMIT" '
      (.node_version.version | ltrimstr("v")) == $version
      and .node_version.commit == $commit
    ' <<<"$version_body" >/dev/null 2>&1; then
      jq -n --argjson runtime "$version_body" --argjson height "$plan_height" \
        '{found:false,last_upgrade_height:$height,observed_via:"runtime-version",runtime:$runtime}' \
        >"$RUN/last-upgrade-height/$node.json"
      applied=$((applied + 1))
    fi
  done
  (( applied == ${#nodes[@]} )) && break
  observed="$(curl -fsS --max-time 5 "https://$PUBLIC_EDGE_HOST/chain-rpc/status" 2>/dev/null | jq -r '.result.sync_info.latest_block_height // "unavailable"' 2>/dev/null || true)"
  printf 'WAIT  cosmovisor upgrade applied=%s/%s observed-height=%s target=%s\n' "$applied" "${#nodes[@]}" "${observed:-unavailable}" "$plan_height"
  sleep 5
done
(( applied == ${#nodes[@]} )) || die "not every joined node applied upgrade height $plan_height"
capture_runtime_state

marker_scope=full
marker_description='full release'
if [[ "${LAB_CANDIDATE:-false}" == true ]]; then
  marker_scope=cosmovisor
  marker_description='candidate Cosmovisor binary upgrade'
fi
step "Record the $marker_description marker on every upgraded participant"
for node in "${nodes[@]}"; do
  "$ROOT/scripts/write-upgrade-marker.sh" \
    "$node" "$GDC_RELEASE_PROFILE" "$(profile_hash)" "$marker_scope"
done

upgrade_stage='post-upgrade-epoch'
post_upgrade_boundary=$((plan_height + GENESIS_EPOCH_LENGTH))
step "Wait for one full post-upgrade epoch beyond height $post_upgrade_boundary"
deadline=$((SECONDS + ${GDC_UPGRADE_POST_EPOCH_WAIT_SECONDS:-3600}))
current=0
while (( SECONDS < deadline )); do
  status="$(curl -fsS --max-time 8 "https://$PUBLIC_EDGE_HOST/chain-rpc/status" 2>/dev/null || true)"
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
capture_canonical_genesis "https://$PUBLIC_EDGE_HOST/chain-rpc/genesis" "$RUN/post-genesis.json"
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
