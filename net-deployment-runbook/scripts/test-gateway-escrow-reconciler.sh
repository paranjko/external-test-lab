#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECONCILER="$ROOT/04-ops/gateway-escrow-reconciler.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

write_env() {
  local path="$1"
  cat >"$path" <<'EOF'
DEVSHARD_ADMIN_API_KEY=test-admin
DEVSHARD_PRIVATE_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DEVSHARD_MODEL=Qwen/Qwen3-0.6B
DEVSHARD_ROUTE_PREFIX=/devshard/v3
DEVSHARD_CHAIN_ID=gonka-devnet-community
DEVSHARD_ROTATION_ESCROW_AMOUNT=1
GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED=true
EOF
}

run_case() {
  local name="$1"
  local case_dir="$WORK/$name"
  mkdir -p "$case_dir/bin"
  write_env "$case_dir/gateway.env"
  printf '%s\n' '{"state":"READY","current_balance":1000,"low_watermark":100}' >"$case_dir/reserve.json"
  cat >"$case_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$CASE_DIR/curl.log"
url=''
for arg in "$@"; do
  [[ "$arg" == http://gateway* || "$arg" == http://chain* ]] && url="$arg"
done
if [[ "$url" == *'/v1/admin/devshards' ]]; then
  printf '%s\n' "$ADMIN_STATE"
  exit 0
fi
if [[ "$url" == *'/v1/status' ]]; then
  if [[ "$CASE_NAME" == poc || "$CASE_NAME" == poc-probation ]]; then
    printf '%s\n' '{"devshards":[{"chain_phase":"PoCValidate"}]}'
  else
    printf '%s\n' '{"devshards":[{"chain_phase":"Inference"}]}'
  fi
  exit 0
fi
if [[ "$url" == *'preserved_nodes_snapshot' ]]; then
  if [[ "$CASE_NAME" == poc || "$CASE_NAME" == poc-probation ]]; then
    printf '%s\n' '{"snapshot":{"model_preserved_nodes":[{"model_id":"Qwen/Qwen3-0.6B","participants":[{"participant_id":"preserved"}]}]}}'
  else
    printf '%s\n' '{"snapshot":{"model_preserved_nodes":[]}}'
  fi
  exit 0
fi
if [[ "$url" == *'current_epoch_group_data' ]]; then
  printf '%s\n' '{"epoch_group_data":{"epoch_index":"42"}}'
  exit 0
fi
if [[ "$url" == *'devshard_escrow/'* ]]; then
  id="${url##*/}"
  case "${CASE_NAME}:${id}" in
    unknown:8) exit 7 ;;
    malformed:8) printf '%s\n' 'not-json' ;;
    pending:123) printf '%s\n' '{"found":false}' ;;
    pending-superseded:123) printf '%s\n' '{"found":false}' ;;
    pending-superseded:124|pending-superseded:125) printf '%s\n' "{\"found\":true,\"escrow\":{\"id\":\"$id\",\"settled\":false}}" ;;
    pending-routable:123) printf '%s\n' '{"found":true,"escrow":{"id":"123","settled":false}}' ;;
    manual-disabled:7) printf '%s\n' '{"found":true,"escrow":{"id":"7","settled":false}}' ;;
    inactive:7) printf '%s\n' '{"found":true,"escrow":{"id":"7","settled":false}}' ;;
    inactive:8) printf '%s\n' '{"found":true,"escrow":{"id":"8","settled":true}}' ;;
    inactive:9) printf '%s\n' '{"found":true,"escrow":{"id":"9","settled":false}}' ;;
    poc:7) printf '%s\n' '{"found":true,"escrow":{"id":"7","settled":false,"slots":["blocked"]}}' ;;
    poc:9|poc-probation:9) printf '%s\n' '{"found":true,"escrow":{"id":"9","settled":false,"slots":["preserved"]}}' ;;
    pool:7|pool:9) printf '%s\n' "{\"found\":true,\"escrow\":{\"id\":\"$id\",\"settled\":false}}" ;;
    nested-runtime:9) printf '%s\n' '{"found":true,"escrow":{"id":"9","settled":false}}' ;;
    *) exit 7 ;;
  esac
  exit 0
