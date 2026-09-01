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

# A one-host JOIN role intentionally has no local gateway, public-edge, or
# Telegram role. Its Bootstrap descriptor still binds PUBLIC_EDGE_HOST to a
# validated seed, which is the only safe auxiliary control-plane origin until
# the joining Host is admitted. Never call node_public_host with an empty role.
gateway_public_host="$PUBLIC_EDGE_HOST"
[[ -z "${GATEWAY_NODE:-}" ]] || gateway_public_host="$(node_public_host "$GATEWAY_NODE")"
telegram_bot_public_host="$PUBLIC_EDGE_HOST"
[[ -z "${TELEGRAM_BOT_HOST:-}" ]] || telegram_bot_public_host="$(node_public_host "$TELEGRAM_BOT_HOST")"

prometheus_url='http://127.0.0.1:9099'
if [[ "$NODE" != "${GATEWAY_NODE:-}" ]]; then
  prometheus_url="https://${gateway_public_host}/ops-prometheus"
fi

gateway_admission_protocols_json='{}'
gateway_protocol_contract="$(selected_gateway_protocol_contract)" || exit 2
read -r -a gateway_supported_protocols <<<"$gateway_protocol_contract"
(( ${#gateway_supported_protocols[@]} > 0 )) || {
  echo 'gateway admission requires at least one supported DevShard protocol' >&2
  exit 2
}
for protocol in "${gateway_supported_protocols[@]}"; do
  case "$protocol" in
    v3) protocol_url="$DEVSHARD_V3_URL"; protocol_sha256="$DEVSHARD_V3_SHA256" ;;
    v4) protocol_url="$DEVSHARD_V4_URL"; protocol_sha256="$DEVSHARD_V4_SHA256" ;;
    v5) protocol_url="${DEVSHARD_V5_URL:-}"; protocol_sha256="${DEVSHARD_V5_SHA256:-}" ;;
    *) echo "unsupported DevShard gateway protocol in profile: $protocol" >&2; exit 2 ;;
  esac
  [[ "$protocol_url" =~ ^https?:// && "$protocol_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "DevShard $protocol gateway admission contract is incomplete" >&2
    exit 2
  }
  if jq -e --arg protocol "$protocol" 'has($protocol)' <<<"$gateway_admission_protocols_json" >/dev/null; then
    echo "duplicate DevShard gateway protocol in profile: $protocol" >&2
    exit 2
  fi
  gateway_admission_protocols_json="$(jq -c \
    --arg protocol "$protocol" --arg url "$protocol_url" --arg sha256 "$protocol_sha256" \
    '. + {($protocol):{binary:$url,sha256:$sha256}}' <<<"$gateway_admission_protocols_json")"
done

gateway_admission_status_url="https://${gateway_public_host}/ops-gateway-admission-state"
if [[ -n "${GATEWAY_NODE:-}" && "$NODE" == "$GATEWAY_NODE" && "$NODE" == "${PUBLIC_EDGE_NODE:-}" ]]; then
  gateway_admission_status_url='http://127.0.0.1:18084/v1/status'
fi

values=(
  "PUBLIC_HOST=$(node_public_host "$NODE")"
  "ACME_EMAIL=${ACME_EMAIL:-}"
  "CADDY_IMAGE=$CADDY_IMAGE"
  "MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE"
  "GRAFANA_IMAGE=$GRAFANA_IMAGE"
  "PYTHON_IMAGE=${PYTHON_IMAGE:-python:3.13-alpine}"
  "GATEWAY_PUBLIC_HOST=$gateway_public_host"
  "GDC_GATEWAY_ADMISSION_UPSTREAM=http://${gateway_public_host}:18080"
  # The public one-runtime status omits protocol and capacity. Admission uses
  # the authenticated aggregate observer so it binds the actual live runtime
  # identity and positive capacity instead of deployment intent. The gateway
  # participant edge exposes this path over TLS only to PUBLIC_EDGE_CIDR. A
  # colocated public edge uses the same host-network loopback instead.
  "GDC_GATEWAY_ADMISSION_STATUS_URL=$gateway_admission_status_url"
  "GDC_GATEWAY_ADMISSION_EPOCH_URL=https://${PUBLIC_EDGE_HOST}/chain-api/productscience/inference/inference/current_epoch_group_data"
  "GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL=https://${PUBLIC_EDGE_HOST}/chain-rpc/status"
  "GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL=https://${PUBLIC_EDGE_HOST}/chain-api/productscience/inference/inference/params"
  "GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=$gateway_admission_protocols_json"
  "GDC_GATEWAY_ADMISSION_SAFE_GUARD_BLOCKS=${GDC_GATEWAY_ADMISSION_SAFE_GUARD_BLOCKS:-10}"
  "GDC_GATEWAY_ADMISSION_MAX_QUEUE=${GDC_GATEWAY_ADMISSION_MAX_QUEUE:-16}"
  "GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS=${GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS:-300}"
  "GDC_GATEWAY_ADMISSION_MAX_DEADLINE_SECONDS=${GDC_GATEWAY_ADMISSION_MAX_DEADLINE_SECONDS:-900}"
  "GDC_GATEWAY_ADMISSION_POLL_SECONDS=${GDC_GATEWAY_ADMISSION_POLL_SECONDS:-0.25}"
  "GDC_GATEWAY_ADMISSION_MAX_BODY_BYTES=${GDC_GATEWAY_ADMISSION_MAX_BODY_BYTES:-1048576}"
  "GDC_GATEWAY_ADMISSION_MAX_DISPATCHES_PER_BLOCK=${GDC_GATEWAY_ADMISSION_MAX_DISPATCHES_PER_BLOCK:-1}"
  "GDC_GATEWAY_ADMISSION_AUDIT_FILE=/edge/status/gateway-admission.jsonl"
  "TELEGRAM_BOT_PUBLIC_HOST=$telegram_bot_public_host"
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
