#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 3 ]] || { echo "Usage: $0 inventory.env secrets-dir output-dir" >&2; exit 2; }
INVENTORY="$1"; SECRETS="$2"; OUT="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$OUT"
for i in 0 1 2 3 4; do
  "$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "gdc-node$i" \
    --account-public "$ROOT/artifacts/accounts/gdc-node${i}-cold.json" --bootstrap \
    --secrets-dir "$SECRETS" --output "$OUT/gdc-node$i.env"
done