fi
if [[ "$url" == *'/v1/admin/escrows' ]]; then
  output=''
  previous=''
  for arg in "$@"; do
    [[ "$previous" == -o ]] && output="$arg"
    previous="$arg"
  done
  response='{"escrow_id":"9"}'
  [[ "$CASE_NAME" != creation-fails ]] || response='{}'
  if [[ -n "$output" && "$output" != /dev/null ]]; then
    printf '%s\n' "$response" >"$output"
  else
    printf '%s\n' "$response"
  fi
  exit 0
fi
if [[ "$url" == *'/v1/admin/settings' ]]; then
  if [[ "$CASE_NAME" == manual-disabled ]]; then
    printf '%s\n' '{"disabled":{"enabled":true}}'
  else
    printf '%s\n' '{"disabled":{"enabled":false}}'
  fi
  exit 0
fi
if [[ "$url" == *'/v1/admin/devshards/9/participants' && "$CASE_NAME" == poc-probation ]]; then
  recovery_count="$(cat "$CASE_DIR/recovery-count" 2>/dev/null || printf 0)"
  if (( recovery_count >= 2 )); then
    printf '%s\n' '{"participants":[{"participant_key":"preserved","probationary":false,"failure_strikes":0,"request_allowed":true,"quarantined":false,"blocked":false}]}'
  else
    printf '{"participants":[{"participant_key":"preserved","probationary":true,"failure_strikes":%s,"request_allowed":true,"quarantined":false,"blocked":false}]}\n' "$((2 - recovery_count))"
  fi
  exit 0
fi
if [[ "$url" == *'/v1/chat/completions' ]]; then
  output=''
  wants_status=false
  stream=false
  previous=''
  for arg in "$@"; do
    [[ "$previous" == -o ]] && output="$arg"
    [[ "$previous" == --data && "$arg" == *'"stream":true'* ]] && stream=true
    [[ "$arg" == -w ]] && wants_status=true
    previous="$arg"
  done
  if [[ "$stream" == true ]]; then
    recovery_count="$(cat "$CASE_DIR/recovery-count" 2>/dev/null || printf 0)"
    printf '%s\n' "$((recovery_count + 1))" >"$CASE_DIR/recovery-count"
    [[ -z "$output" || "$output" == /dev/null ]] || printf '%s\n\n%s\n\n' 'data: {"choices":[{"delta":{"content":"OK"}}]}' 'data: [DONE]' >"$output"
  else
    [[ -z "$output" || "$output" == /dev/null ]] || printf '%s\n' '{"choices":[{}]}' >"$output"
  fi
  if [[ "$wants_status" == true ]]; then printf 200; else printf '%s\n' '{"choices":[{}]}'; fi
  exit 0
fi
printf '%s\n' '{}'
EOF
  chmod +x "$case_dir/bin/curl"
  CASE_DIR="$case_dir" CASE_NAME="$name" ADMIN_STATE="$2" \
    PATH="$case_dir/bin:$PATH" \
    GDC_GATEWAY_ENV="$case_dir/gateway.env" \
    GDC_GATEWAY_RECONCILIATION_FILE="$case_dir/status.json" \
    GDC_GATEWAY_RECONCILIATION_LOCK="$case_dir/reconciler.lock" \
    GDC_GATEWAY_RESERVE_FILE="$case_dir/reserve.json" \
    GDC_GATEWAY_REPLACEMENT_ATTEMPT_FILE="$case_dir/replacement-attempt.json" \
    GDC_GATEWAY_RECONCILIATION_URL=http://gateway \
    GDC_GATEWAY_CHAIN_REST=http://chain \
    "$RECONCILER"
}

