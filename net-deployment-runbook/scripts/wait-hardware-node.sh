#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

NODE="${1:-}"
topology_contains_node "$NODE" || die "unknown SSH alias: $NODE"

ACCOUNT="$ACCOUNTS/$NODE-cold.json"
[[ -s "$ACCOUNT" ]] || die "missing public account artifact for $NODE"
ADDRESS="$(jq -er .address "$ACCOUNT")"
TIMEOUT="${GDC_ML_HARDWARE_WAIT_SECONDS:-300}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'GDC_ML_HARDWARE_WAIT_SECONDS must be positive'
DEADLINE=$((SECONDS + TIMEOUT))
URL="https://${GENESIS_PUBLIC_HOST}/chain-api/productscience/inference/inference/hardware_nodes/${ADDRESS}"

while (( SECONDS < DEADLINE )); do
  NODES="$(curl -fsS --connect-timeout 5 --max-time 15 "$URL" 2>/dev/null || true)"
  if jq -e --arg model "$MODEL_ID" '
    .nodes.hardware_nodes
    | any(.status == "INFERENCE" and (.models | index($model) != null))
  ' <<<"$NODES" >/dev/null 2>&1; then
    printf '%s\n' "$NODES"
    printf 'READY %s has a chain-recorded INFERENCE hardware node for %s\n' "$NODE" "$MODEL_ID"
    exit 0
  fi
  printf 'WAIT  %s hardware node is not yet chain-recorded as INFERENCE for %s\n' "$NODE" "$MODEL_ID"
  sleep 5
done

die "$NODE hardware node did not become chain-recorded as INFERENCE within ${TIMEOUT}s"
