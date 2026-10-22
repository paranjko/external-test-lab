#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

NODE="${1:-}"
ML_ENDPOINT="${2:-}"
ML_HOST="${3:-}"
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die 'ml add requires a valid Network Node SSH alias'
[[ "$ML_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$ML_HOST" != "$NODE" ]] \
  || die 'ml add requires a distinct ML SSH alias'

# This is a narrow ownership discriminator, not a second lending preflight.
# A regular validator identity enters the lending path, an explicitly clean
# Host may use ML-only provisioning, and every residual/symlinked identity is
# unsafe to classify as either. The lending phase remains the owner of the
# complete deployment and signer validation immediately before a stop.
ownership_rc=0
ssh -T "$ML_HOST" 'set -Eeuo pipefail
  identity=/srv/dai/identity/p2p/node_key.json
  identity_root=/srv/dai/identity
  signer=/srv/dai/signer/tmkms
  if sudo test -L "$identity" || sudo test -L "$identity_root" || sudo test -L "$signer"; then
    exit 11
  fi
  if sudo test -f "$identity"; then
    exit 0
  fi
  if sudo test -e "$identity" || sudo test -e "$identity_root" || sudo test -e "$signer"; then
    exit 11
  fi
  exit 10' >/dev/null || ownership_rc=$?
case "$ownership_rc" in
  0) exec bash "$ROOT/scripts/phase-ml-lend.sh" "$NODE" "$ML_ENDPOINT" "$ML_HOST" ;;
  10) ;;
  *)
    printf 'OPERATOR ACTION REQUIRED cannot safely classify %s as a validator or ML-only Host; leave it unchanged and resolve its retained identity state before retrying\n' "$ML_HOST" >&2
    exit 195
    ;;
esac

topology_contains_node "$NODE" || die "ml add expects an alias from GDC_NODE_ALIASES, got: $NODE"
"$ROOT/scripts/check-running-network-node.sh" "$NODE" \
  || die "$NODE is not a running Network Node with a deployed DAPI endpoint; start or join it before adding an ML endpoint"