run_case unknown '{"devshards":[{"id":"8","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "RECOVERING" and .reason == "chain_escrow_query_unavailable"' "$WORK/unknown/status.json" >/dev/null
! grep -Eq '/deactivate|DELETE|/v1/admin/escrows' "$WORK/unknown/curl.log"

run_case malformed '{"devshards":[{"id":"8","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "RECOVERING" and .reason == "chain_escrow_query_unavailable"' "$WORK/malformed/status.json" >/dev/null
! grep -Eq '/deactivate|DELETE|/v1/admin/escrows' "$WORK/malformed/curl.log"

mkdir -p "$WORK/pending"
printf '%s\n' '{"state":"RECOVERING","reason":"waiting_for_chain_confirmation","replacement_escrow":"123","entered_at":"2026-08-10T08:00:00Z"}' >"$WORK/pending/status.json"
run_case pending '{"devshards":[{"id":"123","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "RECOVERING" and .reason == "waiting_for_chain_confirmation" and .replacement_escrow == "123" and .entered_at == "2026-08-10T08:00:00Z"' "$WORK/pending/status.json" >/dev/null
! grep -Eq '/deactivate|DELETE|/v1/admin/escrows' "$WORK/pending/curl.log"

# A newer runtime created by the gateway's own rotator supersedes an older
# recovery candidate. Probe the newest chain-valid runtime instead of waiting
# forever for the stale pending ID.
mkdir -p "$WORK/pending-superseded"
printf '%s\n' '{"state":"RECOVERING","reason":"waiting_for_chain_confirmation","replacement_escrow":"123"}' >"$WORK/pending-superseded/status.json"
run_case pending-superseded '{"devshards":[{"id":"123","active":true,"phase":"active","requests_blocked":false},{"id":"124","active":true,"phase":"active","requests_blocked":false},{"id":"125","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "READY" and .reason == "replacement_routable" and .replacement_escrow == "125"' "$WORK/pending-superseded/status.json" >/dev/null
grep -Fq '/devshard/125/v1/chat/completions' "$WORK/pending-superseded/curl.log"
! grep -Fq '/v1/admin/escrows' "$WORK/pending-superseded/curl.log"

# A replacement remains the same tracked escrow after chain confirmation.
# Reconciliation activates and probes it instead of funding another escrow.
mkdir -p "$WORK/pending-routable"
printf '%s\n' '{"state":"RECOVERING","reason":"waiting_for_routable_runtime","replacement_escrow":"123"}' >"$WORK/pending-routable/status.json"
run_case pending-routable '{"devshards":[{"id":"123","active":false,"phase":"inactive","requests_blocked":false}]}'
jq -e '.state == "READY" and .reason == "replacement_routable" and .replacement_escrow == "123"' "$WORK/pending-routable/status.json" >/dev/null
grep -Fq '/v1/admin/devshards/123/activate' "$WORK/pending-routable/curl.log"
! grep -Fq '/v1/admin/escrows' "$WORK/pending-routable/curl.log"

run_case inactive '{"devshards":[{"id":"7","active":false,"phase":"inactive","requests_blocked":false},{"id":"8","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "READY" and .reason == "replacement_routable" and .replacement_escrow == "9"' "$WORK/inactive/status.json" >/dev/null
grep -Fq '/v1/admin/escrows' "$WORK/inactive/curl.log"

# A terminal create failure is visible to systemd, stores only a sanitized
# classification, and consumes the one bounded attempt for this epoch. A
# repeated tick cannot mint a second escrow or report success.
set +e
run_case creation-fails '{"devshards":[]}'
creation_rc=$?
set -e
[[ "$creation_rc" == 1 ]]
jq -e '.state == "FAILED" and .reason == "replacement_escrow_creation_failed"' "$WORK/creation-fails/status.json" >/dev/null
jq -e '.state == "failed" and .failure_class == "invalid_response" and .generation == "epoch-42"' "$WORK/creation-fails/replacement-attempt.json" >/dev/null
set +e
run_case creation-fails '{"devshards":[]}'
limit_rc=$?
set -e
[[ "$limit_rc" == 1 ]]
jq -e '.state == "FAILED" and .reason == "replacement_attempt_limit_reached"' "$WORK/creation-fails/status.json" >/dev/null
[[ "$(grep -c '/v1/admin/escrows' "$WORK/creation-fails/curl.log")" == 1 ]]

