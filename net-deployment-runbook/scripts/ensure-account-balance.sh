#!/usr/bin/env bash
# Reconcile a managed network account to an explicit spendable balance.
set -Eeuo pipefail

usage() {
  echo "Usage: $0 account.json inventory.env target-ngonka" >&2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

is_safe_integer() {
  local value="$1" maximum=9223372036854775807 index value_digit maximum_digit
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  (( ${#value} < ${#maximum} )) && return 0
  (( ${#value} == ${#maximum} )) || return 1
  for ((index = 0; index < ${#maximum}; index++)); do
    value_digit="${value:index:1}"
    maximum_digit="${maximum:index:1}"
    (( value_digit < maximum_digit )) && return 0
    (( value_digit > maximum_digit )) && return 1
  done
  return 0
}

account_balance_wait() {
  sleep 2
}

read_spendable_balance() {
  local endpoint="$1" address="$2" response stderr_file http_status rc detail balance
  response="$(mktemp)"
  stderr_file="$(mktemp)"
  set +e
  http_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$response" -w '%{http_code}' \
    "${endpoint%/}/cosmos/bank/v1beta1/spendable_balances/$address" 2>"$stderr_file")"
  rc=$?
  set -e
  if (( rc != 0 )) || [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    detail="$(tr '\n' ' ' <"$stderr_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    rm -f "$response" "$stderr_file"
    echo "managed account balance unavailable url_role=chain_api http_status=${http_status:-000} curl_exit=$rc curl_status=$(curl_exit_status "$rc")${detail:+ detail=$detail}" >&2
    return 1
  fi
  balance="$(jq -er '[.balances[]? | select(.denom == "ngonka") | .amount][0] // "0"' "$response" 2>/dev/null)" || {
    rm -f "$response" "$stderr_file"
    echo 'managed account balance response is not valid Gonka bank JSON' >&2
    return 1
  }
  rm -f "$response" "$stderr_file"
  is_safe_integer "$balance" || {
    echo 'managed account spendable balance is outside the supported signed integer range' >&2
    return 1
  }
  printf '%s\n' "$balance"
}

fund_account() {
  "$ROOT/03-join/fund-account.sh" "$@"
}

ensure_account_balance_main() {
  [[ $# -eq 3 ]] || { usage; return 2; }
  local account_json="$1" inventory="$2" target="$3" address chain_api current deficit
  [[ -s "$account_json" && -s "$inventory" && "$target" != 0 ]] && is_safe_integer "$target" || {
    usage
    return 2
  }
  load_env "$inventory"
  load_topology
  address="$(jq -er .address "$account_json")"
  [[ "$address" =~ ^gonka1[0-9a-z]+$ ]] || {
    echo 'managed account JSON contains an invalid Gonka address' >&2
    return 2
  }
  # Funding is submitted and confirmed through the Genesis node RPC by
  # fund-account.sh. Read the matching Genesis REST surface as the same
  # authoritative state boundary; a configurable observer API may lag and
  # otherwise cause a repeated invocation to fund the same committed deficit.
  chain_api="https://${GENESIS_PUBLIC_HOST}/chain-api"
  current="$(read_spendable_balance "$chain_api" "$address")"
  if (( current >= target )); then
    printf 'PASS managed account reserve current=%s target=%s\n' "$current" "$target"
    return 0
  fi
  deficit="$((target - current))"
  fund_account "$account_json" "$inventory" "$deficit"
  for attempt in $(seq 1 30); do
    current="$(read_spendable_balance "$chain_api" "$address")"
    if (( current >= target )); then
      printf 'PASS managed account reserve current=%s target=%s\n' "$current" "$target"
      return 0
    fi
    printf 'WAIT managed account funding visibility attempt=%s/30 current=%s target=%s\n' \
      "$attempt" "$current" "$target"
    (( attempt == 30 )) || account_balance_wait
  done
  echo "managed account reserve remains below target current=$current target=$target" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ensure_account_balance_main "$@"
fi
