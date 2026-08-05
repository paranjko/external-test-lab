#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 9 ]] || { echo "Usage: $0 work-dir env-file model dtype revision tensor-parallel max-seqs gpu-util context" >&2; exit 2; }
WORK="$1"; ENV_FILE="$2"; MODEL="$3"; DTYPE="$4"; REVISION="$5"; TENSOR="$6"; MAX_SEQS="$7"; GPU_UTIL="$8"; CONTEXT="$9"
NODE_DIR="$WORK/02-node"
cd "$NODE_DIR"
docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml up -d >"$WORK/start.log" 2>&1
cleanup() {
  docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml logs --no-color >"$WORK/runtime.log" 2>&1 || true
  docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml down >"$WORK/stop.log" 2>&1 || true
}
trap cleanup EXIT
deadline=$((SECONDS + 1800))
body="$(jq -nc --arg model "$MODEL" --arg dtype "$DTYPE" --arg revision "$REVISION" --arg tensor "$TENSOR" --arg max "$MAX_SEQS" --arg util "$GPU_UTIL" --arg context "$CONTEXT" '{model:$model,dtype:$dtype,additional_args:["--revision",$revision,"--tensor-parallel-size",$tensor,"--max-num-seqs",$max,"--gpu-memory-utilization",$util,"--max-model-len",$context]}')"
# The nginx inference proxy is intentionally for OpenAI traffic. Control-plane
# calls go directly to the MLNode container so the /api/v1 prefix is preserved.
ensure_inference_started() {
  docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml exec -T mlnode \
    curl -fsS http://127.0.0.1:8080/api/v1/inference/up/status >"$WORK/status.json" || return 0
  if jq -e '.status == "not_started"' "$WORK/status.json" >/dev/null 2>&1; then
    printf '%s' "$body" | docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml exec -T mlnode \
      curl -fsS -X POST http://127.0.0.1:8080/api/v1/inference/up/async -H 'Content-Type: application/json' \
      --data-binary @- >"$WORK/startup.json" 2>>"$WORK/control.log" || true
  fi
}
while (( SECONDS < deadline )); do
  ensure_inference_started
  jq -e '.is_running == true and (.error == null or .error == "")' "$WORK/status.json" >/dev/null 2>&1 && break
  printf 'WAIT  ML qualification elapsed=%ss\n' "$((1800 - deadline + SECONDS))"
  sleep 15
done
jq -e '.is_running == true and (.error == null or .error == "")' "$WORK/status.json" >/dev/null
# Query VLLM directly inside MLNode. The host's port 5050 proxy is an
# integration surface, but its upstream can briefly lag MLNode's ready state.
# `is_running` also becomes true shortly before VLLM opens its listener, so
# wait for the model endpoint itself instead of treating control-plane state as
# sufficient evidence.
while (( SECONDS < deadline )); do
  ensure_inference_started
  if docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml exec -T mlnode \
    curl -fsS http://127.0.0.1:5000/v1/models >"$WORK/models.json" 2>>"$WORK/vllm.log" && \
    jq -e --arg model "$MODEL" '.data[] | select(.id == $model)' "$WORK/models.json" >/dev/null; then
    break
  fi
  printf 'WAIT  VLLM model endpoint elapsed=%ss\n' "$((1800 - deadline + SECONDS))"
  sleep 10
done
jq -e --arg model "$MODEL" '.data[] | select(.id == $model)' "$WORK/models.json" >/dev/null
chat="$(jq -nc --arg model "$MODEL" '{model:$model,messages:[{role:"user",content:"Reply exactly GDC_OK"}],max_tokens:16,temperature:0}')"
while (( SECONDS < deadline )); do
  if printf '%s' "$chat" | docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml exec -T mlnode \
    curl -fsS http://127.0.0.1:5000/v1/chat/completions -H 'Content-Type: application/json' --data-binary @- \
    >"$WORK/completion.json" 2>>"$WORK/vllm.log" && \
    jq -e '.choices[0].message.content | type == "string"' "$WORK/completion.json" >/dev/null; then
    break
  fi
  printf 'WAIT  VLLM completion elapsed=%ss\n' "$((1800 - deadline + SECONDS))"
  sleep 10
done
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader >"$WORK/vram.csv"
jq -e '.choices[0].message.content | type == "string"' "$WORK/completion.json" >/dev/null
