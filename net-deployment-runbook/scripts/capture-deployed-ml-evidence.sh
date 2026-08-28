#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -ge 3 ]] || {
  echo "Usage: $0 OUTPUT_DIR MODEL_ID SSH_ALIAS [SSH_ALIAS...]" >&2
  exit 2
}

OUTPUT_DIR="$1"
MODEL_ID="$2"
shift 2
hosts=("$@")
timeout_seconds="${GDC_DEPLOYED_ML_EVIDENCE_TIMEOUT_SECONDS:-1800}"
poll_seconds="${GDC_DEPLOYED_ML_EVIDENCE_POLL_SECONDS:-10}"

[[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != / ]] || {
  echo 'error: deployed ML evidence output directory is unsafe' >&2
  exit 2
}
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo 'error: GDC_DEPLOYED_ML_EVIDENCE_TIMEOUT_SECONDS must be a positive integer' >&2
  exit 2
}
[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo 'error: GDC_DEPLOYED_ML_EVIDENCE_POLL_SECONDS must be a positive integer' >&2
  exit 2
}

umask 077
mkdir -p "$OUTPUT_DIR"

declare -A seen=() containers=() stages=() reasons=()
for host in "${hosts[@]}"; do
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "error: invalid ML Host SSH alias: $host" >&2
    exit 2
  }
  [[ -z "${seen[$host]:-}" ]] || {
    echo "error: duplicate ML Host SSH alias: $host" >&2
    exit 2
  }
  seen[$host]=1
  stages[$host]=container
  reasons[$host]=not_checked
  mkdir -p "$OUTPUT_DIR/$host"
done

