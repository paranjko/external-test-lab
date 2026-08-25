#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 inventory.env gateway-account.json live-minimum-ngonka rotation-amount temporary-escrows target-escrows funding-horizon fee-reserve active-liabilities pending-liabilities max-refill" >&2; }
[[ $# -eq 11 ]] || { usage; exit 2; }
INVENTORY="$1"; ACCOUNT_JSON="$2"; MINIMUM="$3"; ROTATION_AMOUNT="$4"; TEMPORARY="$5"; TARGET_COUNT="$6"; FUNDING_HORIZON="$7"; FEE_RESERVE="$8"; ACTIVE_LIABILITIES="$9"; PENDING_LIABILITIES="${10}"; MAX_REFILL="${11}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
ADDRESS="$(jq -er .address "$ACCOUNT_JSON")"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]+$ ]] || { echo 'invalid gateway address' >&2; exit 2; }
[[ "$MINIMUM" =~ ^[1-9][0-9]*$ ]] || { echo 'live minimum spendable balance must be positive' >&2; exit 2; }

spendable_balance() {
  curl -fsS --max-time 10 \
    "https://${GENESIS_PUBLIC_HOST}/chain-api/cosmos/bank/v1beta1/spendable_balances/$ADDRESS" \
    | jq -er '[.balances[]? | select(.denom == "ngonka") | .amount][0] // "0"'
}

CURRENT="$(spendable_balance)"
[[ "$CURRENT" =~ ^[0-9]+$ ]] || { echo 'invalid gateway spendable balance' >&2; exit 1; }
policy() {
  "$ROOT/scripts/gateway-reserve-policy.sh" "$CURRENT" "$MINIMUM" "$ROTATION_AMOUNT" "$TEMPORARY" "$TARGET_COUNT" "$FUNDING_HORIZON" "$FEE_RESERVE" "$ACTIVE_LIABILITIES" "$PENDING_LIABILITIES" "$MAX_REFILL"
}
reserve="$(policy)"
low_watermark="$(jq -er '.low_watermark' <<<"$reserve")"
target_balance="$(jq -er '.target_balance' <<<"$reserve")"
deficit="$(jq -er '.deficit' <<<"$reserve")"
if (( CURRENT >= target_balance )); then
  printf 'PASS gateway reserve policy %s\n' "$reserve"
  exit 0
fi
(( deficit > 0 )) || { echo 'gateway reserve policy produced no refill below target' >&2; exit 1; }
"$ROOT/03-join/fund-account.sh" "$ACCOUNT_JSON" "$INVENTORY" "$deficit"
for _ in $(seq 1 30); do
  CURRENT="$(spendable_balance)"
  [[ "$CURRENT" =~ ^[0-9]+$ ]] || continue
  reserve="$(policy)" || exit $?
  low_watermark="$(jq -er '.low_watermark' <<<"$reserve")"
  [[ "$CURRENT" =~ ^[0-9]+$ ]] && (( CURRENT >= low_watermark )) && {
    printf 'PASS gateway reserve policy %s\n' "$reserve"
    exit 0
  }
  sleep 2
done
echo "gateway spendable reserve remains below calculated low watermark $low_watermark ngonka" >&2
exit 1
