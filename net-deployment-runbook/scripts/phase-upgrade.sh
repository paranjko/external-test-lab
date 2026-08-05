#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == testnet-0.2.15 ]] || die 'upgrade target must be testnet-0.2.15'

BASELINE="$STATE/phase-profiles/genesis.env"
[[ -s "$BASELINE" ]] || die 'no baseline Genesis profile recorded; run the 0.2.14 baseline first'
grep -qx 'release_profile=testnet-0.2.14' "$BASELINE" || die 'Genesis was not formed from testnet-0.2.14'
grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$BASELINE" || die 'model overlay differs from baseline; model migration is a separate exercise'
record_phase_profile upgrade

# An interrupted upgrade may be resumed, but never by two local invocations at
# once. The lock is deliberately local: one operator checkout owns the
# generated inputs and orchestrates all remote changes.
exec 9>"$STATE/upgrade.lock"
flock -n 9 || die 'another upgrade invocation is already active; inspect its run log before resuming'

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-upgrade"
mkdir -p "$RUN"
# The upgrade worker must survive a node4 public-edge reload. Its authoritative
# chain reads therefore use node0's loopback RPC over SSH, never the public
# routing path that this very lifecycle can reconfigure.
chain_rpc() {
  local endpoint="$1"
  ssh gdc-node0 "curl -fsS http://127.0.0.1:26657/$endpoint"
}

capture_chain_state() {
  local prefix="$1" account address
  chain_rpc status >"$RUN/$prefix-status.json"
  chain_rpc validators >"$RUN/$prefix-validators.json"
  curl -fsS "https://$NODE0_PUBLIC_HOST/v1/models" >"$RUN/$prefix-models.json"
  ssh gdc-node0 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant' >"$RUN/$prefix-participants.json"
  ssh gdc-node0 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data' >"$RUN/$prefix-epoch-group.json"
  printf '[]' >"$RUN/$prefix-balances.json"
  for account in "$ACCOUNTS"/gdc-node*-cold.json "$ACCOUNTS/gdc-gateway.json"; do
    address="$(jq -er .address "$account")"
    balance="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$address")"
    jq --arg address "$address" --argjson balance "$balance" '. + [{address:$address,balance:$balance}]' "$RUN/$prefix-balances.json" >"$RUN/$prefix-balances.tmp"
    mv "$RUN/$prefix-balances.tmp" "$RUN/$prefix-balances.json"
  done
}

capture_service_versions() {
  local prefix="$1" index node
  mkdir -p "$RUN/$prefix-services"
  for index in "${nodes[@]}"; do
    node="gdc-node$index"
    ssh "$node" "cd /srv/dai/deploy/$node && docker compose ps --format json" \
      | jq -s '[.[] | {service:.Service,image:.Image,state:.State,health:.Health}] | sort_by(.service)' \
      >"$RUN/$prefix-services/$node.json"
    ssh "$node" "cat /srv/dai/deploy/$node/.gdc-release" >"$RUN/$prefix-services/$node.release"
  done
}

check_upgrade_disk_preflight() {
  local index node free_gib
  local min_free_gib="${GDC_UPGRADE_MIN_FREE_GIB:-20}"
  [[ "$min_free_gib" =~ ^[1-9][0-9]*$ ]] || die 'GDC_UPGRADE_MIN_FREE_GIB must be a positive integer'

  step "Require at least ${min_free_gib} GiB free for chain data and Docker images"
  for index in "${nodes[@]}"; do
    node="gdc-node$index"
    # A release pull may grow Docker's storage while node state grows below
    # DATA_DIR. Check the lesser available capacity of both filesystems before
    # waiting for the irreversible governance activation height.
    free_gib="$(ssh "$node" '
      data_dir=$(awk -F= '\''$1 == "DATA_DIR" {print $2; exit}'\'' /srv/dai/deploy/'"$node"'/.env)
      docker_root=$(docker info --format '\''{{.DockerRootDir}}'\'' 2>/dev/null || true)
      test -n "$data_dir" && test -n "$docker_root"
      for path in "$data_dir" "$docker_root"; do
        df -BG --output=avail "$path" | awk '\''NR == 2 { gsub(/[^0-9]/, ""); print }'\''
      done | sort -n | head -n 1
    ')"
    [[ "$free_gib" =~ ^[0-9]+$ ]] || die "$node did not report free storage for upgrade preflight"
    (( free_gib >= min_free_gib )) || die "$node has only ${free_gib} GiB free; need ${min_free_gib} GiB before upgrade"
    printf 'READY %s upgrade storage free=%s GiB\n' "$node" "$free_gib"
  done
}

