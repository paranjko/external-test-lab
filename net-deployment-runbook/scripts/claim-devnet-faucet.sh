#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

address="${1:-}"
[[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] || die 'expected a Gonka Host cold address'
amount="${GDC_FAUCET_CLAIM_NGONKA:-100000000000}"
[[ "$amount" =~ ^[1-9][0-9]*$ ]] || die 'GDC_FAUCET_CLAIM_NGONKA must be positive'
endpoint="${GDC_FAUCET_URL:-https://${GENESIS_PUBLIC_HOST}/faucet/v1/claim}"
endpoint="${endpoint%/}"

# The claim runs after the Host is registered, where a stop has no way back.
# One claim exists per address and a repeated POST answers 409, so a transport
# failure or a gateway error is retried without double funding.
attempt=0
while :; do
  attempt=$((attempt + 1))
  response="$(curl -sS --connect-timeout 10 --max-time 60 -w $'\n%{http_code}' \
    -X POST "$endpoint" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg address "$address" '{address:$address}')" || true)"
  http_code="${response##*$'\n'}"
  payload="${response%$'\n'*}"
  [[ "$http_code" =~ ^(000|502|503|504)$ ]] || break
  (( attempt < 6 )) || break
  printf 'WAIT DevNet faucet unavailable http_status=%s attempt=%s/6; retrying\n' "$http_code" "$attempt"
  sleep 10
done
if [[ "$http_code" == 409 ]]; then
  # A retry after an interrupted join is safe: the faucet gives one claim per
  # Host address, and the balance check below determines whether it settled.
  claim_state="$(jq -r '.state // empty' <<<"$payload" 2>/dev/null || true)"
  if [[ "$claim_state" == confirmed ]]; then
    printf 'READY faucet claim already confirmed for %s\n' "$address"
  else
    die 'DevNet faucet retained an unconfirmed earlier claim; an operator must recover the faucet claim before JOIN can continue'
  fi
elif [[ "$http_code" == 200 ]]; then
  txhash="$(jq -r .txhash <<<"$payload")"
  [[ "$txhash" =~ ^[0-9A-Fa-f]{64}$ ]] || die 'faucet response lacks a transaction hash'
  [[ "$(jq -r '.state // empty' <<<"$payload")" == confirmed ]] || die 'faucet response is not confirmed'
  printf 'READY faucet confirmed funding for %s tx=%s\n' "$address" "$txhash"
elif [[ "$http_code" == 202 ]]; then
  txhash="$(jq -r .txhash <<<"$payload")"
  [[ "$txhash" =~ ^[0-9A-Fa-f]{64}$ ]] || die 'faucet response lacks a transaction hash'
  printf 'READY faucet submitted funding for %s tx=%s\n' "$address" "$txhash"
else
  detail="$(jq -r '.detail // .error // empty' <<<"$payload" 2>/dev/null || true)"
  die "DevNet faucet rejected funding request (HTTP $http_code): ${detail:-unexpected response}"
fi

deadline=$((SECONDS + ${GDC_FAUCET_SETTLEMENT_TIMEOUT_SECONDS:-180}))
next_progress=$SECONDS
while (( SECONDS < deadline )); do
  balance_endpoint="https://${GENESIS_PUBLIC_HOST}/chain-api/cosmos/bank/v1beta1/spendable_balances/$address"
  balance_body="$(mktemp)"
  balance_stderr="$(mktemp)"
  if balance_http_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$balance_body" -w '%{http_code}' \
    "$balance_endpoint" 2>"$balance_stderr")"; then
    balance_curl_exit=0
  else
    balance_curl_exit=$?
  fi
  if (( balance_curl_exit == 0 )) && [[ "$balance_http_status" =~ ^2[0-9][0-9]$ ]]; then
    balance="$(jq -r '[.balances[]? | select(.denom == "ngonka") | (.amount | tonumber)] | add // 0' "$balance_body")"
  else
    balance_detail="$(tr '\n' ' ' <"$balance_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    printf 'WAIT DevNet faucet balance unavailable url=%s http_status=%s curl_exit=%s curl_status=%s%s\n' \
      "$balance_endpoint" "${balance_http_status:-000}" "$balance_curl_exit" "$(curl_exit_status "$balance_curl_exit")" "${balance_detail:+ detail=$balance_detail}"
    balance='0'
  fi
  rm -f "$balance_body" "$balance_stderr"
  if [[ "$balance" =~ ^[0-9]+$ ]] && (( balance >= amount )); then
    printf 'PASS DevNet faucet funded %s with at least %sngonka\n' "$address" "$amount"
    exit 0
  fi
  if (( SECONDS >= next_progress )); then
    printf 'WAIT DevNet faucet funding elapsed=%ss remaining=%ss address=%s balance=%sngonka required=%sngonka\n' \
      "$((SECONDS - (deadline - ${GDC_FAUCET_SETTLEMENT_TIMEOUT_SECONDS:-180})))" "$((deadline - SECONDS))" "$address" "$balance" "$amount"
    next_progress=$((SECONDS + 15))
  fi
  sleep 3
done
die "DevNet faucet funding for $address was not visible within ${GDC_FAUCET_SETTLEMENT_TIMEOUT_SECONDS:-180}s"
