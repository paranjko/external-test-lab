#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

NODE="${1:-}"
ML_ENDPOINT="${2:-}"
ML_HOST="${3:-}"
topology_contains_node "$NODE" || die "ml add expects an alias from GDC_NODE_ALIASES, got: $NODE"
[[ "$ML_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$ML_HOST" != "$NODE" ]] \
  || die 'ml add requires a distinct ML SSH alias'
[[ "$ML_ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]] \
  || die 'ml add requires --mlnode-peer with an IPv4 address or DNS name'
ssh_ready "$NODE" || die "$NODE is unreachable"
ssh_ready "$ML_HOST" || die "$ML_HOST is unreachable"
"$ROOT/scripts/check-running-network-node.sh" "$NODE" \
  || die "$NODE is not a running Network Node with a deployed DAPI endpoint; start or join it before adding an ML endpoint"

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/ml-add-$NODE-$ML_HOST"
mkdir -p "$RUN"
chmod 0700 "$RUN"
REMOTE="/tmp/gdc-ml-add-${GDC_RUN_ID:-manual}-$ML_HOST"

step "Validate $ML_HOST as a new ML-only Host for $NODE"
if ! ssh -T "$ML_HOST" "set -Eeuo pipefail
  sudo test ! -e /srv/dai/identity/p2p/node_key.json
  sudo test ! -e /srv/dai/signer/tmkms
  if sudo test -e /srv/dai/deploy/compose.yaml; then
    sudo test -s '$REMOTE/02-node/ml-only/install-ml.sh'
    printf 'READY resume partial ML-only setup for %s\\n' '$ML_HOST'
  fi"
then
  die "$ML_HOST is not a clean ML-only Host; refusing to overwrite an existing deployment or validator identity"
fi

current_config="$RUN/node-config.before.json"
ssh -T "$NODE" 'sudo cat /srv/dai/deploy/node-config.json' >"$current_config"
jq -e 'type == "array" and length > 0' "$current_config" >/dev/null \
  || die "$NODE has no usable deployed ML endpoint configuration"

next_config="$RUN/node-config.next.json"
node_id_file="$RUN/external-node-id"
"$ROOT/scripts/add-network-ml-endpoint.sh" \
  --input "$current_config" --ml-host "$ML_ENDPOINT" --ml-alias "$ML_HOST" \
  --output "$next_config" --id-output "$node_id_file"
EXTERNAL_NODE_ID="$(<"$node_id_file")"

# Prepare the target as ML-only before any Network Node configuration changes.
GDC_PREPARE_HOSTS="$ML_HOST" GDC_PREPARE_ML_ONLY_HOST="$ML_HOST" \
  GDC_PREPARE_ML_ONLY_FOR="$NODE" "$ROOT/scripts/phase-prepare.sh"

step "Install and start additional ML endpoint $ML_HOST for $NODE"
ML_ENV="$RUN/$ML_HOST.env"
AGENT_ENV="$RUN/$ML_HOST-agent.env"
write_env "$ML_ENV" \
  "COMPOSE_PROJECT_NAME=$ML_HOST" \
  'ML_BIND_IP=0.0.0.0' \
  "PUBLIC_URL=https://$(node_public_host "$NODE")" \
  "GDC_STOP_POC_AT_WINDDOWN=${GDC_STOP_POC_AT_WINDDOWN:-true}" \
  "HF_HOME=$HF_CACHE_ROOT" \
  "MLNODE_IMAGE=$MLNODE_GENERIC_IMAGE" \
  "MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE" \
  'POC_BATCH_SIZE_DEFAULT=32'
"$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$ML_HOST" \
  --allow-ml-only-host "$ML_HOST" --output "$AGENT_ENV" >/dev/null

ssh "$ML_HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE/scripts'"
rsync -a "$ROOT/02-node/" "$ML_HOST:$REMOTE/02-node/"
rsync -a "$ROOT/04-ops/agent/" "$ML_HOST:$REMOTE/agent/"
scp -q "$ROOT/scripts/lib-lock.sh" "$ML_HOST:$REMOTE/scripts/lib-lock.sh"
scp -q "$ML_ENV" "$ML_HOST:$REMOTE/ml.env"
scp -q "$AGENT_ENV" "$ML_HOST:$REMOTE/agent.env"
ssh -T "$ML_HOST" "set -Eeuo pipefail
  sudo '$REMOTE/02-node/ml-only/install-ml.sh' --node-name '$ML_HOST' --env '$REMOTE/ml.env'
  sudo '$REMOTE/agent/install-agent.sh' '$ML_HOST' '$REMOTE/agent.env' --gpu
  rm -rf '$REMOTE'
  cd /srv/dai/deploy
  ./start-ml.sh .env '$MODEL_ID' '$MLNODE_DTYPE' '$MODEL_REVISION' '$MLNODE_TENSOR_PARALLEL_SIZE' '$MLNODE_MAX_NUM_SEQS' '$MLNODE_GPU_MEMORY_UTILIZATION' '$MLNODE_CONTEXT_LENGTH'"
start_stack "$ML_HOST" /srv/dai/deploy/monitoring-agent
"$ROOT/scripts/capture-deployed-ml-evidence.sh" "$RUN/ml-runtime" "$MODEL_ID" "$ML_HOST"

step "Add $ML_HOST to $NODE API endpoint configuration"
REMOTE_CONFIG="/tmp/gdc-ml-config-${GDC_RUN_ID:-manual}-$NODE.json"
scp -q "$next_config" "$NODE:$REMOTE_CONFIG"
if ! ssh -T "$NODE" "set -Eeuo pipefail
  sudo install -m 0644 '$REMOTE_CONFIG' '/srv/dai/deploy/node-config.json.tmp'
  sudo mv '/srv/dai/deploy/node-config.json.tmp' '/srv/dai/deploy/node-config.json'
  rm -f '$REMOTE_CONFIG'
  cd /srv/dai/deploy
  sudo ./sync-node-config.sh"; then
  scp -q "$current_config" "$NODE:$REMOTE_CONFIG"
  ssh -T "$NODE" "sudo install -m 0644 '$REMOTE_CONFIG' '/srv/dai/deploy/node-config.json.tmp' && sudo mv '/srv/dai/deploy/node-config.json.tmp' '/srv/dai/deploy/node-config.json' && rm -f '$REMOTE_CONFIG'" || true
  die "DAPI rejected the additional ML endpoint; restored the prior node configuration and retained $ML_HOST for inspection"
fi

api_nodes="$RUN/dapi-nodes.json"
ssh -T "$NODE" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes' >"$api_nodes"
jq -e --arg id "$EXTERNAL_NODE_ID" --arg host "$ML_ENDPOINT" '
  type == "array" and any(.[]; .node.id == $id and .node.host == $host
    and .node.inference_port == 5000 and .node.poc_port == 5000)
' "$api_nodes" >/dev/null || die "$NODE DAPI did not retain the additional ML endpoint after synchronization"

existing_link="$(ssh -T "$NODE" 'sudo cat /srv/dai/deploy/gdc-ml-link.json 2>/dev/null' || true)"
new_link=''
if jq -e --arg node "$NODE" '.schema_version == 2 and .validator_alias == $node and (.ml_hosts | type == "array")' \
  <<<"$existing_link" >/dev/null 2>&1; then
  new_link="$(jq -c --arg alias "$ML_HOST" --arg endpoint "$ML_ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
    '.ml_hosts += [{ssh_alias:$alias,endpoint:$endpoint,node_id:$node_id}]' <<<"$existing_link")"
elif jq -e --arg node "$NODE" '.schema_version == 1 and .validator_alias == $node' \
  <<<"$existing_link" >/dev/null 2>&1; then
  legacy_endpoint="$(jq -r .ml_endpoint <<<"$existing_link")"
  legacy_node_id="$(jq -er --arg endpoint "$legacy_endpoint" '.[] | select(.host == $endpoint) | .id' "$current_config")" \
    || die "legacy ML link for $NODE does not match its deployed node configuration"
  new_link="$(jq -cn --arg node "$NODE" --arg alias "$(jq -r .ml_ssh_alias <<<"$existing_link")" \
    --arg endpoint "$legacy_endpoint" --arg legacy_node_id "$legacy_node_id" --arg new_alias "$ML_HOST" \
    --arg new_endpoint "$ML_ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
    '{schema_version:2,validator_alias:$node,ml_hosts:[{ssh_alias:$alias,endpoint:$endpoint,node_id:$legacy_node_id},{ssh_alias:$new_alias,endpoint:$new_endpoint,node_id:$node_id}]}')"
else
  new_link="$(jq -cn \
    --arg validator_alias "$NODE" --arg ml_alias "$ML_HOST" --arg ml_endpoint "$ML_ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
    '{schema_version:2,validator_alias:$validator_alias,ml_hosts:[{ssh_alias:$ml_alias,endpoint:$ml_endpoint,node_id:$node_id}]}')"
fi
link_record="$new_link"
printf '%s\n' "$link_record" | ssh -T "$NODE" 'set -Eeuo pipefail
  install_path=/srv/dai/deploy/gdc-ml-link.json
  sudo install -d -m 0750 /srv/dai/deploy
  sudo tee "${install_path}.tmp" >/dev/null
  sudo install -m 0640 "${install_path}.tmp" "$install_path"
  sudo rm -f "${install_path}.tmp"'
install -d -m 0700 "$STATE/ml-attached"
printf '%s\n' "$link_record" >"$STATE/ml-attached/$NODE.json"
chmod 0600 "$STATE/ml-attached/$NODE.json"

printf 'READY added ML endpoint node_id=%s host=%s to %s without changing validator identity or signer state\n' \
  "$EXTERNAL_NODE_ID" "$ML_HOST" "$NODE"