HTTP_STATUS=000
capture_http() {
  local host="$1" container="$2" method="$3" url="$4" body_file="$5" payload="${6:-}"
  local wire="$body_file.wire" status_line rc=0
  rm -f "$wire" "$body_file"
  if [[ "$method" == GET ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
      "docker exec '$container' curl -sS --max-time 20 -w '\nGDC_HTTP_STATUS=%{http_code}\n' '$url'" \
      >"$wire" || rc=$?
  else
    printf '%s' "$payload" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
      "docker exec -i '$container' curl -sS --max-time 60 -w '\nGDC_HTTP_STATUS=%{http_code}\n' '$url' -H 'Content-Type: application/json' --data-binary @-" \
      >"$wire" || rc=$?
  fi
  if (( rc != 0 )); then
    HTTP_STATUS=000
    rm -f "$wire"
    return "$rc"
  fi
  status_line="$(tail -n 1 "$wire")"
  [[ "$status_line" =~ ^GDC_HTTP_STATUS=([0-9]{3})$ ]] || {
    HTTP_STATUS=000
    rm -f "$wire"
    return 1
  }
  HTTP_STATUS="${BASH_REMATCH[1]}"
  sed '$d' "$wire" >"$body_file"
  rm -f "$wire"
}

completion_payload="$(jq -nc --arg model "$MODEL_ID" \
  '{model:$model,messages:[{role:"user",content:"Reply exactly GDC_OK"}],max_tokens:16,temperature:0}')"
deadline=$((SECONDS + timeout_seconds))
remaining=${#hosts[@]}

while (( remaining > 0 && SECONDS < deadline )); do
  for host in "${hosts[@]}"; do
    [[ -n "${stages[$host]:-}" ]] || continue
    report="$OUTPUT_DIR/$host"

    if [[ "${stages[$host]}" == container ]]; then
      mapfile -t matches < <(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
        "docker ps --filter 'label=com.docker.compose.project=$host' --filter 'label=com.docker.compose.service=mlnode' --format '{{.Names}}'" \
        2>/dev/null || true)
      if (( ${#matches[@]} != 1 )) || [[ ! "${matches[0]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        reasons[$host]="running_mlnode_containers_${#matches[@]}"
        printf 'WAIT  deployed ML evidence host=%s stage=container reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      containers[$host]="${matches[0]}"
      printf '%s\n' "${matches[0]}" >"$report/container.txt"
      stages[$host]=runtime
    fi

    if [[ "${stages[$host]}" == runtime ]]; then
      container="${containers[$host]}"
      if ! capture_http "$host" "$container" GET \
        http://127.0.0.1:8080/api/v1/inference/up/status "$report/status.json.tmp"; then
        reasons[$host]=runtime_status_transport
        printf 'WAIT  deployed ML evidence host=%s stage=runtime reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      if [[ "$HTTP_STATUS" != 200 ]]; then
        reasons[$host]="runtime_status_http_$HTTP_STATUS"
        printf 'WAIT  deployed ML evidence host=%s stage=runtime reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      if ! jq -e '.is_running == true and (.error == null or .error == "")' \
        "$report/status.json.tmp" >/dev/null 2>&1; then
        reasons[$host]=runtime_not_ready
        printf 'WAIT  deployed ML evidence host=%s stage=runtime reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      mv "$report/status.json.tmp" "$report/status.json"

      if ! capture_http "$host" "$container" GET \
        http://127.0.0.1:5000/v1/models "$report/models.json.tmp"; then
        reasons[$host]=models_transport
        printf 'WAIT  deployed ML evidence host=%s stage=models reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      if [[ "$HTTP_STATUS" != 200 ]]; then
        reasons[$host]="models_http_$HTTP_STATUS"
        printf 'WAIT  deployed ML evidence host=%s stage=models reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      if ! jq -e --arg model "$MODEL_ID" '.data[] | select(.id == $model)' \
        "$report/models.json.tmp" >/dev/null 2>&1; then
        reasons[$host]=model_missing
        printf 'WAIT  deployed ML evidence host=%s stage=models reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      mv "$report/models.json.tmp" "$report/models.json"

      if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
        'nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader' \
        >"$report/vram.csv.tmp"; then
        reasons[$host]=gpu_inventory_transport
        printf 'WAIT  deployed ML evidence host=%s stage=gpu reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      [[ -s "$report/vram.csv.tmp" ]] || {
        reasons[$host]=gpu_inventory_empty
        printf 'WAIT  deployed ML evidence host=%s stage=gpu reason=%s\n' "$host" "${reasons[$host]}"
        continue
      }
      mv "$report/vram.csv.tmp" "$report/vram.csv"
      stages[$host]=completion
      printf 'READY deployed ML runtime host=%s container=%s model=%s\n' "$host" "$container" "$MODEL_ID"
    fi

    if [[ "${stages[$host]}" == completion ]]; then
      container="${containers[$host]}"
      if ! capture_http "$host" "$container" POST \
        http://127.0.0.1:5000/v1/chat/completions "$report/completion.json.tmp" "$completion_payload"; then
        reasons[$host]=completion_transport
        printf 'WAIT  deployed ML completion host=%s reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      if [[ "$HTTP_STATUS" != 200 ]]; then
        reasons[$host]="completion_http_$HTTP_STATUS"
        mv "$report/completion.json.tmp" "$report/completion-last.json"
        printf 'WAIT  deployed ML completion host=%s reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      if ! jq -e '.choices[0].message.content | type == "string"' \
        "$report/completion.json.tmp" >/dev/null 2>&1; then
        reasons[$host]=completion_invalid_response
        mv "$report/completion.json.tmp" "$report/completion-last.json"
        printf 'WAIT  deployed ML completion host=%s reason=%s\n' "$host" "${reasons[$host]}"
        continue
      fi
      mv "$report/completion.json.tmp" "$report/completion.json"
      rm -f "$report/completion-last.json"
      unset 'stages[$host]'
      unset 'reasons[$host]'
      remaining=$((remaining - 1))
      printf 'PASS  deployed ML completion host=%s model=%s\n' "$host" "$MODEL_ID"
    fi
  done
  (( remaining == 0 )) && break
  sleep "$poll_seconds"
done

if (( remaining > 0 )); then
  for host in "${hosts[@]}"; do
    [[ -n "${stages[$host]:-}" ]] || continue
    printf 'FAILED deployed ML evidence host=%s stage=%s reason=%s\n' \
      "$host" "${stages[$host]}" "${reasons[$host]}" >&2
  done
  echo "error: deployed ML evidence did not complete within ${timeout_seconds}s" >&2
  exit 1
fi

printf 'PASS deployed ML evidence: %s\n' "$OUTPUT_DIR"