prepull_upgrade_images() {
  local index node
  local -a images=(
    "$TMKMS_IMAGE" "$INFERENCED_IMAGE" "$DAPI_IMAGE" "$EDGE_API_IMAGE"
    "$VERSIOND_IMAGE" "$PROXY_IMAGE" "$POSTGRES_IMAGE" "$EXPLORER_IMAGE"
  )

  step 'Pre-pull immutable target images before the upgrade plan activates'
  mkdir -p "$RUN/prepull-images"
  for index in "${nodes[@]}"; do
    node="gdc-node$index"
    # Pulling does not recreate a container or alter chain state. Doing it
    # ahead of the plan height avoids turning the chain halt into an image
    # download outage, and the subsequent inspect proves every exact digest.
    printf '%s\n' "${images[@]}" | ssh "$node" '
      set -Eeuo pipefail
      mapfile -t images
      for image in "${images[@]}"; do docker pull "$image"; done
      docker image inspect "${images[@]}" >/dev/null
    ' >"$RUN/prepull-images/$node.log" 2>&1
    printf 'READY %s has %s pinned target images\n' "$node" "${#images[@]}"
  done
}

mapfile -t nodes < <(configured_node_indexes)
(( ${#nodes[@]} > 0 )) || die 'no joined participants to upgrade'
check_upgrade_disk_preflight
step 'Record pre-upgrade chain state'
capture_chain_state pre
capture_service_versions pre
# The generated Genesis artifact belongs to the baseline rehearsal and can be
# stale after a restored network. Upgrade inputs must use the canonical Genesis
# actually served by the live chain, otherwise an installer can silently
# replace /srv/dai/shared/genesis.json with a different document.
chain_rpc genesis | jq -S .result.genesis >"$RUN/live-genesis.json"
live_genesis_hash="$(sha256sum "$RUN/live-genesis.json" | awk '{print $1}')"
{
  profile_summary
  printf 'profile_hash=%s\n' "$(profile_hash)"
} >"$RUN/target-profile.env"

if [[ -z "${GDC_UPGRADE_PROPOSAL_ID:-}" ]]; then
  cat >"$RUN/verdict.md" <<EOF
# DevNet upgrade: BLOCKED

The target profile is pinned, and pre-upgrade state was captured. Set
GDC_UPGRADE_PROPOSAL_ID only after submitting the protocol-required software
upgrade governance proposal. This phase intentionally will not replace a
running chain binary without passed governance evidence.
EOF
  printf 'BLOCKED upgrade evidence: %s (GDC_UPGRADE_PROPOSAL_ID is required)\n' "$RUN"
  exit 3
fi

step "Verify passed upgrade proposal $GDC_UPGRADE_PROPOSAL_ID"
proposal="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$GDC_UPGRADE_PROPOSAL_ID")"
printf '%s\n' "$proposal" >"$RUN/upgrade-proposal.json"
jq -e '.proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/upgrade-proposal.json" >/dev/null || die 'upgrade proposal has not passed'
upgrade_name="v$GONKA_RELEASE"
jq -e --arg name "$upgrade_name" '
  [.. | objects | select(.["@type"]? == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade") | .plan? | select(.name == $name)] | length > 0
' "$RUN/upgrade-proposal.json" >/dev/null || die "proposal $GDC_UPGRADE_PROPOSAL_ID is not the passed $upgrade_name software-upgrade proposal"

plan_height="$(jq -er --arg name "$upgrade_name" '
  [.. | objects | select(.["@type"]? == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade") | .plan? | select(.name == $name) | .height | tonumber][0]
' "$RUN/upgrade-proposal.json")"
[[ "$plan_height" =~ ^[1-9][0-9]*$ ]] || die 'passed software-upgrade proposal has no valid activation height'
prepull_upgrade_images

# Replacing the containers before the on-chain plan height would bypass the
# protocol transition. Preserve pre-state and return SCHEDULED unless an
# operator explicitly chooses the state-based wait mode.
current_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/pre-status.json")"
if (( current_height < plan_height )); then
  if [[ "${GDC_UPGRADE_WAIT:-false}" != true ]]; then
    cat >"$RUN/verdict.md" <<EOF
# DevNet upgrade: SCHEDULED

Proposal $GDC_UPGRADE_PROPOSAL_ID passed for $upgrade_name at height
$plan_height. Current height is $current_height, so no container was changed.
Run this phase with \`GDC_UPGRADE_WAIT=true\` close to the activation height;
it will use the captured plan rather than an operator-supplied height.
EOF
    printf 'SCHEDULED upgrade evidence: %s (current=%s target=%s)\n' "$RUN" "$current_height" "$plan_height"
    exit 0
  fi
  deadline=$((SECONDS + ${GDC_UPGRADE_WAIT_SECONDS:-21600}))
  while (( current_height < plan_height && SECONDS < deadline )); do
    printf 'WAIT  upgrade activation height=%s target=%s\n' "$current_height" "$plan_height"
    sleep 15
    current_height="$(chain_rpc status | jq -er '.result.sync_info.latest_block_height | tonumber')"
  done
  (( current_height >= plan_height )) || die "activation height $plan_height was not reached before wait deadline"
fi

step 'Roll each joined participant onto the pinned target without replacing Genesis'
step 'Reject a mixed release family before changing any remote host'
for index in "${nodes[@]}"; do
  node="gdc-node$index"
  remote_release="$(ssh "$node" 'cat /srv/dai/deploy/'"$node"'/.gdc-release 2>/dev/null || true')"
  if [[ "$remote_release" == testnet-0.2.14\ * ]]; then
    continue
  fi
  # A previous invocation may have completed a host and then been interrupted.
  # Permit an explicit resume only when that host has exactly this pinned
  # target profile; any third release remains a hard stop.
  if [[ "$remote_release" == "testnet-0.2.15 $(profile_hash)" ]]; then
    printf 'READY resuming interrupted upgrade; %s already has the target marker\n' "$node"
    continue
  fi
  die "$node is neither the recorded 0.2.14 baseline nor this 0.2.15 target"
done
for index in "${nodes[@]}"; do
  node="gdc-node$index"
  step "Upgrade $node"
  # The deployment script retains /srv/dai/deploy/$node/.inference and its
  # Genesis. Only rendered Compose inputs and images are replaced.
  # Chain state lives below the rendered DATA_DIR (for example
  # /srv/dai/gdc-node0), not beside the Compose files. Validate the actual
  # mounted Genesis and ensure it still matches the shared Genesis before any
  # release input is replaced.
  remote_data_dir="$(ssh "$node" "awk -F= '\$1 == \"DATA_DIR\" {print \$2; exit}' /srv/dai/deploy/$node/.env")"
  [[ "$remote_data_dir" =~ ^/srv/dai/[A-Za-z0-9._-]+$ ]] || die "$node has an unsafe or missing DATA_DIR"
  remote_genesis_hash="$(ssh "$node" "test -s '$remote_data_dir/inference/config/genesis.json' && jq -S . '$remote_data_dir/inference/config/genesis.json' | sha256sum | awk '{print \$1}'")"
  [[ "$remote_genesis_hash" == "$live_genesis_hash" ]] \
    || die "$node Genesis differs from the live chain; recreate the 0.2.14 baseline before upgrade"
  node_dir="$GENERATED/upgrade/$node"
  mkdir -p "$node_dir"
  env_args=(--inventory "$INVENTORY" --node-name "$node" \
    --account-public "$ACCOUNTS/$node-cold.json" --seeds-file "$GENESIS/genesis-seeds.txt" \
    --secrets-dir "$SECRETS")
  if [[ "$index" == 4 ]]; then
    node4_callback_address="$(getent ahostsv4 "$NODE4_PUBLIC_HOST" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ ! "$node4_callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      node4_callback_address="$(ssh -G gdc-node4 2>/dev/null | awk '$1 == "hostname" {print $2; exit}' || true)"
    fi
    [[ "$node4_callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'cannot determine gdc-node4 callback IPv4'
    env_args+=(--poc-callback-url "http://$node4_callback_address:9100" --ml-callback-bind 0.0.0.0)
  fi
  "${ROOT}/02-node/render-node-env.sh" "${env_args[@]}" --output "$node_dir/.env" >/dev/null
  profile_var="NODE${index}_GPU_PROFILE"
  config_args=(--node-name "$node" --profile "${!profile_var}" --output "$node_dir/node-config.json")
  [[ "$index" == 4 ]] && config_args+=(--ml-host "$NODE4_ML_ENDPOINT" --ml-poc-port 5000)
  "${ROOT}/02-node/render-node-config.sh" "${config_args[@]}" >/dev/null
  remote="/tmp/gdc-upgrade-$$-$node"
  ssh "$node" "rm -rf '$remote' && mkdir -p '$remote'"
  rsync -a "$ROOT/02-node/" "$node:$remote/02-node/"
  scp -q "$node_dir/.env" "$node:$remote/node.env"
  scp -q "$node_dir/node-config.json" "$node:$remote/node-config.json"
  scp -q "$RUN/live-genesis.json" "$node:$remote/genesis.json"
  local_ml=()
  [[ "$index" != 4 ]] && local_ml=(--local-ml)
  ssh -T "$node" "sudo '$remote/02-node/install-node.sh' --node-name '$node' --env '$remote/node.env' --node-config '$remote/node-config.json' --genesis '$remote/genesis.json' --allow-release-change ${local_ml[*]}; rm -rf '$remote'; cd /srv/dai/deploy/$node && ./start-node.sh"
  ssh "$node" "grep -qx 'testnet-0.2.15 $(profile_hash)' /srv/dai/deploy/$node/.gdc-release" || die "$node did not accept target release marker"
done

step 'Wait for one complete epoch beyond the approved upgrade boundary'
before="$(jq -r .result.sync_info.latest_block_height "$RUN/pre-status.json")"
# `before` may have been captured well before activation while a state-based
# worker waited for the plan.  A height merely greater than that old snapshot
# proves nothing about the upgrade. Require a full configured epoch after the
# exact approved boundary instead.
post_upgrade_boundary=$((plan_height + GENESIS_EPOCH_LENGTH))
deadline=$((SECONDS + ${GDC_UPGRADE_POST_EPOCH_WAIT_SECONDS:-3600})); current="$plan_height"
while (( SECONDS < deadline )); do
  post="$(chain_rpc status)"; current="$(jq -r .result.sync_info.latest_block_height <<<"$post")"
  (( current > post_upgrade_boundary )) && break
  printf 'WAIT  upgrade height=%s epoch-boundary=%s\n' "$current" "$post_upgrade_boundary"
  sleep 15
done
(( current > post_upgrade_boundary )) || die 'chain did not advance through one complete epoch after the approved upgrade boundary'
capture_chain_state post
capture_service_versions post
[[ "$(jq -r .result.node_info.network "$RUN/pre-status.json")" == "$(jq -r .result.node_info.network "$RUN/post-status.json")" ]] || die 'chain ID changed during upgrade'
jq -e --slurpfile before "$RUN/pre-validators.json" '
  ([.result.validators[] | {address,pub_key,voting_power}] | sort_by(.address))
  ==
  ([$before[0].result.validators[] | {address,pub_key,voting_power}] | sort_by(.address))
' "$RUN/post-validators.json" >/dev/null || die 'validator identity or voting power changed across upgrade'
jq -e --slurpfile before "$RUN/pre-participants.json" '
  ([.participant[] | {address,status,validator_key}] | sort_by(.address))
  ==
  ([$before[0].participant[] | {address,status,validator_key}] | sort_by(.address))
' "$RUN/post-participants.json" >/dev/null || die 'participant identity or status changed across upgrade'
jq -e --arg model "$MODEL_ID" --slurpfile before "$RUN/pre-models.json" --slurpfile before_group "$RUN/pre-epoch-group.json" '
  (.data | map(.id) | index($model) != null)
  and ($before[0].data | map(.id) | index($model) != null)
  and . != null
' "$RUN/post-models.json" >/dev/null || die "model $MODEL_ID is missing after upgrade"
jq -e --arg model "$MODEL_ID" '.epoch_group_data.model_id == $model' "$RUN/post-epoch-group.json" >/dev/null || die "model group changed from $MODEL_ID"
jq '[.epoch_group_data.validation_weights[]?.member_address] | sort' "$RUN/pre-epoch-group.json" >"$RUN/pre-group-members.json"
jq '[.epoch_group_data.validation_weights[]?.member_address] | sort' "$RUN/post-epoch-group.json" >"$RUN/post-group-members.json"
jq -e --slurpfile before "$RUN/pre-group-members.json" '
  (length > 0) and . == $before[0]
' "$RUN/post-group-members.json" >/dev/null || die 'model-group membership changed across upgrade'
jq -e --slurpfile before "$RUN/pre-balances.json" '
  ([.[].address] | sort) == ([$before[0][].address] | sort)
' "$RUN/post-balances.json" >/dev/null || die 'account set changed across upgrade'
for index in "${nodes[@]}"; do
  node="gdc-node$index"
  grep -qx "testnet-0.2.15 $(profile_hash)" "$RUN/post-services/$node.release" || die "$node post-upgrade release marker is incorrect"
  jq -e --arg inferenced "$INFERENCED_IMAGE" --arg dapi "$DAPI_IMAGE" '
    ([.[] | select(.service == "node") | .image] | any(. | startswith($inferenced)))
    and ([.[] | select(.service == "api") | .image] | any(. | startswith($dapi)))
  ' "$RUN/post-services/$node.json" >/dev/null || die "$node service image versions do not match the target profile"
done
jq -n --slurpfile before_status "$RUN/pre-status.json" --slurpfile after_status "$RUN/post-status.json" \
  --slurpfile before_balances "$RUN/pre-balances.json" --slurpfile after_balances "$RUN/post-balances.json" \
  '{appHashBefore:$before_status[0].result.sync_info.latest_app_hash,appHashAfter:$after_status[0].result.sync_info.latest_app_hash,balanceBefore:$before_balances[0],balanceAfter:$after_balances[0]}' \
  >"$RUN/state-comparison.json"
cat >"$RUN/verdict.md" <<EOF
# DevNet upgrade: PASS

The existing chain advanced from height $before through the full post-upgrade
epoch boundary $post_upgrade_boundary to $current using the pinned
testnet-0.2.15 target. Genesis was retained on every joined participant.
EOF
printf 'PASS upgrade evidence: %s\n' "$RUN"
