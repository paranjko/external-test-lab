#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
if [[ "$url" == *'/chain-rpc/status' ]]; then
  printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"50"}}}'
  exit 0
fi
if [[ "$url" == *'/preserved_nodes_snapshot' ]]; then
  calls_file="${FAKE_SNAPSHOT_CALLS:?}"
  calls="$(cat "$calls_file")"
  printf '%s' "$((calls + 1))" >"$calls_file"
  if (( calls == 0 )); then
    printf '%s\n' '{"found":false}'
  else
    printf '%s\n' '{"found":true,"snapshot":{"episode_anchor_height":"50","model_preserved_nodes":[{"model_id":"Qwen/Qwen3-0.6B","participants":[{"node_ids":["node-a"]}]}]}}'
  fi
  exit 0
fi
exit 1
EOF
chmod +x "$WORK/bin/curl"
printf 0 >"$WORK/calls"
PATH="$WORK/bin:$PATH" FAKE_SNAPSHOT_CALLS="$WORK/calls" "$ROOT/scripts/capture-poc-snapshot.sh" https://chain.example.test 50 5 5 "$WORK/snapshot.json"
jq -e '.found == true and .snapshot.episode_anchor_height == "50" and .capture.captured_height == 50' "$WORK/snapshot.json" >/dev/null
[[ "$(cat "$WORK/calls")" == 2 ]]
printf 'PASS PoC snapshot capture retries publication at the exact anchor\n'
