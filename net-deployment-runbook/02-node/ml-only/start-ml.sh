#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A second invocation can otherwise race the first one while it pulls images
# or starts vLLM, yielding misleading readiness output from two operators.
# This is a host-local lifecycle operation, so only one execution is valid.
LOCK_FILE=/var/lock/gdc-node4-ml-start.lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "FAILED ML start is already running on this host" >&2
  exit 1
fi
ENV_FILE="${1:-$HERE/.env}"
shift || true
MODEL="${1:-}"
DTYPE="${2:-}"
REVISION="${3:-}"
TENSOR_PARALLEL="${4:-}"
MAX_SEQS="${5:-}"
GPU_UTILIZATION="${6:-}"
CONTEXT_LENGTH="${7:-}"
if [[ -n "$MODEL" ]]; then
  [[ -n "$DTYPE" && -n "$REVISION" && -n "$TENSOR_PARALLEL" && -n "$MAX_SEQS" && -n "$GPU_UTILIZATION" && -n "$CONTEXT_LENGTH" ]] || {
    echo 'Usage: start-ml.sh [env-file [model dtype revision tensor-parallel max-seqs gpu-utilization context-length]]' >&2
    exit 2
  }
fi
run_long() {
  local label="$1" log="$2" pid elapsed=0
  shift 2
  printf 'WAIT  %s elapsed=0s\n' "$label"
  "$@" >"$log" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    kill -0 "$pid" 2>/dev/null || break
    elapsed=$((elapsed + 30))
    printf 'WAIT  %s elapsed=%ss\n' "$label" "$elapsed"
  done
  if ! wait "$pid"; then tail -100 "$log" >&2; return 1; fi
}
docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" config --quiet
run_long 'pull ML images' "$HERE/start.log" docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" pull
printf 'WAIT  start ML services\n'
if ! docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" up -d >>"$HERE/start.log" 2>&1; then
  tail -100 "$HERE/start.log" >&2
  exit 1
fi
printf 'WAIT  ML readiness elapsed=0s\n'
deadline=$((SECONDS + 1800))
while (( SECONDS < deadline )); do
  if curl --connect-timeout 3 --max-time 10 -fsS http://127.0.0.1:8080/api/v1/inference/up/status >/dev/null 2>&1; then
    break
  fi
  sleep 15
  printf 'WAIT  ML readiness elapsed=%ss\n' "$((1800 - deadline + SECONDS))"
done
if (( SECONDS >= deadline )); then
  printf 'FAILED ML services did not become ready within 1800s\n' >&2
  docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" logs --tail 100 >&2
  exit 1
fi

[[ -n "$MODEL" ]] || { printf 'READY ML services started\n'; exit 0; }

request="$(jq -nc --arg model "$MODEL" --arg dtype "$DTYPE" --arg revision "$REVISION" \
  --arg tensor "$TENSOR_PARALLEL" --arg max "$MAX_SEQS" --arg util "$GPU_UTILIZATION" --arg context "$CONTEXT_LENGTH" \
  '{model:$model,dtype:$dtype,additional_args:["--revision",$revision,"--tensor-parallel-size",$tensor,"--max-num-seqs",$max,"--gpu-memory-utilization",$util,"--max-model-len",$context]}')"
while (( SECONDS < deadline )); do
  status="$(docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" exec -T mlnode \
    curl -fsS http://127.0.0.1:8080/api/v1/inference/up/status || true)"
  if jq -e '.is_running == true and (.error == null or .error == "")' <<<"$status" >/dev/null 2>&1; then
    break
  fi
  if jq -e '.status == "not_started"' <<<"$status" >/dev/null 2>&1; then
    printf '%s' "$request" | docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" exec -T mlnode \
      curl -fsS -X POST http://127.0.0.1:8080/api/v1/inference/up/async -H 'Content-Type: application/json' --data-binary @- >/dev/null || true
  fi
  sleep 15
  printf 'WAIT  ML inference startup elapsed=%ss\n' "$((1800 - deadline + SECONDS))"
done
jq -e '.is_running == true and (.error == null or .error == "")' <<<"$status" >/dev/null || {
  printf 'FAILED ML inference did not start\n' >&2
  docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" logs --tail 100 >&2
  exit 1
}

while (( SECONDS < deadline )); do
  if docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" exec -T mlnode \
    curl -fsS http://127.0.0.1:5000/v1/models | jq -e --arg model "$MODEL" '.data[] | select(.id == $model)' >/dev/null; then
    printf 'READY ML inference serves %s\n' "$MODEL"
    exit 0
  fi
  sleep 10
  printf 'WAIT  ML model endpoint elapsed=%ss\n' "$((1800 - deadline + SECONDS))"
done
printf 'FAILED ML model endpoint did not serve %s\n' "$MODEL" >&2
docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml" logs --tail 100 >&2
exit 1
