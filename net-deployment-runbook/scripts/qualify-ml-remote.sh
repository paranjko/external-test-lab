#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 10 ]] || { echo "Usage: $0 work-dir env-file backend model dtype revision tensor-parallel max-seqs gpu-util context" >&2; exit 2; }
WORK="$1"; ENV_FILE="$2"; BACKEND="$3"; MODEL="$4"; DTYPE="$5"; REVISION="$6"; TENSOR="$7"; MAX_SEQS="$8"; GPU_UTIL="$9"; CONTEXT="${10}"
NODE_DIR="$WORK/02-node"
cd "$NODE_DIR"
case "$BACKEND" in
  cuda) COMPOSE_FILE=compose.ml-local.yaml ;;
  rocm)
    kfd_group="$(awk -F= '$1 == "AMD_KFD_GROUP_ID" {print $2; exit}' "$ENV_FILE")"
    render_group="$(awk -F= '$1 == "AMD_RENDER_GROUP_ID" {print $2; exit}' "$ENV_FILE")"
    if [[ -n "$kfd_group" && "$kfd_group" == "$render_group" ]]; then
      COMPOSE_FILE=compose.ml-amd-single-group.yaml
    else
      COMPOSE_FILE=compose.ml-amd.yaml
    fi
    ;;
  *) echo "unsupported ML qualification backend: $BACKEND" >&2; exit 2 ;;
