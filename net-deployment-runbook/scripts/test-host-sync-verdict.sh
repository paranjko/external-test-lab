#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/host-sync-verdict.sh"

host_sync_accepts 100 101 101 995 1000 false 90

if host_sync_accepts 100 100 100 995 1000 false 90; then
  echo 'stopped near-tip Host satisfied synchronized acceptance' >&2
  exit 1
fi
if host_sync_accepts 100 101 101 900 1000 false 90; then
  echo 'stale latest block time satisfied synchronized acceptance' >&2
  exit 1
fi
if host_sync_accepts 100 101 101 995 1000 true 90; then
  echo 'catching-up Host satisfied synchronized acceptance' >&2
  exit 1
fi
record="$(host_sync_record node4 100 100 100 995 1000 false)"
jq -e '.host == "node4" and .lag == 0 and .block_age_seconds == 5 and .progressing == false' <<<"$record" >/dev/null
printf 'PASS Host synchronization rejects stopped near-tip and stale states\n'
