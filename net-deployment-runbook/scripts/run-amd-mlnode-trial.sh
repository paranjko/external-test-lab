#!/usr/bin/env bash
set -Eeuo pipefail

image="${1:-}"
[[ "$image" == *@sha256:* ]] || {
  echo 'usage: run-amd-mlnode-trial.sh IMAGE@sha256:DIGEST' >&2
  exit 2
}

container="${GDC_AMD_MLNODE_CONTAINER:-gdc-amd-mlnode-trial}"
port="${GDC_AMD_MLNODE_PORT:-18080}"
hf_home="${GDC_AMD_HF_HOME:-/srv/dai/hf-cache}"
model="${GDC_AMD_MODEL:-Qwen/Qwen3-0.6B}"
revision="${GDC_AMD_MODEL_REVISION:-c1899de289a04d12100db370d81485cdf75e47ca}"
dtype="${GDC_AMD_DTYPE:-auto}"
context="${GDC_AMD_CONTEXT:-2048}"
max_seqs="${GDC_AMD_MAX_SEQS:-64}"
gpu_utilization="${GDC_AMD_GPU_UTILIZATION:-0.85}"
timeout_seconds="${GDC_AMD_TRIAL_TIMEOUT_SECONDS:-1800}"

[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'invalid trial container name' >&2; exit 2; }
[[ "$port" =~ ^[0-9]+$ && "$timeout_seconds" =~ ^[0-9]+$ ]] || { echo 'invalid trial port or timeout' >&2; exit 2; }
[[ -e /dev/kfd ]] || { echo 'AMD ROCm /dev/kfd is unavailable' >&2; exit 1; }
render_node="$(basename "$(readlink -f /sys/class/drm/renderD128 2>/dev/null || true)")"
[[ "$render_node" == renderD* ]] || { echo 'AMD DRM renderD128 is unavailable' >&2; exit 1; }
docker image inspect "$image" >/dev/null || { echo "AMD MLNode image is unavailable locally: $image" >&2; exit 1; }
if docker container inspect "$container" >/dev/null 2>&1; then
  echo "AMD MLNode trial container already exists: $container" >&2
  exit 1
fi
mkdir -p "$hf_home"
kfd_gid="$(stat -c '%g' /dev/kfd)"
render_gid="$(stat -c '%g' "/dev/dri/$render_node")"

docker run -d --name "$container" --restart=no --ipc=host \
  --device /dev/kfd --device "/dev/dri/$render_node" \
  --group-add "$kfd_gid" --group-add "$render_gid" \
  --mount "type=bind,src=$hf_home,dst=/root/.cache" \
  --publish "127.0.0.1:${port}:8080" \
  --env HF_HOME=/root/.cache --env POC_BATCH_SIZE_DEFAULT=32 \
  "$image" uvicorn api.app:app --host=0.0.0.0 --port=8080 >/dev/null

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
  if curl -fsS "http://127.0.0.1:${port}/readyz" >/dev/null; then break; fi
  sleep 2
done
curl -fsS "http://127.0.0.1:${port}/readyz" >/dev/null || {
  docker logs --tail 100 "$container" >&2 || true
  exit 1
}

request="$(jq -nc --arg model "$model" --arg dtype "$dtype" --arg revision "$revision" --arg context "$context" --arg max_seqs "$max_seqs" --arg utilization "$gpu_utilization" \
  '{model:$model,dtype:$dtype,additional_args:["--revision",$revision,"--tensor-parallel-size","1","--max-num-seqs",$max_seqs,"--gpu-memory-utilization",$utilization,"--max-model-len",$context]}')"
curl -fsS -X POST "http://127.0.0.1:${port}/api/v1/inference/up/async" \
  -H 'Content-Type: application/json' --data-binary "$request" >/dev/null || true

while (( SECONDS < deadline )); do
  if docker exec "$container" curl -fsS http://127.0.0.1:5000/v1/models >/dev/null 2>&1; then break; fi
  sleep 10
done
docker exec "$container" curl -fsS http://127.0.0.1:5000/v1/models | jq -e --arg model "$model" '.data[] | select(.id == $model)' >/dev/null
completion="$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply exactly GDC_OK"}],max_tokens:16,temperature:0}')"
printf '%s' "$completion" | docker exec -i "$container" curl -fsS http://127.0.0.1:5000/v1/chat/completions \
  -H 'Content-Type: application/json' --data-binary @- | jq -e '.choices[0].message.content | type == "string"' >/dev/null
printf 'PASS AMD MLNode trial completed container=%s api=http://127.0.0.1:%s\n' "$container" "$port"
