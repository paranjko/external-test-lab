#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 inventory.env gateway-account.json minimum-spendable-ngonka" >&2; }
[[ $# == 3 ]] || { usage; exit 2; }
INVENTORY="$1"; ACCOUNT_JSON="$2"; MINIMUM="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
ADDRESS="$(jq -er .address "$ACCOUNT_JSON")"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]+$ ]] || { echo 'invalid gateway address' >&2; exit 2; }
[[ "$MINIMUM" =~ ^[1-9][0-9]*$ ]] || { echo 'minimum spendable balance must be positive' >&2; exit 2; }

spendable_balance() {
  curl -fsS --max-time 10 \
    "https://${GENESIS_PUBLIC_HOST}/chain-api/cosmos/bank/v1beta1/spendable_balances/$ADDRESS" \
    | jq -er '[.balances[]? | select(.denom == "ngonka") | .amount][0] // "0"'
}

CURRENT="$(spendable_balance)"
[[ "$CURRENT" =~ ^[0-9]+$ ]] || { echo 'invalid gateway spendable balance' >&2; exit 1; }
if (( CURRENT >= MINIMUM )); then
  printf 'PASS gateway spendable reserve %sngonka >= %sngonka\n' "$CURRENT" "$MINIMUM"
  exit 0
fi

DEFICIT=$((MINIMUM - CURRENT))
"$ROOT/03-join/fund-account.sh" "$ACCOUNT_JSON" "$INVENTORY" "$DEFICIT"
for _ in $(seq 1 30); do
  CURRENT="$(spendable_balance)"
  [[ "$CURRENT" =~ ^[0-9]+$ ]] && (( CURRENT >= MINIMUM )) && {
    printf 'PASS gateway spendable reserve restored to %sngonka\n' "$CURRENT"
    exit 0
  }
  sleep 2
done
echo "gateway spendable reserve remains below $MINIMUM ngonka" >&2
exit 1
