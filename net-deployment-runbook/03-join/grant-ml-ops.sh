#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 NODE_NAME IDENTITY_JSON inventory.env" >&2; }
[[ $# -eq 3 ]] || { usage; exit 2; }
NODE="$1"; IDENTITY="$2"; INVENTORY="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
topology_contains_node "$NODE" || { echo "node is not configured in inventory: $NODE" >&2; exit 2; }
PASSWORD="$(<"$ROOT/state/secrets/operator.keyring")"; WARM="$(jq -r .warm_address "$IDENTITY")"
COLD="${NODE}-cold"
# The command runs in a Docker container on the operator host. Re-entering
# a participant through its own public hostname can be classified as an
# internal proxy request and rejected with HTML 400. The configured public edge
# is the stable external operator route even before it becomes a participant.
RPC="${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}"

# The node containers can be running before their public RPC proxy has
# completed its own restart.  A transaction command probes the RPC while
# building its client context; without this gate a transient proxy 400 makes a
# freshly started Genesis fail after the node is already healthy.
rpc_ready=false
for _ in $(seq 1 60); do
  status="$("$ROOT/scripts/inferenced.sh" status --node "$RPC" --output json 2>/dev/null || true)"
  if jq -e --arg chain "$CHAIN_ID" '.node_info.network == $chain and (.sync_info.latest_block_height | tonumber) > 0' \
    <<<"$status" >/dev/null 2>&1; then
    rpc_ready=true
    break
  fi
  printf 'WAIT  public chain RPC before granting ML operations\n' >&2
  sleep 2
done
[[ "$rpc_ready" == true ]] || { echo 'public chain RPC did not become ready for ML operations grant' >&2; exit 1; }

printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" tx inference grant-ml-ops-permissions \
  "$COLD" "$WARM" --from "$COLD" --keyring-backend file --chain-id "$CHAIN_ID" \
  --node "$RPC" \
  --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --yes