run_case poc '{"devshards":[{"id":"7","active":true,"phase":"active","requests_blocked":false},{"id":"9","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "READY" and .replacement_escrow == "9"' "$WORK/poc/status.json" >/dev/null
grep -Fq '/v1/admin/devshards/7/deactivate' "$WORK/poc/curl.log"

# If every PoC-preserved participant is in probation, bounded streaming
# completions must restore a trusted winner before the canonical non-streaming
# readiness probe can publish READY.
run_case poc-probation '{"devshards":[{"id":"9","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "READY" and .replacement_escrow == "9"' "$WORK/poc-probation/status.json" >/dev/null
[[ "$(<"$WORK/poc-probation/recovery-count")" == 2 ]]
grep -Fq '"stream":true' "$WORK/poc-probation/curl.log"
grep -Fq '"max_tokens":1' "$WORK/poc-probation/curl.log"

# The external controller must not fight the gateway's built-in rotation
# controller. Both chain-valid runtimes remain active outside PoC, and no new
# escrow is created merely because the pool contains more than one entry.
run_case pool '{"devshards":[{"id":"7","active":true,"runtime":{"phase":"active","requests_blocked":false}},{"id":"9","active":true,"runtime":{"phase":"active","requests_blocked":false}}]}'
jq -e '.state == "READY" and .replacement_escrow == "9"' "$WORK/pool/status.json" >/dev/null
! grep -Eq '/deactivate|DELETE|/v1/admin/escrows' "$WORK/pool/curl.log"

# Current gateway responses place lifecycle fields in `runtime`.  This must
# keep the existing chain-valid escrow routable and must not create another
# escrow at every reconciliation tick.
run_case nested-runtime '{"devshards":[{"id":"9","active":true,"runtime":{"phase":"active","requests_blocked":false}}]}'
jq -e '.state == "READY" and .reason == "replacement_routable" and .replacement_escrow == "9"' "$WORK/nested-runtime/status.json" >/dev/null
! grep -Fq '/v1/admin/escrows' "$WORK/nested-runtime/curl.log"

# A manual admission shutdown is authoritative. The reconciler reports it and
# never silently reopens public traffic.
run_case manual-disabled '{"devshards":[{"id":"7","active":true,"runtime":{"phase":"active","requests_blocked":false}}]}'
jq -e '.state == "PENDING" and .reason == "gateway_admission_disabled" and .replacement_escrow == "7"' "$WORK/manual-disabled/status.json" >/dev/null
! grep -Fq '"disabled":{"enabled":false}' "$WORK/manual-disabled/curl.log"

# A shell payload in an operator-owned configuration must remain inert when
# the timer reads its credentials.
marker="$WORK/root-execution-marker"
printf 'DEVSHARD_ADMIN_API_KEY=$(touch %s)\n' "$marker" >"$WORK/malicious.env"
GDC_GATEWAY_ENV="$WORK/malicious.env" \
  GDC_GATEWAY_RECONCILIATION_FILE="$WORK/malicious-status.json" \
  GDC_GATEWAY_RECONCILIATION_LOCK="$WORK/malicious.lock" \
  "$RECONCILER"
[[ ! -e "$marker" ]]
jq -e '.state == "FAILED" and .reason == "gateway_credentials_incomplete"' "$WORK/malicious-status.json" >/dev/null

# A predictable legacy temporary symlink must not be followed.
protected="$WORK/protected-status-target"
printf 'unchanged\n' >"$protected"
mkdir -p "$WORK/symlink-status"
ln -s "$protected" "$WORK/symlink-status/status.json.tmp"
run_case symlink-status '{"devshards":[]}'
[[ "$(<"$protected")" == unchanged ]]

printf 'PASS gateway escrow reconciliation safety contract\n'
