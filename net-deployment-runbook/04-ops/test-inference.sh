#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 https://api.example KEY" >&2; exit 2; }
deadline_ms="$(( $(date +%s%3N) + 90000 ))"
BODY="$(curl --connect-timeout 10 --max-time 90 -fsS "${1%/}/v1/chat/completions" \
  -H "Authorization: Bearer $2" -H "X-Request-Deadline-Ms: $deadline_ms" -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Reply with exactly: GDC_OK"}],"temperature":0}' \
)"
jq -e '.choices[0].message.content | type=="string"' <<<"$BODY" >/dev/null
jq . <<<"$BODY"
