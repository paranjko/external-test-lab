#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile "join-${1:-unknown}"
NODE="$(node_name "${1:-}")"
host_is_skipped "$NODE" && die "$NODE is excluded by GDC_SKIP_HOSTS"
INDEX="${NODE#gdc-node}"
HANDOFF_DIR="${GDC_NODE_HANDOFF_DIR:-}"
if [[ -n "$HANDOFF_DIR" ]]; then
  HANDOFF_DIR="$(cd "$HANDOFF_DIR" && pwd)"
  [[ -s "$HANDOFF_DIR/manifest.sha256" ]] || die "handoff bundle lacks manifest.sha256: $HANDOFF_DIR"
  (cd "$HANDOFF_DIR" && sha256sum -c manifest.sha256) || die 'handoff bundle checksum verification failed'
  [[ "$(<"$HANDOFF_DIR/node")" == "$NODE" ]] || die "handoff bundle is not for $NODE"
  [[ "$(<"$HANDOFF_DIR/chain-id")" == "$CHAIN_ID" ]] || die 'handoff bundle chain ID differs from local configuration'
  step "Import the verified $NODE handoff bundle"
  install -d -m 0700 "$SECRETS" "$GENESIS" "$ACCOUNTS"
  install -m 0600 "$HANDOFF_DIR/secrets/$NODE.keyring" "$SECRETS/$NODE.keyring"
  install -m 0600 "$HANDOFF_DIR/secrets/$NODE.postgres" "$SECRETS/$NODE.postgres"
  install -m 0600 "$HANDOFF_DIR/accounts/$NODE-cold.json" "$ACCOUNTS/$NODE-cold.json"
  install -m 0600 "$HANDOFF_DIR/genesis/genesis.json" "$GENESIS/genesis.json"
  install -m 0600 "$HANDOFF_DIR/genesis/genesis.sha256" "$GENESIS/genesis.sha256"
  install -m 0600 "$HANDOFF_DIR/genesis/genesis-seeds.txt" "$GENESIS/genesis-seeds.txt"
fi
if [[ "$INDEX" == 4 ]]; then
  ML_TARGET='gdc-node4-ml'
else
  ML_TARGET="$NODE"
fi
ensure_ml_qualification "$ML_TARGET"
URL="$(node_url "$NODE")"
PUBLIC_HOST="${URL#https://}"
getent ahostsv4 "$PUBLIC_HOST" | grep -q . || die "$PUBLIC_HOST does not resolve to IPv4"
ACCOUNT="$ACCOUNTS/$NODE-cold.json"
IDENTITY="$IDENTITIES/$NODE.json"
[[ -s "$GENESIS/genesis.json" && -s "$GENESIS/genesis-seeds.txt" ]] || die 'run genesis first'
if [[ ! -s "$ACCOUNT" ]]; then
  step "Create $NODE cold account"
  "$ROOT/01-identities-genesis/create-cold-accounts.sh" "$SECRETS/operator.keyring" "$NODE"
fi
[[ -s "$ACCOUNT" ]] || die "missing public cold account for $NODE"

if [[ ! -s "$IDENTITY" ]]; then
  step "Create $NODE identity"
  "$ROOT/01-identities-genesis/collect-identities.sh" "$INVENTORY" "$SECRETS" "$IDENTITIES" "$ROOT/artifacts/mnemonics" "$NODE"
fi

