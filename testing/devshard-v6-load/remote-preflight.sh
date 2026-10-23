#!/usr/bin/env bash
# Read-only snapshot of a gateway node before and after a remote load run: idle check, versions, escrow budget.
# Usage: remote-preflight.sh <gateway ssh host> [container name pattern] > preflight.txt
set -euo pipefail

host=${1:?ssh host of the gateway node, e.g. gdc-node0}
pattern=${2:-park-gateway}

timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "bash -s -- '$pattern'" <<'EOF'
set -uo pipefail
pattern=$1
rest=http://127.0.0.1:1317/productscience/inference/inference
echo "== $(hostname) $(date -u +%FT%TZ)"
echo "== chain"
curl -s -m 10 http://127.0.0.1:26657/abci_info | jq -c '.result.response | {version, last_block_height}'
curl -s -m 10 "$rest/current_epoch_group_data" | jq -c '.epoch_group_data | {epoch_index, poc_start_block_height}'
curl -s -m 10 "$rest/params" | jq '(.params // .).devshard_escrow_params | .approved_versions |= map({name, sha256, binary})'
echo "== containers"
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE "$pattern|versiond|devshard|router" | sort
for c in $(docker ps --format '{{.Names}}' | grep -E "$pattern" | sort); do
  echo "== $c"
  echo "log lines 10m: $(docker logs --since 10m "$c" 2>&1 | wc -l), completions 10m: $(docker logs --since 10m "$c" 2>&1 | grep -ciE 'chat/completions')"
  docker stats --no-stream --format 'cpu {{.CPUPerc}} mem {{.MemUsage}}' "$c"
  port=$(docker port "$c" | grep -m1 -oE '[0-9]+$' || true)
  [ -n "$port" ] || { echo "no published port"; continue; }
  status=$(curl -s -m 10 "localhost:$port/v1/status")
  jq -c '{phase, escrow_id, nonce, chain_phase, confirmation_poc_phase, models: (.capacity.models // {} | with_entries(.value |= "\(.routable)/\(.total_weight)"))}' <<<"$status" 2>/dev/null || echo "status: ${status:0:300}"
  for id in $(jq -r '[.escrow_id, (.devshards[]?.escrow_id)] | map(select(. != null)) | unique | .[]' <<<"$status" 2>/dev/null); do
    echo "-- escrow $id"
    curl -s -m 10 "$rest/devshard_escrow/$id" | jq -c '.escrow | del(.slots)'
  done
done
EOF
