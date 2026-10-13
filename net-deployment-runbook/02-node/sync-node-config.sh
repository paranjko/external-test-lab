#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/node-config.json"
[[ -s "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 1; }

mapfile -t nodes < <(jq -ce 'if type == "array" and length > 0 then .[] else error("expected one or more ML nodes") end' "$CONFIG")
deadline=$((SECONDS + 90))

while (( SECONDS < deadline )); do
  synchronized=true
  for node in "${nodes[@]}"; do
    node_id="$(jq -er '.id' <<<"$node")"
    node_host="$(jq -er '.host' <<<"$node")"
    response="$(curl -sS --max-time 10 -w $'\n%{http_code}' -X POST \
      -H 'Content-Type: application/json' \
      --data "$node" 'http://127.0.0.1:9200/admin/v1/nodes' 2>/dev/null || true)"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [[ "$status" != 200 ]] || ! jq -e --arg id "$node_id" --arg host "$node_host" \
      '.id == $id and .host == $host' <<<"$body" >/dev/null; then
      synchronized=false
      break
    fi
  done
  if [[ "$synchronized" == true ]]; then
    printf 'READY node configuration synchronized: %s ML node(s)\n' "${#nodes[@]}"
    exit 0
  fi
  sleep 3
done

echo "Failed to synchronize ML node configuration for $node_id" >&2
exit 1
