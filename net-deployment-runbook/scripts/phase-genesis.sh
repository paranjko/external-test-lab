#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
TIME_SPEC="${1:---time=+1m}"
[[ "$TIME_SPEC" =~ ^--time=\+([1-9][0-9]*)m$ ]] || die 'expected --time=+Nm'
GENESIS_LEAD_MINUTES="${BASH_REMATCH[1]}"

step 'Verify the operator inferenced CLI matches the selected release'
"$ROOT/scripts/ensure-inferenced-cli.sh"

# Genesis is the one-command path for a fresh, single-validator network.  It
# must not rely on an operator remembering preparatory phases from a previous
# rehearsal.  Scope host preparation and qualification to the requested
# Genesis alias; additional validators remain independent join operations.
GDC_PREPARE_HOSTS="$GENESIS_NODE" "$ROOT/scripts/phase-prepare.sh"
if [[ "${GDC_GENESIS_ROLE_INPUT:-false}" == true && "$(node_gpu_profile "$GENESIS_NODE")" == auto ]]; then
  step "Detect GPU profile for $GENESIS_NODE"
  detected_gpu_profile="$("$ROOT/scripts/detect-gpu-profile.sh" "$GENESIS_NODE")"
  encoded_gpu_profiles="$(printf '%q' "$GENESIS_NODE=$detected_gpu_profile")"
  sed -i -E "s/^GDC_NODE_GPU_PROFILES=.*/GDC_NODE_GPU_PROFILES=$encoded_gpu_profiles/" "$ENV_FILE"
  GDC_NODE_GPU_PROFILES="$GENESIS_NODE=$detected_gpu_profile"
  export GDC_NODE_GPU_PROFILES
  load_topology
  write_inventory
  printf 'READY %s GPU profile detected as %s\n' "$GENESIS_NODE" "$detected_gpu_profile"
fi
qualification_status=passed
if [[ "${GDC_GENESIS_SKIP_QUALIFICATION:-false}" == true ]]; then
  qualification_status=skipped_by_operator
  printf 'SKIP  ML qualification explicitly disabled by the Genesis operator\n'
else
  GDC_QUALIFY_HOSTS="$GENESIS_NODE" "$ROOT/scripts/phase-qualify-ml.sh"
  require_ml_qualification "$GENESIS_NODE"
fi
record_phase_profile genesis
printf 'ml_qualification=%s\n' "$qualification_status" >>"$STATE/phase-profiles/genesis.env"
printf 'PROFILE phase=genesis ml_qualification=%s\n' "$qualification_status"
genesis_identity_inputs=(
  "$SECRETS/operator.keyring"
  "$SECRETS/$GENESIS_NODE.keyring"
  "$SECRETS/$GENESIS_NODE.postgres"
  "$ACCOUNTS/$GENESIS_NODE-cold.json"
  "$ACCOUNTS/gdc-gateway-cold.json"
  "$ACCOUNTS/gdc-faucet-cold.json"
  "$IDENTITIES/$GENESIS_NODE.json"
)
identity_inputs_ready=true
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || identity_inputs_ready=false
done
# A host reset deliberately removes the remote inference directory while it
# preserves the operator's local account and identity evidence. Those local
# files alone cannot start a new Genesis: the node must also have the
# identity-bootstrap config.toml that init-identity.sh creates on the host.
if [[ "$identity_inputs_ready" == true ]] \
  && ! ssh -T "$GENESIS_NODE" "test -s '$DATA_ROOT/$GENESIS_NODE/inference/config/config.toml'"; then
  identity_inputs_ready=false
  printf 'READY remote Genesis identity state is absent; recreating it before Genesis\n'
fi
if [[ "$identity_inputs_ready" != true ]]; then
  step 'Create Genesis operator secrets, Genesis participant identities, and gateway account'
  "$ROOT/scripts/phase-identities.sh"
