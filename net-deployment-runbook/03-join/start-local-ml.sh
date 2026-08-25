#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 8 ]] || {
  echo "Usage: $0 NODE MODEL REVISION DTYPE TENSOR MAX_SEQS GPU_UTILIZATION CONTEXT_LENGTH" >&2
  exit 2
}
NODE="$1"; MODEL="$2"; REVISION="$3"; DTYPE="$4"; TENSOR="$5"
MAX_SEQS="$6"; GPU_UTILIZATION="$7"; CONTEXT_LENGTH="$8"

ssh -T "$NODE" \
  "NODE='$NODE' MODEL='$MODEL' REVISION='$REVISION' DTYPE='$DTYPE' TENSOR='$TENSOR' MAX_SEQS='$MAX_SEQS' GPU_UTILIZATION='$GPU_UTILIZATION' CONTEXT_LENGTH='$CONTEXT_LENGTH' bash -s" <<'REMOTE'
set -Eeuo pipefail
cd "/srv/dai/deploy/$NODE"
compose=(sudo docker compose --env-file .env -f compose.yaml -f compose.ml-local.yaml)
request="$(jq -nc \
  --arg model "$MODEL" --arg dtype "$DTYPE" --arg revision "$REVISION" \
  --arg tensor "$TENSOR" --arg max "$MAX_SEQS" --arg util "$GPU_UTILIZATION" --arg context "$CONTEXT_LENGTH" \
  '{model:$model,dtype:$dtype,additional_args:["--revision",$revision,"--tensor-parallel-size",$tensor,"--max-num-seqs",$max,"--gpu-memory-utilization",$util,"--max-model-len",$context]}')"
deadline=$((SECONDS + 1800))
while (( SECONDS < deadline )); do
  status="$("${compose[@]}" exec -T mlnode curl -fsS http://127.0.0.1:8080/api/v1/inference/up/status 2>/dev/null || true)"
  if jq -e '.is_running == true and (.error == null or .error == "")' <<<"$status" >/dev/null 2>&1; then
    break
  fi
  if jq -e '.status == "not_started"' <<<"$status" >/dev/null 2>&1; then
    if ! printf '%s' "$request" | "${compose[@]}" exec -T mlnode \
      curl -fsS -X POST http://127.0.0.1:8080/api/v1/inference/up/async \
      -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>/dev/null; then
      printf 'WAIT local ML start request node=%s control_endpoint=http://127.0.0.1:8080/api/v1/inference/up/async result=unavailable; retrying\n' "$NODE"
    fi
  fi
  printf 'WAIT local ML inference startup node=%s control_endpoint=http://127.0.0.1:8080/api/v1/inference/up/status elapsed=%ss\n' "$NODE" "$((1800 - deadline + SECONDS))"
  sleep 15
done
if ! jq -e '.is_running == true and (.error == null or .error == "")' <<<"$status" >/dev/null 2>&1; then
  echo "FAILED local ML inference did not start on $NODE within 1800s" >&2
  exit 1
fi

# The control-plane flag can become true before the vLLM backend has opened
# its listener. Require the configured model endpoint and one real local
# completion before PoC registration is allowed to start.
while (( SECONDS < deadline )); do
  if "${compose[@]}" exec -T mlnode curl -fsS http://127.0.0.1:5000/v1/models 2>/dev/null \
    | jq -e --arg model "$MODEL" '.data[] | select(.id == $model)' >/dev/null 2>&1; then
    completion_request="$(jq -nc --arg model "$MODEL" \
      '{model:$model,messages:[{role:"user",content:"Reply exactly GDC_OK"}],max_tokens:16,temperature:0}')"
    if printf '%s' "$completion_request" | "${compose[@]}" exec -T mlnode \
      curl -fsS http://127.0.0.1:5000/v1/chat/completions 2>/dev/null \
      -H 'Content-Type: application/json' --data-binary @- \
      | jq -e '.choices[0].message.content | type == "string"' >/dev/null 2>&1; then
      printf 'READY local ML inference serves %s on %s\n' "$MODEL" "$NODE"
      exit 0
    fi
  fi
  printf 'WAIT local ML model endpoint node=%s model_endpoint=http://127.0.0.1:5000/v1/models completion_endpoint=http://127.0.0.1:5000/v1/chat/completions elapsed=%ss\n' "$NODE" "$((1800 - deadline + SECONDS))"
  sleep 10
done
echo "FAILED local ML model endpoint did not serve $MODEL on $NODE within 1800s" >&2
exit 1
REMOTE