esac
qualification_timeout="${ML_QUALIFICATION_TIMEOUT_SECONDS:-1800}"
probe_timeout="${ML_QUALIFICATION_PROBE_TIMEOUT_SECONDS:-30}"
poll_interval="${ML_QUALIFICATION_POLL_INTERVAL_SECONDS:-15}"
vllm_poll_interval="${ML_QUALIFICATION_VLLM_POLL_INTERVAL_SECONDS:-10}"
[[ "$qualification_timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'ML_QUALIFICATION_TIMEOUT_SECONDS must be a positive integer' >&2; exit 2; }
[[ "$probe_timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'ML_QUALIFICATION_PROBE_TIMEOUT_SECONDS must be a positive integer' >&2; exit 2; }
[[ "$poll_interval" =~ ^[1-9][0-9]*$ ]] || { echo 'ML_QUALIFICATION_POLL_INTERVAL_SECONDS must be a positive integer' >&2; exit 2; }
[[ "$vllm_poll_interval" =~ ^[1-9][0-9]*$ ]] || { echo 'ML_QUALIFICATION_VLLM_POLL_INTERVAL_SECONDS must be a positive integer' >&2; exit 2; }
cleanup() {
  timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --no-color >"$WORK/runtime.log" 2>&1 || true
  timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down >"$WORK/stop.log" 2>&1 || true
}
trap cleanup EXIT
timeout "$qualification_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d >"$WORK/start.log" 2>&1
deadline=$((SECONDS + qualification_timeout))
body="$(jq -nc --arg model "$MODEL" --arg dtype "$DTYPE" --arg revision "$REVISION" --arg tensor "$TENSOR" --arg max "$MAX_SEQS" --arg util "$GPU_UTIL" --arg context "$CONTEXT" '{model:$model,dtype:$dtype,additional_args:["--revision",$revision,"--tensor-parallel-size",$tensor,"--max-num-seqs",$max,"--gpu-memory-utilization",$util,"--max-model-len",$context]}')"
# The nginx inference proxy is intentionally for OpenAI traffic. Control-plane
# calls go directly to the MLNode container so the /api/v1 prefix is preserved.
ensure_inference_started() {
  local status_tmp="$WORK/status.json.tmp"
  if ! timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mlnode \
    curl -fsS http://127.0.0.1:8080/api/v1/inference/up/status >"$status_tmp" 2>>"$WORK/control.log"; then
    rm -f "$status_tmp"
    return 0
  fi
  mv "$status_tmp" "$WORK/status.json"
  if jq -e '.status == "not_started"' "$WORK/status.json" >/dev/null 2>&1; then
    printf '%s' "$body" | timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mlnode \
      curl -fsS -X POST http://127.0.0.1:8080/api/v1/inference/up/async -H 'Content-Type: application/json' \
      --data-binary @- >"$WORK/startup.json" 2>>"$WORK/control.log" || true
  fi
}
fail_on_terminal_status() {
  [[ -s "$WORK/status.json" ]] || return 0
  if jq -e '.error != null and .error != ""' "$WORK/status.json" >/dev/null 2>&1; then
    printf 'FAILED MLNode reported terminal startup error: ' >&2
    jq -r '.error' "$WORK/status.json" >&2
    return 1
  fi
}
fail_on_terminal_runtime() {
  local runtime_tmp="$WORK/startup-runtime.log.tmp"
  if ! timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" \
    logs --no-color mlnode >"$runtime_tmp" 2>>"$WORK/control.log"; then
    rm -f "$runtime_tmp"
    return 0
  fi
  mv "$runtime_tmp" "$WORK/startup-runtime.log"
  # This vLLM lifecycle marker is emitted only after the EngineCore process
  # has terminated during the current, freshly created qualification stack.
  # Do not treat generic ERROR/Traceback lines as terminal: optional plugin
  # import failures can be logged while model startup continues normally.
  if grep -Fq 'EngineCore failed to start.' "$WORK/startup-runtime.log"; then
    printf 'FAILED MLNode runtime reported terminal EngineCore startup failure\n' >&2
    return 1
  fi
}
while (( SECONDS < deadline )); do
  ensure_inference_started
  fail_on_terminal_status || exit 1
  fail_on_terminal_runtime || exit 1
  jq -e '.is_running == true and (.error == null or .error == "")' "$WORK/status.json" >/dev/null 2>&1 && break
  printf 'WAIT  ML qualification elapsed=%ss\n' "$((qualification_timeout - deadline + SECONDS))"
  sleep "$poll_interval"
done
if ! jq -e '.is_running == true and (.error == null or .error == "")' "$WORK/status.json" >/dev/null 2>&1; then
  printf 'FAILED MLNode control endpoint did not report a running model within %ss\n' "$qualification_timeout" >&2
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
  fail_on_terminal_status || exit 1
  if timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mlnode \
    curl -fsS http://127.0.0.1:5000/v1/models >"$WORK/models.json" 2>>"$WORK/vllm.log" && \
    jq -e --arg model "$MODEL" '.data[] | select(.id == $model)' "$WORK/models.json" >/dev/null; then
    break
  fi
  printf 'WAIT  VLLM model endpoint elapsed=%ss\n' "$((qualification_timeout - deadline + SECONDS))"
  sleep "$vllm_poll_interval"
done
jq -e --arg model "$MODEL" '.data[] | select(.id == $model)' "$WORK/models.json" >/dev/null
chat="$(jq -nc --arg model "$MODEL" '{model:$model,messages:[{role:"user",content:"Reply exactly GDC_OK"}],max_tokens:16,temperature:0}')"
while (( SECONDS < deadline )); do
  if printf '%s' "$chat" | timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mlnode \
    curl -fsS http://127.0.0.1:5000/v1/chat/completions -H 'Content-Type: application/json' --data-binary @- \
    >"$WORK/completion.json" 2>>"$WORK/vllm.log" && \
    jq -e '.choices[0].message.content | type == "string"' "$WORK/completion.json" >/dev/null; then
    break
  fi
  printf 'WAIT  VLLM completion elapsed=%ss\n' "$((qualification_timeout - deadline + SECONDS))"
  sleep "$vllm_poll_interval"
done
jq -e '.choices[0].message.content | type == "string"' "$WORK/completion.json" >/dev/null
if [[ "$BACKEND" == cuda ]]; then
  timeout "$probe_timeout" nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader >"$WORK/vram.csv"
else
  timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mlnode \
    rocminfo >"$WORK/rocm-info.txt"
  timeout "$probe_timeout" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mlnode \
    python3 -c 'import torch; assert torch.version.hip; assert torch.cuda.is_available(); x=torch.ones(1024, device="cuda"); result=x.sum().item(); assert result == 1024; print(f"hip={torch.version.hip} device={torch.cuda.get_device_name(0)} sum={result}")' \
    >"$WORK/rocm-workload.txt"
fi
