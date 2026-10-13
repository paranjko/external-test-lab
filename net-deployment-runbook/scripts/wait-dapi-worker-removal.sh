#!/usr/bin/env bash
# Confirm that DAPI has removed a worker after DELETE. The pinned DAPI waits
# for queued worker commands without a server-side deadline, so a bounded
# client timeout is not enough to decide that a lent GPU can be reclaimed.
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --node-id ID [--timeout-seconds SECONDS] [--poll-seconds SECONDS]" >&2
}

node_id=''
# The pinned DAPI client bounds one ML-node command at 15 minutes.  Allow a
# small finalization margin, rather than refusing a legitimate drain at 120s.
timeout_seconds=960
poll_seconds=15
while (($#)); do
  case "$1" in
    --node-id) node_id="${2:-}"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:-}"; shift 2 ;;
    --poll-seconds) poll_seconds="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] \
  && [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
  && [[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] \
  || { usage; exit 2; }

started_at="$(date +%s)"
if ! curl -fsS --connect-timeout 5 --max-time 15 -X DELETE \
  "http://127.0.0.1:9200/admin/v1/nodes/$node_id" >/dev/null; then
  printf 'WAIT DAPI did not confirm worker removal node_id=%s; waiting for broker readback\n' "$node_id"
fi

while true; do
  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || { echo 'DAPI worker removal clock is invalid' >&2; exit 1; }
  elapsed=$((now - started_at))
  if nodes="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes)"; then
    if jq -e --arg id "$node_id" 'type == "array" and all(.[]; .node.id != $id)' <<<"$nodes" >/dev/null; then
      printf 'PASS DAPI confirmed worker removal node_id=%s elapsed=%ss\n' "$node_id" "$elapsed"
      exit 0
    fi
    last='worker is still registered'
  else
    last='DAPI node readback is unavailable'
  fi

  if (( elapsed >= timeout_seconds )); then
    printf 'DAPI did not confirm worker removal node_id=%s within %ss (%s)\n' \
      "$node_id" "$timeout_seconds" "$last" >&2
    exit 195
  fi
  printf 'WAIT DAPI worker removal node_id=%s elapsed=%ss remaining=%ss last=%s\n' \
    "$node_id" "$elapsed" "$((timeout_seconds - elapsed))" "$last"
  sleep "$poll_seconds"
done