fi
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || die "Genesis identity input was not created: $input"
done
GENESIS_TIME="$(date -u -d "+${GENESIS_LEAD_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"

step "Build and verify the one-participant Genesis at $GENESIS_TIME"
"$ROOT/01-identities-genesis/build-genesis.sh" --inventory "$INVENTORY" --identities-dir "$IDENTITIES" --secrets-dir "$SECRETS" --genesis-time "$GENESIS_TIME" --output-dir "$GENESIS"
"$ROOT/01-identities-genesis/verify-genesis.sh" "$GENESIS/genesis.json" "$GENESIS/genesis.sha256" "$CHAIN_ID"
bind_run_manifest_genesis "$(genesis_sha256 "$GENESIS/genesis.json")"
for profile_field in genesis_sha256 genesis_overrides_sha256; do
  profile_value="$(jq -er --arg field "$profile_field" '.[$field]' "$GENESIS/ceremony-record.json")"
  printf '%s=%s\n' "$profile_field" "$profile_value" >>"$STATE/phase-profiles/genesis.env"
  printf 'PROFILE phase=genesis %s=%s\n' "$profile_field" "$profile_value"
done

step "Render only $GENESIS_NODE"
NODE="$GENESIS_NODE"
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
GENESIS_RUNTIME_ID="$(runtime_id_for_participant "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")")"
record_runtime_identity "$NODE" "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")" "$GENESIS_RUNTIME_ID"
"$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNTS/$NODE-cold.json" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS" --output "$NODE_DIR/.env" >/dev/null
"$ROOT/02-node/render-node-config.sh" --node-name "$NODE" --runtime-id "$GENESIS_RUNTIME_ID" --profile "$(node_gpu_profile "$NODE")" --output "$NODE_DIR/node-config.json" >/dev/null
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --output "$GENERATED/edge/$NODE.env"
"$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$NODE" --output "$GENERATED/agents/$NODE.env"

step "Install $NODE deployment"
ssh_ready "$NODE" || die "$NODE is unreachable; Genesis cannot be launched"
REMOTE="/tmp/gdc-deploy-$$-$NODE"
ssh "$NODE" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/02-node/" "$NODE:$REMOTE/02-node/"
rsync -a "$ROOT/03-join/" "$NODE:$REMOTE/03-join/"
rsync -a "$ROOT/04-ops/edge-node/" "$NODE:$REMOTE/edge/"
rsync -a "$ROOT/04-ops/agent/" "$NODE:$REMOTE/agent/"
scp -q "$NODE_DIR/.env" "$NODE:$REMOTE/node.env"
scp -q "$NODE_DIR/node-config.json" "$NODE:$REMOTE/node-config.json"
scp -q "$GENERATED/edge/$NODE.env" "$NODE:$REMOTE/edge.env"
scp -q "$GENERATED/agents/$NODE.env" "$NODE:$REMOTE/agent.env"
scp -q "$GENESIS/genesis.json" "$NODE:$REMOTE/genesis.json"
ssh -T "$NODE" "sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' --local-ml; sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; sudo '$REMOTE/agent/install-agent.sh' '$REMOTE/agent.env' --gpu; rm -rf '$REMOTE'"

step 'Start the Genesis participant'
start_stack "$NODE" /srv/dai/edge
start_stack "$NODE" /srv/dai/monitoring-agent
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh"

step 'Activate Genesis ML operations'
"$ROOT/03-join/wait-synced.sh" "https://$GENESIS_PUBLIC_HOST/chain-rpc" "https://$GENESIS_PUBLIC_HOST/chain-rpc"
record_join_state "$NODE" NODE_SYNCED "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
step 'Restart the Genesis API and colocated MLNode only after synchronization'
"$ROOT/03-join/restart-api-after-sync.sh" "$NODE"
"$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITIES/$NODE.json" "$INVENTORY"
"$ROOT/03-join/wait-active.sh" "https://$GENESIS_PUBLIC_HOST" "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
record_join_state "$NODE" ACTIVE "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
persist_runtime_topology
printf '\nGenesis launched with %s as the only participant.\n' "$NODE"

step 'Start the public DevNet faucet for independent Host joins'
"$ROOT/scripts/phase-ops.sh" faucet

if [[ "${GDC_GENESIS_BOOTSTRAP_ACCESS:-true}" == true ]]; then
  step 'Bootstrap authenticated inference for the single-validator network'
  "$ROOT/scripts/phase-bootstrap-access.sh"
  step 'Require bounded Genesis validator effectiveness before lifecycle success'
  GDC_JOIN_GATEWAY_CLIENT_KEY_FILE="$SECRETS/gateway.join-client-key" \
    "$ROOT/scripts/phase-join-acceptance.sh" "$NODE"
else
  printf 'INCOMPLETE Genesis was created without bootstrap access; it is not a full lifecycle PASS\n' >&2
fi
