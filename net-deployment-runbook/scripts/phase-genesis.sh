#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile genesis
require_ml_qualification gdc-node0
TIME_SPEC="${1:---time=+1m}"
[[ "$TIME_SPEC" =~ ^--time=\+([1-9][0-9]*)m$ ]] || die 'expected --time=+Nm'
GENESIS_TIME="$(date -u -d "+${BASH_REMATCH[1]} minutes" +%Y-%m-%dT%H:%M:%SZ)"
[[ -s "$IDENTITIES/gdc-node0.json" ]] || die 'run identities first'

step "Build and verify the one-participant Genesis at $GENESIS_TIME"
"$ROOT/01-identities-genesis/build-genesis.sh" --inventory "$INVENTORY" --identities-dir "$IDENTITIES" --secrets-dir "$SECRETS" --genesis-time "$GENESIS_TIME" --output-dir "$GENESIS"
"$ROOT/01-identities-genesis/verify-genesis.sh" "$GENESIS/genesis.json" "$GENESIS/genesis.sha256" "$CHAIN_ID"

step 'Render only gdc-node0'
NODE=gdc-node0
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
"$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNTS/$NODE-cold.json" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS" --output "$NODE_DIR/.env" >/dev/null
"$ROOT/02-node/render-node-config.sh" --node-name "$NODE" --profile "$NODE0_GPU_PROFILE" --output "$NODE_DIR/node-config.json" >/dev/null
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --output "$GENERATED/edge/$NODE.env"
"$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$NODE" --output "$GENERATED/agents/$NODE.env"

step 'Install gdc-node0 deployment'
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
"$ROOT/03-join/wait-synced.sh" "https://$NODE0_PUBLIC_HOST/chain-rpc" "https://$NODE0_PUBLIC_HOST/chain-rpc"
"$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITIES/$NODE.json" "$INVENTORY"
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
printf '\nGenesis launched with gdc-node0 as the only participant.\n'
