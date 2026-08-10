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

values=(
  "PUBLIC_HOST=$(node_public_host "$NODE")"
  "ACME_EMAIL=${ACME_EMAIL:-}"
  "CADDY_IMAGE=$CADDY_IMAGE"
  "GRAFANA_IMAGE=$GRAFANA_IMAGE"
  "GATEWAY_PUBLIC_HOST=$(node_public_host "$GATEWAY_NODE")"
  "PUBLIC_GRAFANA_PROMETHEUS_URL=https://$(node_public_host "$GATEWAY_NODE")/ops-prometheus"
  "MONITORING_CIDR=$MONITORING_CIDR"
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
