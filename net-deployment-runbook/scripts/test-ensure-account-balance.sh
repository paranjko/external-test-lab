#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'PUBLIC_EDGE_HOST=gonka.example\nGENESIS_PUBLIC_HOST=node0.example\n' >"$tmp/inventory.env"
printf '{"address":"gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' >"$tmp/account.json"

source "$ROOT/scripts/ensure-account-balance.sh"
load_env() { :; }
load_topology() { export GENESIS_PUBLIC_HOST=node0.example; }
account_balance_wait() { :; }

set_balances() {
  printf '%s\n' "$@" >"$tmp/balances"
}
read_spendable_balance() {
  local value
  if [[ -s "$tmp/balances" ]]; then
    value="$(head -n 1 "$tmp/balances")"
    tail -n +2 "$tmp/balances" >"$tmp/balances.next"
    mv "$tmp/balances.next" "$tmp/balances"
    printf '%s\n' "$value" >"$tmp/last-balance"
  else
    value="$(<"$tmp/last-balance")"
  fi
  printf '%s\n' "$value"
}
fund_account() {
  printf '%s\n' "$3" >>"$tmp/funding.log"
}

set_balances 500
ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 >/dev/null
[[ ! -e "$tmp/funding.log" ]]

set_balances 100 500
ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 >/dev/null
[[ "$(cat "$tmp/funding.log")" == 400 ]]

rm -f "$tmp/funding.log"
set_balances 100 100 500
ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 >/dev/null
[[ "$(cat "$tmp/funding.log")" == 400 ]]

rm -f "$tmp/funding.log"
set_balances 100 499
if ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 >/dev/null 2>&1; then
  echo 'account reserve accepted a post-funding balance below target' >&2
  exit 1
fi

rm -f "$tmp/funding.log"
set_balances 450
ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 400 >/dev/null
[[ ! -e "$tmp/funding.log" ]]

set_balances 100 450
ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 400 >/dev/null
[[ "$(cat "$tmp/funding.log")" == 400 ]]

rm -f "$tmp/funding.log"
set_balances 100 399
if ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 400 >/dev/null 2>&1; then
  echo 'account reserve accepted a post-funding balance below its minimum' >&2
  exit 1
fi

if ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 0 >/dev/null 2>&1; then
  echo 'account reserve accepted a zero target' >&2
  exit 1
fi
if ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 9999999999999999999 >/dev/null 2>&1; then
  echo 'account reserve accepted an integer outside the supported range' >&2
  exit 1
fi
if ensure_account_balance_main "$tmp/account.json" "$tmp/inventory.env" 500 501 >/dev/null 2>&1; then
  echo 'account reserve accepted a minimum above its target' >&2
  exit 1
fi

printf 'PASS managed account reserve contract\n'
