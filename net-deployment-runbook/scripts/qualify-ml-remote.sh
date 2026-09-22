#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 11 ]] || { echo "Usage: $0 work-dir env-file source-model served-model dtype revision tensor-parallel max-seqs gpu-util context vllm-args" >&2; exit 2; }
WORK="$1"; ENV_FILE="$2"; SOURCE_MODEL="$3"; MODEL="$4"; DTYPE="$5"; REVISION="$6"; TENSOR="$7"; MAX_SEQS="$8"; GPU_UTIL="$9"; CONTEXT="${10}"; VLLM_ARGS="${11}"
NODE_DIR="$WORK/02-node"
cd "$NODE_DIR"
docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml up -d >"$WORK/start.log" 2>&1
cleanup() {
  docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml logs --no-color >"$WORK/runtime.log" 2>&1 || true
  docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml down >"$WORK/stop.log" 2>&1 || true
}
trap cleanup EXIT
deadline=$((SECONDS + 1800))
case "$VLLM_ARGS" in ''|--enforce-eager) ;; *) echo 'unsupported MLNode vLLM arguments' >&2; exit 2 ;; esac
body="$(jq -nc --arg source "$SOURCE_MODEL" --arg served "$MODEL" --arg dtype "$DTYPE" --arg revision "$REVISION" --arg tensor "$TENSOR" --arg max "$MAX_SEQS" --arg util "$GPU_UTIL" --arg context "$CONTEXT" --arg eager "$VLLM_ARGS" '{model:$source,dtype:$dtype,additional_args:(["--revision",$revision,"--tensor-parallel-size",$tensor,"--max-num-seqs",$max,"--gpu-memory-utilization",$util,"--max-model-len",$context,"--served-model-name",$served] + (if $eager == "" then [] else [$eager] end))}')"
# The nginx inference proxy is intentionally for OpenAI traffic. Control-plane
# calls go directly to the MLNode container so the /api/v1 prefix is preserved.
ensure_inference_started() {
  local status_tmp="$WORK/status.json.tmp"
  if ! docker compose --env-file "$ENV_FILE" -f compose.ml-local.yaml exec -T mlnode \
    curl -fsS http://127.0.0.1:8080/api/v1/inference/up/status >"$status_tmp" 2>>"$WORK/control.log"; then
    rm -f "$status_tmp"
    return 0
  fi
  mv "$status_tmp" "$WORK/status.json"
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
if ! jq -e '.is_running == true and (.error == null or .error == "")' "$WORK/status.json" >/dev/null 2>&1; then
  printf 'FAILED MLNode control endpoint did not report a running model within 1800s\n' >&2
  tail -100 "$WORK/control.log" >&2 2>/dev/null || true
  exit 1
fi
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
