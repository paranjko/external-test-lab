#!/usr/bin/env bash
# Keep the gateway reserve above a calculated horizon.  The signer is a
# separate loopback service; this process never receives a keyring or mnemonic.
set -Eeuo pipefail

gateway_env="${GDC_GATEWAY_ENV:-/srv/dai/ops/gateway.env}"
status_file="${GDC_GATEWAY_RESERVE_FILE:-/srv/dai/ops/status/gateway-reserve.json}"
lock_file="${GDC_GATEWAY_RESERVE_LOCK:-$(dirname "$status_file")/gateway-reserve.lock}"
mkdir -p "$(dirname "$status_file")"
exec 9>"$lock_file"
flock -n 9 || exit 0

value() { awk -v key="$1" 'index($0,key "=")==1 { if (++n > 1) exit 2; v=substr($0,length(key)+2) } END {if(n==1)print v;else exit 1}' "$gateway_env"; }
write_state() {
  local state="$1" reason="$2" policy="${3:-}" next="${4:-}" attempt="${5:-null}"
  [[ -n "$policy" ]] || policy='{}'
  jq -n --arg state "$state" --arg reason "$reason" --arg checked_at "$(date -u +%FT%TZ)" --arg next_attempt_at "$next" --argjson policy "$policy" --argjson attempt "$attempt" \
    '{state:$state,reason:$reason,checked_at:$checked_at,next_attempt_at:$next_attempt_at} + $policy + (if $attempt == null then {} else {attempt:$attempt} end)' >"${status_file}.tmp"
  chmod 0644 "${status_file}.tmp"; mv -f "${status_file}.tmp" "$status_file"
}
attempt_from_state() {
  jq -c '
    .attempt?
    | select(type == "object")
    | select((.identity | type) == "string" and (.identity | test("^[0-9a-f]{64}$")))
  ' "$status_file" 2>/dev/null || true
}
curl_status() {
  case "$1" in
    0) printf ok ;;
    6) printf dns_resolution_failed ;;
    7) printf connection_failed ;;
    22) printf http_error ;;
    28) printf timeout ;;
    35|60) printf tls_error ;;
    *) printf curl_error ;;
  esac
}
transaction_result() {
  local txhash="$1" response code
  response="$(curl -fsS --connect-timeout 3 --max-time 10 "$chain_rest/cosmos/tx/v1beta1/txs/$txhash" 2>/dev/null || true)"
  [[ -n "$response" ]] || { printf pending; return; }
  code="$(jq -r '.tx_response.code // .code // empty' <<<"$response" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]+$ ]] || { printf pending; return; }
  (( code == 0 )) && printf committed || printf failed
}
new_attempt() {
  local identity
  # The identity belongs to this funding need, not to a calendar day or a
  # deficit. Persist it before contacting the signer so a timeout retries the
  # same unresolved submission, while a later need necessarily receives a new
  # signer row.
  identity="$(printf '%s' "$(date -u +%FT%N):$$:$RANDOM:$account:$target_balance:$deficit" | sha256sum | cut -d' ' -f1)"
  jq -cn --arg identity "$identity" --arg account "$account" --argjson target_balance "$target_balance" --argjson deficit "$deficit" --argjson balance_before "$balance" \
    '{identity:$identity,state:"created",account:$account,target_balance:$target_balance,deficit:$deficit,balance_before:$balance_before,created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}'
}
[[ -s "$gateway_env" && ! -L "$gateway_env" ]] || { write_state BLOCKED gateway_credentials_unavailable; exit 1; }
account="$(value GDC_GATEWAY_ACCOUNT 2>/dev/null || true)"
chain_rest="$(value GDC_GATEWAY_CHAIN_REST 2>/dev/null || true)"
min_amount="$(value GDC_GATEWAY_RESERVE_MIN_AMOUNT 2>/dev/null || true)"
rotation="$(value DEVSHARD_ROTATION_ESCROW_AMOUNT 2>/dev/null || true)"
temporary="$(value GDC_GATEWAY_ROTATION_TEMP_COUNT 2>/dev/null || printf 2)"
target="$(value GDC_GATEWAY_ROTATION_TARGET_COUNT 2>/dev/null || printf 2)"
horizon="$(value GDC_GATEWAY_FUNDING_HORIZON_ROTATIONS 2>/dev/null || printf 1)"
fee="$(value GDC_GATEWAY_FEE_RESERVE_NGONKA 2>/dev/null || printf 1000000)"
maximum="$(value GDC_GATEWAY_MAX_REFILL_NGONKA 2>/dev/null || true)"
signer="$(value GDC_GATEWAY_RESERVE_SIGNER_URL 2>/dev/null || true)"
gateway_admin_key="$(value DEVSHARD_ADMIN_API_KEY 2>/dev/null || true)"
gateway_admin_url="$(value GDC_GATEWAY_ADMIN_URL 2>/dev/null || printf http://127.0.0.1:18080)"
reconciliation_file="${GDC_GATEWAY_RECONCILIATION_FILE:-$(dirname "$status_file")/gateway-reconciliation.json}"
replacement_max_attempts="$(value GDC_GATEWAY_REPLACEMENT_MAX_ATTEMPTS 2>/dev/null || printf 1)"
[[ "$account" =~ ^gonka1[0-9a-z]+$ && "$chain_rest" =~ ^http://127\.0\.0\.1: && "$signer" =~ ^http://127\.0\.0\.1: && "$maximum" =~ ^[1-9][0-9]*$ ]] || { write_state BLOCKED reserve_configuration_invalid; exit 1; }
[[ "$gateway_admin_key" != '' && "$gateway_admin_url" =~ ^http://127\.0\.0\.1: && "$replacement_max_attempts" =~ ^[1-9][0-9]*$ ]] || { write_state BLOCKED reserve_gateway_configuration_invalid; exit 1; }
balance="$(curl -fsS --connect-timeout 3 --max-time 10 "$chain_rest/cosmos/bank/v1beta1/spendable_balances/$account" | jq -er '[.balances[]?|select(.denom=="ngonka")|.amount][0] // "0"')" || { write_state BLOCKED reserve_chain_unavailable; exit 1; }
admin_state="$(curl -fsS --connect-timeout 3 --max-time 10 "$gateway_admin_url/v1/admin/devshards" -H "Authorization: Bearer $gateway_admin_key" 2>/dev/null || true)"
active_count="$(jq -er '[.devshards[]? | select(.active == true) | select((.runtime.phase // .phase // "") == "active") | select((.runtime.requests_blocked // .requests_blocked // false) != true)] | length' <<<"$admin_state" 2>/dev/null || true)"
[[ "$active_count" =~ ^[0-9]+$ ]] || { write_state BLOCKED reserve_gateway_admin_unavailable; exit 1; }
active_liabilities=$((active_count * rotation))
pending_count=0
if jq -e '.state == "RECOVERING" and (.replacement_escrow // "") != ""' "$reconciliation_file" >/dev/null 2>&1; then
  pending_count=1
fi
# The reconciler permits at most this many creates in the current epoch. Hold
# their full escrow cost before it starts another transition; a missing admin
# response fails closed above rather than fabricating zero liabilities.
pending_liabilities=$(((pending_count + replacement_max_attempts) * rotation))
policy="$("$(dirname "$0")/gateway-reserve-policy.sh" "$balance" "$min_amount" "$rotation" "$temporary" "$target" "$horizon" "$fee" "$active_liabilities" "$pending_liabilities" "$maximum")" || { write_state BLOCKED reserve_policy_rejected; exit 1; }
deficit="$(jq -er .deficit <<<"$policy")"
target_balance="$(jq -er .target_balance <<<"$policy")"
if (( deficit == 0 )); then write_state READY reserve_sufficient "$policy"; exit 0; fi
attempt="$(attempt_from_state)"
next="$(jq -r '.next_attempt_at // empty' "$status_file" 2>/dev/null || true)"
[[ -z "$next" || "$(date -u +%s)" -ge "$(date -u -d "$next" +%s 2>/dev/null || printf 0)" ]] || { write_state BLOCKED reserve_backoff "$policy" "$next" "${attempt:-null}"; exit 1; }
token="$(value GDC_GATEWAY_RESERVE_TOKEN 2>/dev/null || true)"
[[ -n "$token" ]] || { write_state BLOCKED reserve_signer_credential_unavailable "$policy"; exit 1; }
if [[ -n "$attempt" ]]; then
  attempt_state="$(jq -r .state <<<"$attempt")"
  txhash="$(jq -r '.txhash // empty' <<<"$attempt")"
  if [[ "$attempt_state" == submitted && "$txhash" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    tx_state="$(transaction_result "$txhash")"
    case "$tx_state" in
      pending)
        next="$(date -u -d '+60 seconds' +%FT%TZ)"
        write_state RECOVERING refill_submission_pending "$(jq --arg txhash "$txhash" '. + {last_refill_txhash:$txhash}' <<<"$policy")" "$next" "$attempt"
        exit 1
        ;;
      failed)
        attempt="$(jq '(.state="failed") + {finalized_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' <<<"$attempt")"
        write_state BLOCKED refill_transaction_failed "$policy" '' "$attempt"
        exit 1
        ;;
      committed)
        balance_before="$(jq -er .balance_before <<<"$attempt")"
        attempt="$(jq '(.state="committed-success") + {finalized_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' <<<"$attempt")"
        if (( balance > balance_before )); then
          attempt="$(jq --argjson balance_after "$balance" '(.state="balance-reconciled") + {balance_after:$balance_after}' <<<"$attempt")"
          write_state RECOVERING refill_balance_reconciled "$(jq --arg txhash "$txhash" '. + {last_refill_txhash:$txhash}' <<<"$policy")" '' "$attempt"
        else
          write_state BLOCKED refill_balance_unreconciled "$(jq --arg txhash "$txhash" '. + {last_refill_txhash:$txhash}' <<<"$policy")" '' "$attempt"
        fi
        # A terminal attempt is evidence, never a reusable submission. The
        # next controller invocation evaluates the current balance and creates
        # a new identity if funding is still required.
        exit 1
        ;;
    esac
  elif [[ "$attempt_state" == created ]]; then
    : # submit this persisted attempt below
  else
    attempt=''
  fi
fi
[[ -n "$attempt" ]] || attempt="$(new_attempt)"
idempotency="$(jq -r .identity <<<"$attempt")"
write_state RECOVERING refill_attempt_created "$policy" '' "$attempt"
signer_response="$(mktemp)"
signer_stderr="$(mktemp)"
set +e
signer_http_status="$(curl -sS --connect-timeout 3 --max-time 45 -o "$signer_response" -w '%{http_code}' \
  -X POST "$signer/v1/gateway-reserve" -H "Authorization: Bearer $token" \
  -H "Idempotency-Key: $idempotency" -H 'Content-Type: application/json' \
  --data "$(jq -cn --argjson target "$target_balance" '{target_balance:$target}')" 2>"$signer_stderr")"
signer_curl_exit=$?
set -e
if (( signer_curl_exit != 0 )) || [[ ! "$signer_http_status" =~ ^2[0-9][0-9]$ ]]; then
  signer_reason="$(jq -r '.error // empty' "$signer_response" 2>/dev/null || true)"
  signer_reason="$(tr '[:upper:] ' '[:lower:]_' <<<"$signer_reason" | sed 's/[^a-z0-9_-]//g; s/_\+/_/g; s/^_//; s/_$//')"
  signer_detail="$(tr '\n' ' ' <"$signer_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  printf 'ERROR gateway reserve signer request failed role=loopback-reserve-signer http_status=%s curl_exit=%s curl_status=%s%s%s\n' \
    "${signer_http_status:-000}" "$signer_curl_exit" "$(curl_status "$signer_curl_exit")" \
    "${signer_reason:+ reason=$signer_reason}" "${signer_detail:+ detail=$signer_detail}" >&2
  rm -f "$signer_response" "$signer_stderr"
  next="$(date -u -d '+60 seconds' +%FT%TZ)"
  write_state BLOCKED reserve_signer_unavailable "$policy" "$next" "$attempt"
  exit 1
fi
response="$(<"$signer_response")"
rm -f "$signer_response" "$signer_stderr"
txhash="$(jq -r '.txhash // empty' <<<"$response")"
[[ "$txhash" =~ ^[0-9A-Fa-f]{64}$ ]] || { write_state BLOCKED reserve_signer_invalid_response "$policy" '' "$attempt"; exit 1; }
attempt="$(jq --arg txhash "$txhash" '(.state="submitted") + {txhash:$txhash,submitted_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' <<<"$attempt")"
write_state RECOVERING refill_submitted "$(jq --arg txhash "$txhash" '. + {last_refill_txhash:$txhash}' <<<"$policy")" '' "$attempt"