[[ "$ML_ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]] \
  || die 'ml add requires --mlnode-peer for a new ML-only Host'

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/ml-add-$NODE-$ML_HOST"
mkdir -p "$RUN"
chmod 0700 "$RUN"
REMOTE="/tmp/gdc-ml-add-${GDC_RUN_ID:-manual}-$ML_HOST"
ml_parent_record="$GDC_DATA_ROOT/$ML_HOST/state/ml-parent.json"

if [[ -e "$ml_parent_record" || -L "$ml_parent_record" ]]; then
  if [[ ! -f "$ml_parent_record" || -L "$ml_parent_record" ]]; then
    printf 'OPERATOR ACTION REQUIRED cannot safely read the ML attachment record for %s; leave it unchanged and repair or remove the record before retrying\n' "$ML_HOST" >&2
    exit 195
  fi
  attached_parent="$(jq -er 'select(.schema_version == 1 and .kind == "gdc-ml-parent") | .network_alias' "$ml_parent_record" 2>/dev/null)" \
    || {
      printf 'OPERATOR ACTION REQUIRED cannot safely read the ML attachment record for %s; leave it unchanged and repair or remove the record before retrying\n' "$ML_HOST" >&2
      exit 195
    }
  if [[ "$attached_parent" == "$NODE" ]]; then
    printf 'OPERATOR ACTION REQUIRED %s is already attached to %s; remove it before adding it again\n' "$ML_HOST" "$NODE" >&2
    exit 195
  fi
  printf 'OPERATOR ACTION REQUIRED %s is already attached to %s; remove it before attaching it to %s\n' "$ML_HOST" "$attached_parent" "$NODE" >&2
  exit 195
fi

bootstrap_mlnode="$RUN/bootstrap-mlnode.json"
# Hosts joined before Bootstrap was added to role input have no explicit URL.
# Keep them operable through the public Community DevNet convention, while an
# explicitly configured Bootstrap URL remains authoritative.
bootstrap_url="$(network_bootstrap_url)"
"$ROOT/scripts/resolve-bootstrap-mlnode.sh" \
  --url "$bootstrap_url" --run-id "${GDC_RUN_ID:-manual}" --output "$bootstrap_mlnode"
bootstrap_mlnode_image="$(jq -er '.mlnode.image' "$bootstrap_mlnode")"
bootstrap_mlnode_proxy_image="$(jq -er '.mlnode.proxy_image' "$bootstrap_mlnode")"
bootstrap_model_id="$(jq -er '.mlnode.model_id' "$bootstrap_mlnode")"
bootstrap_model_revision="$(jq -er '.mlnode.model_revision' "$bootstrap_mlnode")"
bootstrap_context_length="$(jq -er '.mlnode.context_length' "$bootstrap_mlnode")"
bootstrap_max_num_seqs="$(jq -er '.mlnode.max_num_seqs' "$bootstrap_mlnode")"
bootstrap_gpu_memory_utilization="$(jq -er '.mlnode.gpu_memory_utilization' "$bootstrap_mlnode")"
bootstrap_dtype="$(jq -er '.mlnode.dtype' "$bootstrap_mlnode")"
bootstrap_tensor_parallel_size="$(jq -er '.mlnode.tensor_parallel_size' "$bootstrap_mlnode")"
parent_mlnode_digest="$(ssh -T "$NODE" "sudo docker inspect --format '{{.Image}}' '${NODE}-mlnode-1'")" \
  || die "$NODE does not expose a running MLNode container"
"$ROOT/scripts/verify-bootstrap-mlnode-parent.sh" --receipt "$bootstrap_mlnode" --image "$parent_mlnode_digest"

step "Validate $ML_HOST as a new ML-only Host for $NODE"
if ! ssh -T "$ML_HOST" "set -Eeuo pipefail
  sudo test ! -e /srv/dai/identity/p2p/node_key.json
  sudo test ! -e /srv/dai/signer/tmkms
  if sudo test -e /srv/dai/deploy/compose.yaml; then
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
  "MLNODE_IMAGE=$bootstrap_mlnode_image" \
  "MLNODE_PROXY_IMAGE=$bootstrap_mlnode_proxy_image" \
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
  ./start-ml.sh .env '$bootstrap_model_id' '$bootstrap_dtype' '$bootstrap_model_revision' '$bootstrap_tensor_parallel_size' '$bootstrap_max_num_seqs' '$bootstrap_gpu_memory_utilization' '$bootstrap_context_length'"
start_stack "$ML_HOST" /srv/dai/deploy/monitoring-agent
"$ROOT/scripts/capture-deployed-ml-evidence.sh" "$RUN/ml-runtime" "$bootstrap_model_id" "$ML_HOST"

step "Add $ML_HOST to $NODE API endpoint configuration"
bash "$ROOT/scripts/ensure-ml-callback.sh" "$NODE" "$ML_HOST" "$ML_ENDPOINT"
REMOTE_CONFIG_DIR="/tmp/gdc-ml-config-${GDC_RUN_ID:-manual}-$NODE"
REMOTE_CONFIG="$REMOTE_CONFIG_DIR/node-config.json"
REMOTE_SYNC="$REMOTE_CONFIG_DIR/sync-node-config.sh"
ssh -T "$NODE" "rm -rf '$REMOTE_CONFIG_DIR' && mkdir -p '$REMOTE_CONFIG_DIR'"
scp -q "$next_config" "$NODE:$REMOTE_CONFIG"
scp -q "$ROOT/02-node/sync-node-config.sh" "$NODE:$REMOTE_SYNC"
if ! ssh -T "$NODE" "set -Eeuo pipefail
  sudo install -m 0644 '$REMOTE_CONFIG' '/srv/dai/deploy/node-config.json.tmp'
  sudo mv '/srv/dai/deploy/node-config.json.tmp' '/srv/dai/deploy/node-config.json'
  sudo bash '$REMOTE_SYNC'
  rm -rf '$REMOTE_CONFIG_DIR'"; then
  scp -q "$current_config" "$NODE:$REMOTE_CONFIG"
  ssh -T "$NODE" "sudo install -m 0644 '$REMOTE_CONFIG' '/srv/dai/deploy/node-config.json.tmp' && sudo mv '/srv/dai/deploy/node-config.json.tmp' '/srv/dai/deploy/node-config.json' && rm -rf '$REMOTE_CONFIG_DIR'" || true
  die "could not synchronize the additional ML endpoint; restored the prior node configuration and retained $ML_HOST for inspection"
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
install -d -m 0700 "$(dirname "$ml_parent_record")"
ml_parent_tmp="$(mktemp "$(dirname "$ml_parent_record")/.ml-parent.XXXXXX")"
jq -cn --arg network_alias "$NODE" --arg ml_alias "$ML_HOST" --arg endpoint "$ML_ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
  '{schema_version:1,kind:"gdc-ml-parent",network_alias:$network_alias,ml_alias:$ml_alias,endpoint:$endpoint,node_id:$node_id}' \
  >"$ml_parent_tmp"
chmod 0600 "$ml_parent_tmp"
mv -f -- "$ml_parent_tmp" "$ml_parent_record"

printf 'READY added ML endpoint node_id=%s host=%s to %s without changing validator identity or signer state\n' \
  "$EXTERNAL_NODE_ID" "$ML_HOST" "$NODE"
