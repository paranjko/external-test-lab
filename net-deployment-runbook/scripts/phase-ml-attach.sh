#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

NODE="${1:-}"
topology_contains_node "$NODE" || die "ml attach expects an alias from GDC_NODE_ALIASES, got: $NODE"
ML_HOST="$(node_ml_host "$NODE" || true)"
[[ -n "$ML_HOST" ]] || die "no network GPU is configured for $NODE; set GDC_NODE_ML_HOSTS='$NODE=<ml-ssh-alias>' in .env"
[[ -e "$STATE/joined/$NODE" ]] || die "$NODE is not joined; join the validator before attaching its network GPU"
ML_ENDPOINT="$(ssh -G "$ML_HOST" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
[[ -n "$ML_ENDPOINT" ]] || die "cannot determine network GPU endpoint from SSH alias $ML_HOST"
record_phase_profile "ml-attach-$NODE"

step "Render network GPU configuration for $NODE"
ML_ENV="$GENERATED/$ML_HOST.env"
AGENT_ENV="$GENERATED/agents/$ML_HOST.env"
PROFILE="$(node_gpu_profile "$NODE")"
ML_IMAGE="$MLNODE_GENERIC_IMAGE"
[[ "$PROFILE" == blackwell-* ]] && ML_IMAGE="$MLNODE_BLACKWELL_IMAGE"
write_env "$ML_ENV" \
  "COMPOSE_PROJECT_NAME=$ML_HOST" \
  'ML_BIND_IP=0.0.0.0' \
  "PUBLIC_URL=https://$(node_public_host "$NODE")" \
  "GDC_STOP_POC_AT_WINDDOWN=${GDC_STOP_POC_AT_WINDDOWN:-true}" \
  "HF_HOME=$HF_CACHE_ROOT" \
  "MLNODE_IMAGE=$ML_IMAGE" \
  "MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE" \
  "VLLM_ATTENTION_BACKEND=$(attention_backend_for_profile "$PROFILE")" \
  'POC_BATCH_SIZE_DEFAULT=32'
"$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$ML_HOST" --output "$AGENT_ENV" >/dev/null

step "Install and start network GPU $ML_HOST for $NODE"
REMOTE="/tmp/gdc-deploy-$$-$ML_HOST"
ssh "$ML_HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/02-node/" "$ML_HOST:$REMOTE/02-node/"
rsync -a "$ROOT/04-ops/agent/" "$ML_HOST:$REMOTE/agent/"
scp -q "$ML_ENV" "$ML_HOST:$REMOTE/ml.env"
scp -q "$AGENT_ENV" "$ML_HOST:$REMOTE/agent.env"
ssh -T "$ML_HOST" "sudo '$REMOTE/02-node/ml-only/install-ml.sh' --node-name '$ML_HOST' --env '$REMOTE/ml.env'; sudo '$REMOTE/agent/install-agent.sh' '$REMOTE/agent.env' --gpu; rm -rf '$REMOTE'; cd '/srv/dai/deploy/$ML_HOST' && ./start-ml.sh .env '$MODEL_ID' '$MLNODE_DTYPE' '$MODEL_REVISION' '$MLNODE_TENSOR_PARALLEL_SIZE' '$MLNODE_MAX_NUM_SEQS' '$MLNODE_GPU_MEMORY_UTILIZATION' '$MLNODE_CONTEXT_LENGTH'"
start_stack "$ML_HOST" /srv/dai/monitoring-agent

step "Wait until $NODE has a chain-recorded INFERENCE hardware node"
"$ROOT/scripts/wait-hardware-node.sh" "$NODE"

step "Record the explicit Network Node to external GPU association"
link_record="$(jq -cn \
  --arg validator_alias "$NODE" \
  --arg ml_ssh_alias "$ML_HOST" \
  --arg ml_endpoint "$ML_ENDPOINT" \
  '{schema_version:1,validator_alias:$validator_alias,ml_ssh_alias:$ml_ssh_alias,ml_endpoint:$ml_endpoint}')"
printf '%s\n' "$link_record" | ssh -T "$NODE" "set -Eeuo pipefail
  install_path='/srv/dai/deploy/$NODE/gdc-ml-link.json'
  sudo install -d -m 0750 '/srv/dai/deploy/$NODE'
  sudo tee \"\${install_path}.tmp\" >/dev/null
  sudo install -m 0640 \"\${install_path}.tmp\" \"\${install_path}\"
  sudo rm -f \"\${install_path}.tmp\""

install -d -m 0700 "$STATE/ml-attached"
printf '%s\n' "$ML_HOST" >"$STATE/ml-attached/$NODE"
printf 'READY network GPU %s is attached to %s\n' "$ML_HOST" "$NODE"
