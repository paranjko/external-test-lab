#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 3 ]] || { echo "Usage: $0 inventory.env secrets-dir output-dir" >&2; exit 2; }
INVENTORY="$1"; SECRETS="$2"; OUT="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
mkdir -p "$OUT"
for node in "${GDC_NODES[@]}"; do
  "$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "$node" \
    --account-public "$GDC_HOME/accounts/$node-cold.json" --bootstrap \
    --secrets-dir "$SECRETS" --output "$OUT/$node.env"
done
