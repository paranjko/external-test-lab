#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile genesis
require_ml_qualification "$GENESIS_NODE"
TIME_SPEC="${1:---time=+1m}"
[[ "$TIME_SPEC" =~ ^--time=\+([1-9][0-9]*)m$ ]] || die 'expected --time=+Nm'
GENESIS_LEAD_MINUTES="${BASH_REMATCH[1]}"
genesis_identity_inputs=(
  "$SECRETS/operator.keyring"
  "$SECRETS/$GENESIS_NODE.keyring"
  "$SECRETS/$GENESIS_NODE.postgres"
  "$ACCOUNTS/$GENESIS_NODE-cold.json"
  "$ACCOUNTS/gdc-gateway-cold.json"
  "$IDENTITIES/$GENESIS_NODE.json"
)
identity_inputs_ready=true
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || identity_inputs_ready=false
done
if [[ "$identity_inputs_ready" != true ]]; then
  step 'Create Genesis operator secrets, node0 identities, and gateway account'
  "$ROOT/scripts/phase-identities.sh"
fi
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || die "Genesis identity input was not created: $input"
done
GENESIS_TIME="$(date -u -d "+${GENESIS_LEAD_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"

step "Build and verify the one-participant Genesis at $GENESIS_TIME"
"$ROOT/01-identities-genesis/build-genesis.sh" --inventory "$INVENTORY" --identities-dir "$IDENTITIES" --secrets-dir "$SECRETS" --genesis-time "$GENESIS_TIME" --output-dir "$GENESIS"
"$ROOT/01-identities-genesis/verify-genesis.sh" "$GENESIS/genesis.json" "$GENESIS/genesis.sha256" "$CHAIN_ID"
for profile_field in genesis_sha256 genesis_overrides_sha256; do
  profile_value="$(jq -er --arg field "$profile_field" '.[$field]' "$GENESIS/ceremony-record.json")"
  printf '%s=%s\n' "$profile_field" "$profile_value" >>"$STATE/phase-profiles/genesis.env"
  printf 'PROFILE phase=genesis %s=%s\n' "$profile_field" "$profile_value"
done

step "Render only $GENESIS_NODE"
NODE="$GENESIS_NODE"
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
"$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNTS/$NODE-cold.json" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS" --output "$NODE_DIR/.env" >/dev/null
"$ROOT/02-node/render-node-config.sh" --node-name "$NODE" --node-index "$(node_index "$NODE")" --profile "$(node_gpu_profile "$NODE")" --output "$NODE_DIR/node-config.json" >/dev/null
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
"$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITIES/$NODE.json" "$INVENTORY"
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
printf '\nGenesis launched with %s as the only participant.\n' "$NODE"