step "Render $NODE"
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
env_args=(--inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNT" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS")
if [[ "$INDEX" == 4 ]]; then
  node4_callback_address="$(getent ahostsv4 "$NODE4_PUBLIC_HOST" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  if [[ ! "$node4_callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    node4_callback_address="$(ssh -G gdc-node4 2>/dev/null | awk '$1 == "hostname" {print $2; exit}' || true)"
  fi
  [[ "$node4_callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'cannot determine gdc-node4 callback IPv4'
  env_args+=(--poc-callback-url "http://$node4_callback_address:9100" --ml-callback-bind 0.0.0.0)
fi
"$ROOT/02-node/render-node-env.sh" "${env_args[@]}" --output "$NODE_DIR/.env" >/dev/null
PROFILE_VAR="NODE${INDEX}_GPU_PROFILE"
config_args=(--node-name "$NODE" --profile "${!PROFILE_VAR}" --output "$NODE_DIR/node-config.json")
[[ "$INDEX" == 4 ]] && config_args+=(--ml-host "$NODE4_ML_ENDPOINT" --ml-poc-port 5000)
"$ROOT/02-node/render-node-config.sh" "${config_args[@]}" >/dev/null
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --output "$GENERATED/edge/$NODE.env" >/dev/null
"$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$NODE" --output "$GENERATED/agents/$NODE.env" >/dev/null

step "Install $NODE deployment"
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
local_ml=(); gpu=()
[[ "$INDEX" != 4 ]] && local_ml=(--local-ml) && gpu=(--gpu)
ssh -T "$NODE" "sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' ${local_ml[*]}; sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; sudo '$REMOTE/agent/install-agent.sh' '$REMOTE/agent.env' ${gpu[*]}; rm -rf '$REMOTE'"

if [[ "$INDEX" == 4 ]]; then
  step 'Install and start the remote Blackwell MLNode'
  ML_ENV="$GENERATED/gdc-node4-ml.env"
  AGENT_ENV="$GENERATED/agents/gdc-node4-ml.env"
  cat >"$ML_ENV" <<EOF
ML_BIND_IP=0.0.0.0
HF_HOME=$HF_CACHE_ROOT
MLNODE_IMAGE=$MLNODE_BLACKWELL_IMAGE
MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE
VLLM_ATTENTION_BACKEND=$(attention_backend_for_profile "$NODE4_GPU_PROFILE")
POC_BATCH_SIZE_DEFAULT=32
EOF
  "$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host gdc-node4-ml --output "$AGENT_ENV" >/dev/null
  ML_REMOTE="/tmp/gdc-deploy-$$-gdc-node4-ml"
  ssh gdc-node4-ml "rm -rf '$ML_REMOTE' && mkdir -p '$ML_REMOTE'"
  rsync -a "$ROOT/02-node/" "gdc-node4-ml:$ML_REMOTE/02-node/"
  rsync -a "$ROOT/04-ops/agent/" "gdc-node4-ml:$ML_REMOTE/agent/"
  scp -q "$ML_ENV" "gdc-node4-ml:$ML_REMOTE/ml.env"
  scp -q "$AGENT_ENV" "gdc-node4-ml:$ML_REMOTE/agent.env"
  ssh -T gdc-node4-ml "sudo '$ML_REMOTE/02-node/ml-only/install-ml.sh' '$ML_REMOTE/ml.env'; sudo '$ML_REMOTE/agent/install-agent.sh' '$ML_REMOTE/agent.env' --gpu; rm -rf '$ML_REMOTE'; cd /srv/dai/deploy/gdc-node4-ml && ./start-ml.sh .env '$MODEL_ID' '$MLNODE_DTYPE' '$MODEL_REVISION' '$MLNODE_TENSOR_PARALLEL_SIZE' '$MLNODE_MAX_NUM_SEQS' '$MLNODE_GPU_MEMORY_UTILIZATION' '$MLNODE_CONTEXT_LENGTH'"
  start_stack gdc-node4-ml /srv/dai/monitoring-agent
fi

step "Start $NODE"
start_stack "$NODE" /srv/dai/edge
start_stack "$NODE" /srv/dai/monitoring-agent
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh"

step "Wait until $NODE is synchronized"
"$ROOT/03-join/wait-synced.sh" "$URL/chain-rpc" "https://$NODE0_PUBLIC_HOST/chain-rpc"
step "Register $NODE before funding"
ADDRESS="$(jq -r .address "$ACCOUNT")"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./register-participant.sh .env >register-participant.log 2>&1" || true
if ! "$ROOT/03-join/wait-registered.sh" "https://$NODE0_PUBLIC_HOST" "$ADDRESS"; then
  ssh "$NODE" "tail -100 /srv/dai/deploy/$NODE/register-participant.log" >&2
  exit 1
fi
if [[ -n "$HANDOFF_DIR" ]]; then
  REQUEST_DIR="$ROOT/artifacts/operator-requests"
  REQUEST="$REQUEST_DIR/$NODE-activation-request.json"
  install -d -m 0700 "$REQUEST_DIR"
  jq -n \
    --arg schema gonka-devnet-community-node-handoff-v1 \
    --arg node "$NODE" --arg chain_id "$CHAIN_ID" --arg address "$ADDRESS" \
    --slurpfile identity "$IDENTITY" \
    '{schema: $schema, node: $node, chain_id: $chain_id, cold_address: $address, identity: $identity[0]}' \
    >"$REQUEST"
  chmod 600 "$REQUEST"
  printf '\n%s is registered but intentionally not activated. Transfer this request to the controller operator:\n%s\n' "$NODE" "$REQUEST"
  exit 0
fi
step "Fund $NODE and grant ML operational permissions"
"$ROOT/03-join/fund-account.sh" "$ACCOUNT" "$INVENTORY"
"$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITY" "$INVENTORY"
step "Wait until $NODE is ACTIVE"
"$ROOT/03-join/wait-active.sh" "https://$NODE0_PUBLIC_HOST" "$ADDRESS"
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
printf '\n%s joined successfully.\n' "$NODE"
