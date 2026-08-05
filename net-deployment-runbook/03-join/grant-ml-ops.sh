#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 NODE_NAME IDENTITY_JSON inventory.env" >&2; }
[[ $# -eq 3 ]] || { usage; exit 2; }
NODE="$1"; IDENTITY="$2"; INVENTORY="$3"
[[ "$NODE" =~ ^gdc-node[0-4]$ ]] || { echo 'gdc-node0..4 expected' >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$INVENTORY"
PASSWORD="$(<"$ROOT/state/secrets/operator.keyring")"; WARM="$(jq -r .warm_address "$IDENTITY")"
COLD="${NODE}-cold"
printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" tx inference grant-ml-ops-permissions \
  "$COLD" "$WARM" --from "$COLD" --keyring-backend file --chain-id "$CHAIN_ID" \
  --node "https://${NODE0_PUBLIC_HOST}/chain-rpc/" \
  --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --yes
