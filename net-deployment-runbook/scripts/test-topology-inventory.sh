#!/usr/bin/env bash
# shellcheck disable=SC2034 # fixture variables are consumed after load_env in a sourced shell
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
GDC_NODE_ALIASES='validator-a validator-b validator-c'
GDC_NODE_PUBLIC_HOSTS='validator-a=validator-a.example.net validator-b=validator-b.example.net validator-c=validator-c.example.net'
GDC_NODE_GPU_PROFILES='validator-a=a5000-24g validator-b=t4-16g validator-c=blackwell-16g'
GDC_NODE_P2P_PORTS='validator-a=5000 validator-b=5100 validator-c=5200'
GDC_NODE_ML_HOSTS='validator-c=operator-c-gpu'
GDC_GENESIS_NODE=validator-a
GDC_PUBLIC_EDGE_NODE=validator-c
GDC_GATEWAY_NODE=validator-a
GDC_TELEGRAM_BOT_HOST=validator-c
load_topology

[[ "$GENESIS_NODE" == validator-a && "$PUBLIC_EDGE_NODE" == validator-c && "$GATEWAY_NODE" == validator-a ]]
[[ "$(node_name validator-b)" == validator-b ]]
[[ "$(node_ml_host validator-c)" == operator-c-gpu ]]
[[ "$(node_for_ml_host operator-c-gpu)" == validator-c ]]
[[ "$(node_p2p_port validator-b)" == 5100 ]]

if (
  GDC_NODE_ALIASES='validator-a validator-b'
  GDC_NODE_PUBLIC_HOSTS='validator-a=validator-a.example.net validator-b=validator-b.example.net'
  GDC_NODE_GPU_PROFILES='validator-a=a5000-24g validator-b=t4-16g'
  GDC_NODE_P2P_PORTS='validator-a=5000 validator-b=5100'
  GDC_NODE_ML_HOSTS='validator-a=validator-b'
  load_topology
) 2>/dev/null; then
  echo 'ML SSH aliases must not collide with any validator alias' >&2
  exit 1
fi

CHAIN_ID=gonka-devnet-community
BASE_DENOM=ngonka
SITE_HOST=gonka-dev.net
API_HOST=api.gonka-dev.net
GRAFANA_HOST=grafana.gonka-dev.net
ACME_EMAIL=operator@example.net
MONITORING_CIDR=198.51.100.1/32
PUBLIC_EDGE_CIDR=198.51.100.2/32
DATA_ROOT=/srv/dai
GENESIS_INSTALL_PATH=/srv/dai/shared/genesis.json
HF_CACHE_ROOT=/srv/dai/hf-cache
INVENTORY="$tmp/inventory.env"
write_inventory
unset GDC_NODE_ALIASES GDC_NODE_PUBLIC_HOSTS GDC_NODE_GPU_PROFILES GDC_NODE_P2P_PORTS GDC_NODE_ML_HOSTS
load_env "$INVENTORY"
[[ "$GDC_NODE_ALIASES" == 'validator-a validator-b validator-c' ]]
[[ "$GDC_NODE_ML_HOSTS" == 'validator-c=operator-c-gpu' ]]
[[ "$GDC_GENESIS_NODE" == validator-a ]]
[[ "$GDC_PUBLIC_EDGE_NODE" == validator-c ]]
[[ "$GDC_GATEWAY_NODE" == validator-a ]]
for ops_only in BASE_DOMAIN GRAFANA_PUBLIC_DASHBOARD_UID GRAFANA_PUBLIC_DASHBOARD_SHARE_UID GRAFANA_PUBLIC_DASHBOARD_TOKEN TELEGRAM_BOT_HOST TELEGRAM_BOT_URL; do
  if grep -q "^${ops_only}=" "$INVENTORY"; then
    echo "JOIN inventory contains OPS-only field: $ops_only" >&2
    exit 1
  fi
done
grep -Fq 'topology_contains_node "$HOST"' "$ROOT/01-identities-genesis/collect-identities.sh"
if grep -Eq 'gdc-node\[0-4\]|gdc-nodeN' "$ROOT/01-identities-genesis/collect-identities.sh"; then
  echo 'identity collection must accept the operator inventory aliases, not lab node names' >&2
  exit 1
fi
printf 'PASS inventory accepts arbitrary validator and network-GPU SSH aliases\n'
