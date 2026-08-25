#!/usr/bin/env bash
# Calculate the gateway escrow reserve from explicit, integer-only inputs.
#
# Usage: gateway-reserve-policy.sh CURRENT MIN_AMOUNT ROTATION_AMOUNT \
#   TEMPORARY_ESCROWS TARGET_ESCROWS FUNDING_HORIZON FEE_RESERVE \
#   ACTIVE_LIABILITIES PENDING_LIABILITIES MAX_REFILL
set -Eeuo pipefail

usage() {
  echo "Usage: $0 current min-amount rotation-amount temporary-escrows target-escrows funding-horizon fee-reserve active-liabilities pending-liabilities max-refill" >&2
}

[[ $# -eq 10 ]] || { usage; exit 2; }
for value in "$@"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "gateway reserve policy accepts non-negative integer inputs only" >&2; exit 2; }
done

current="$1" min_amount="$2" rotation_amount="$3" temporary="$4" target="$5"
funding_horizon="$6" fee_reserve="$7" active_liabilities="$8"
pending_liabilities="$9" max_refill="${10}"
[[ "$min_amount" != 0 && "$rotation_amount" != 0 ]] || {
  echo 'gateway reserve policy requires positive min_amount and rotation_amount' >&2
  exit 2
}

max_int=9223372036854775807
safe_add() {
  local left="$1" right="$2"
  (( left <= max_int - right )) || { echo 'gateway reserve policy arithmetic overflow' >&2; exit 2; }
  printf '%s\n' "$((left + right))"
}
safe_mul() {
  local left="$1" right="$2"
  if (( left != 0 && right > max_int / left )); then
    echo 'gateway reserve policy arithmetic overflow' >&2
    exit 2
  fi
  printf '%s\n' "$((left * right))"
}

# A release profile may choose a larger rotation amount, but it must never be
# smaller than the live chain minimum.
(( rotation_amount >= min_amount )) || {
  echo 'gateway rotation amount is below the live chain minimum' >&2
  exit 2
}
liabilities="$(safe_add "$active_liabilities" "$pending_liabilities")"
escrows_before_funding="$(safe_add "$temporary" "$target")"
escrows_before_funding="$(safe_add "$escrows_before_funding" "$funding_horizon")"
rotation_liability="$(safe_mul "$rotation_amount" "$escrows_before_funding")"
low_watermark="$(safe_add "$liabilities" "$rotation_liability")"
low_watermark="$(safe_add "$low_watermark" "$fee_reserve")"
# Keep one additional rotation above the intervention threshold. This makes a
# committed refill useful even if rotation advances while it is confirming.
target_balance="$(safe_add "$low_watermark" "$rotation_amount")"
if (( current >= target_balance )); then
  deficit=0
elif (( current >= low_watermark )); then
  deficit="$((target_balance - current))"
else
  deficit="$((target_balance - current))"
fi
(( deficit <= max_refill )) || {
  echo "gateway reserve deficit ${deficit} exceeds configured maximum refill ${max_refill}" >&2
  exit 1
}
remaining_after_liabilities=0
if (( current > liabilities + fee_reserve )); then
  remaining_after_liabilities="$((current - liabilities - fee_reserve))"
fi
safe_rotations_remaining="$((remaining_after_liabilities / rotation_amount))"

jq -n \
  --argjson current_balance "$current" \
  --argjson min_amount "$min_amount" \
  --argjson rotation_amount "$rotation_amount" \
  --argjson liabilities "$liabilities" \
  --argjson low_watermark "$low_watermark" \
  --argjson target_balance "$target_balance" \
  --argjson deficit "$deficit" \
  --argjson safe_rotations_remaining "$safe_rotations_remaining" \
  --arg explanation "live minimum ${min_amount}; ${escrows_before_funding} funded rotations before the next guaranteed funding opportunity; liabilities and fee reserve included" \
  '{current_balance:$current_balance,min_amount:$min_amount,rotation_amount:$rotation_amount,liabilities:$liabilities,low_watermark:$low_watermark,target_balance:$target_balance,deficit:$deficit,safe_rotations_remaining:$safe_rotations_remaining,explanation:$explanation}'
