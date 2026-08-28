#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="$ROOT/scripts/gateway-reserve-policy.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

adequate="$($POLICY 700 100 100 2 2 1 10 100 100 1000)"
jq -e '.liabilities == 200 and .low_watermark == 710 and .target_balance == 810 and .deficit == 110 and .safe_rotations_remaining == 4' <<<"$adequate" >/dev/null

at_low="$($POLICY 710 100 100 2 2 1 10 100 100 1000)"
jq -e '.deficit == 100 and .low_watermark == 710' <<<"$at_low" >/dev/null

full="$($POLICY 810 100 100 2 2 1 10 100 100 1000)"
jq -e '.deficit == 0' <<<"$full" >/dev/null

if $POLICY 1 100 99 1 1 1 0 0 0 1000 >/dev/null 2>&1; then
  echo 'rotation below live minimum was accepted' >&2; exit 1
fi
if $POLICY 1 100 100 9999999999999999999 1 1 0 0 0 1000 >/dev/null 2>&1; then
  echo 'overflow was accepted' >&2; exit 1
fi
if $POLICY 0 100 100 1 1 1 0 0 0 1 >/dev/null 2>&1; then
  echo 'unbounded deficit was accepted' >&2; exit 1
fi

install -d "$tmp/controller" "$tmp/bin"
install -m 0755 "$ROOT/04-ops/gateway-reserve-controller.sh" "$tmp/controller/gateway-reserve-controller.sh"
install -m 0755 "$POLICY" "$tmp/controller/gateway-reserve-policy.sh"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
output=''
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
emit() {
  local body="$1" status="${2:-200}"
  if [[ -n "$output" ]]; then
    printf '%s\n' "$body" >"$output"
    printf '%s' "$status"
  else
    printf '%s\n' "$body"
  fi
}
[[ "${GDC_TEST_CHAIN_UNAVAILABLE:-false}" != true ]] || exit 22
case "$args" in
  *'/cosmos/bank/'*) emit "{\"balances\":[{\"denom\":\"ngonka\",\"amount\":\"${GDC_TEST_BALANCE:-601}\"}]}" ;;
  *'/cosmos/tx/'*) emit "${GDC_TEST_TX_RESPONSE:-}" ;;
  *'/v1/admin/devshards'*) emit "${GDC_TEST_ADMIN_STATE:-{\"devshards\":[]}}" ;;
  *)
    [[ -n "${GDC_TEST_POST_LOG:-}" ]] && printf 'post\n' >>"$GDC_TEST_POST_LOG"
    if [[ "${GDC_TEST_SIGNER_UNAVAILABLE:-false}" == true ]]; then
      emit '{"error":"gateway reserve funding account has insufficient funds"}' 503
    else
      emit '{"txhash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"submitted"}'
    fi
    ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"
cat >"$tmp/gateway.env" <<'EOF'
GDC_GATEWAY_ACCOUNT=gonka1abc
GDC_GATEWAY_CHAIN_REST=http://127.0.0.1:1317
GDC_GATEWAY_RESERVE_MIN_AMOUNT=100
DEVSHARD_ROTATION_ESCROW_AMOUNT=100
GDC_GATEWAY_ROTATION_TEMP_COUNT=2
GDC_GATEWAY_ROTATION_TARGET_COUNT=2
GDC_GATEWAY_FUNDING_HORIZON_ROTATIONS=1
GDC_GATEWAY_FEE_RESERVE_NGONKA=1
GDC_GATEWAY_MAX_REFILL_NGONKA=1000
GDC_GATEWAY_RESERVE_SIGNER_URL=http://127.0.0.1:18083
GDC_GATEWAY_RESERVE_TOKEN=test-only
DEVSHARD_ADMIN_API_KEY=test-admin
GDC_GATEWAY_ADMIN_URL=http://127.0.0.1:18080
GDC_GATEWAY_REPLACEMENT_MAX_ATTEMPTS=1
EOF
GDC_TEST_BALANCE=701 PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$tmp/ready.json" GDC_GATEWAY_RESERVE_LOCK="$tmp/ready.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
jq -e '.state == "READY" and .reason == "reserve_sufficient" and .target_balance == 701' "$tmp/ready.json" >/dev/null

GDC_TEST_BALANCE=1000 GDC_TEST_ADMIN_STATE='{"devshards":[{"active":true,"runtime":{"phase":"active","requests_blocked":false}},{"active":true,"runtime":{"phase":"active","requests_blocked":false}}]}' \
  PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$tmp/liabilities.json" GDC_GATEWAY_RESERVE_LOCK="$tmp/liabilities.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
jq -e '.liabilities == 300 and .low_watermark == 801' "$tmp/liabilities.json" >/dev/null

