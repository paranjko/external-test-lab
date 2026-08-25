#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --inventory FILE --node-name SSH_ALIAS --output FILE" >&2
}

INVENTORY=''
NODE=''
OUTPUT=''

while (($#)); do
  case "$1" in
    --inventory)
      INVENTORY="$2"
      shift 2
      ;;
    --node-name)
      NODE="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ "$NODE" =~ ^[A-Za-z0-9._-]+$ && -n "$OUTPUT" ]] || {
  usage
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
source "$ROOT/scripts/profile.sh"
load_profiles
topology_contains_node "$NODE" || { echo "node is not configured in inventory: $NODE" >&2; exit 2; }

prometheus_url='http://127.0.0.1:9099'
if [[ "$NODE" != "$GATEWAY_NODE" ]]; then
  prometheus_url="https://$(node_public_host "$GATEWAY_NODE")/ops-prometheus"
fi

values=(
  "PUBLIC_HOST=$(node_public_host "$NODE")"
  "ACME_EMAIL=${ACME_EMAIL:-}"
  "CADDY_IMAGE=$CADDY_IMAGE"
  "MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE"
  "GRAFANA_IMAGE=$GRAFANA_IMAGE"
  "PYTHON_IMAGE=${PYTHON_IMAGE:-python:3.13-alpine}"
  "GATEWAY_PUBLIC_HOST=$(node_public_host "$GATEWAY_NODE")"
  "GDC_GATEWAY_ADMISSION_UPSTREAM=http://$(node_public_host "$GATEWAY_NODE"):18080"
  # The public edge must not assume that gateway-internal listeners are
  # reachable over the gateway Host's public address. Use the TLS routes the
  # runbook already treats as the canonical chain/readiness boundary.
  "GDC_GATEWAY_ADMISSION_STATUS_URL=https://${API_HOST}/v1/status"
  "GDC_GATEWAY_ADMISSION_EPOCH_URL=https://${PUBLIC_EDGE_HOST}/chain-api/productscience/inference/inference/current_epoch_group_data"
  "GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL=https://${PUBLIC_EDGE_HOST}/chain-rpc/status"
  "GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL=https://${PUBLIC_EDGE_HOST}/chain-api/productscience/inference/inference/params"
  "GDC_GATEWAY_ADMISSION_SAFE_GUARD_BLOCKS=${GDC_GATEWAY_ADMISSION_SAFE_GUARD_BLOCKS:-10}"
  "GDC_GATEWAY_ADMISSION_MAX_QUEUE=${GDC_GATEWAY_ADMISSION_MAX_QUEUE:-16}"
  "GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS=${GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS:-240}"
  "GDC_GATEWAY_ADMISSION_POLL_SECONDS=${GDC_GATEWAY_ADMISSION_POLL_SECONDS:-0.25}"
  "GDC_GATEWAY_ADMISSION_MAX_BODY_BYTES=${GDC_GATEWAY_ADMISSION_MAX_BODY_BYTES:-1048576}"
  "GDC_GATEWAY_ADMISSION_MAX_DISPATCHES_PER_BLOCK=${GDC_GATEWAY_ADMISSION_MAX_DISPATCHES_PER_BLOCK:-1}"
  "GDC_GATEWAY_ADMISSION_AUDIT_FILE=/edge/status/gateway-admission.jsonl"
  "TELEGRAM_BOT_PUBLIC_HOST=$(node_public_host "$TELEGRAM_BOT_HOST")"
  "PUBLIC_GRAFANA_PROMETHEUS_URL=$prometheus_url"
  "MONITORING_CIDR=$MONITORING_CIDR"
  "PUBLIC_EDGE_CIDR=$PUBLIC_EDGE_CIDR"
)

# The three public DevNet origins deliberately terminate only on the configured
# public edge. Keeping this
# selection in the rendered env prevents every participant edge proxy from
# attempting to obtain the same ACME certificates.
if [[ "$NODE" == "$PUBLIC_EDGE_NODE" ]]; then
  values+=(
    "PUBLIC_EDGE=true"
    "SITE_HOST=$SITE_HOST"
    "API_HOST=$API_HOST"
    "GRAFANA_HOST=$GRAFANA_HOST"
  )
else
  values+=("PUBLIC_EDGE=false" "PUBLIC_EDGE_HOST=$PUBLIC_EDGE_HOST")
fi

write_env "$OUTPUT" "${values[@]}"