set +e
PATH="$tmp/bin:$PATH" GDC_TEST_CHAIN_UNAVAILABLE=true GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$tmp/blocked.json" GDC_GATEWAY_RESERVE_LOCK="$tmp/blocked.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
controller_rc=$?
set -e
[[ "$controller_rc" == 1 ]]
jq -e '.state == "BLOCKED" and .reason == "reserve_chain_unavailable"' "$tmp/blocked.json" >/dev/null

# A signer outage preserves one attempt identity throughout backoff. A retry
# before next_attempt_at must not create or submit another logical refill.
signer_file="$tmp/signer-unavailable.json"
signer_post_log="$tmp/signer-posts.log"
set +e
GDC_TEST_BALANCE=500 GDC_TEST_SIGNER_UNAVAILABLE=true GDC_TEST_POST_LOG="$signer_post_log" \
  PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$signer_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/signer.lock" \
  "$tmp/controller/gateway-reserve-controller.sh" >/dev/null 2>&1
signer_first_rc=$?
set -e
[[ "$signer_first_rc" == 1 ]]
signer_identity="$(jq -r '.attempt.identity' "$signer_file")"
set +e
GDC_TEST_BALANCE=500 GDC_TEST_SIGNER_UNAVAILABLE=true GDC_TEST_POST_LOG="$signer_post_log" \
  PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$signer_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/signer.lock" \
  "$tmp/controller/gateway-reserve-controller.sh" >/dev/null 2>&1
signer_backoff_rc=$?
set -e
[[ "$signer_backoff_rc" == 1 ]]
[[ "$(jq -r '.attempt.identity' "$signer_file")" == "$signer_identity" ]]
[[ "$(wc -l <"$signer_post_log")" == 1 ]]
[[ "$(jq -r .reason "$signer_file")" == reserve_backoff ]]

# A persisted submission is retried with the same identity only while its
# transaction is unresolved. A later equal deficit gets a fresh identity after
# the previous transaction has reached a terminal, balance-reconciled state.
attempt_file="$tmp/attempt.json"
post_log="$tmp/posts.log"
GDC_TEST_BALANCE=500 GDC_TEST_POST_LOG="$post_log" PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$attempt_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/attempt.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
first_identity="$(jq -r '.attempt.identity' "$attempt_file")"
jq -e '.state == "RECOVERING" and .reason == "refill_submitted" and .attempt.state == "submitted"' "$attempt_file" >/dev/null
set +e
GDC_TEST_BALANCE=500 GDC_TEST_TX_RESPONSE='' GDC_TEST_POST_LOG="$post_log" PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$attempt_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/attempt.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
pending_rc=$?
set -e
[[ "$pending_rc" == 1 ]]
[[ "$(jq -r '.attempt.identity' "$attempt_file")" == "$first_identity" ]]
[[ "$(wc -l <"$post_log")" == 1 ]]
jq '.next_attempt_at = ""' "$attempt_file" >"$attempt_file.next" && mv "$attempt_file.next" "$attempt_file"
set +e
GDC_TEST_BALANCE=600 GDC_TEST_TX_RESPONSE='{"tx_response":{"code":0}}' GDC_TEST_POST_LOG="$post_log" PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$attempt_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/attempt.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
committed_rc=$?
set -e
[[ "$committed_rc" == 1 ]]
jq -e '.reason == "refill_balance_reconciled" and .attempt.state == "balance-reconciled"' "$attempt_file" >/dev/null
GDC_TEST_BALANCE=500 GDC_TEST_POST_LOG="$post_log" PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$attempt_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/attempt.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
second_identity="$(jq -r '.attempt.identity' "$attempt_file")"
[[ "$second_identity" != "$first_identity" ]]
[[ "$(wc -l <"$post_log")" == 2 ]]

# A chain-terminal failure is retained for diagnostics and is never presented
# as a submitted refill. The next need may create a new identity.
failed_file="$tmp/failed-attempt.json"
GDC_TEST_BALANCE=500 GDC_TEST_POST_LOG="$tmp/failed-posts.log" PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$failed_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/failed-attempt.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
set +e
GDC_TEST_BALANCE=500 GDC_TEST_TX_RESPONSE='{"tx_response":{"code":7}}' PATH="$tmp/bin:$PATH" GDC_GATEWAY_ENV="$tmp/gateway.env" \
  GDC_GATEWAY_RESERVE_FILE="$failed_file" GDC_GATEWAY_RESERVE_LOCK="$tmp/failed-attempt.lock" \
  "$tmp/controller/gateway-reserve-controller.sh"
failed_rc=$?
set -e
[[ "$failed_rc" == 1 ]]
jq -e '.reason == "refill_transaction_failed" and .attempt.state == "failed"' "$failed_file" >/dev/null
printf 'PASS gateway reserve policy contract\n'
