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
if [[ "$url" == *'devshard_escrow/'* ]]; then
  id="${url##*/}"
  case "${CASE_NAME}:${id}" in
    unknown:8) exit 7 ;;
    pending:123) printf '%s\n' '{"found":false}' ;;
    inactive:7) printf '%s\n' '{"found":true,"escrow":{"id":"7","settled":false}}' ;;
    inactive:8) printf '%s\n' '{"found":true,"escrow":{"id":"8","settled":true}}' ;;
    inactive:9) printf '%s\n' '{"found":true,"escrow":{"id":"9","settled":false}}' ;;
    *) exit 7 ;;
  esac
  exit 0
fi
if [[ "$url" == *'/v1/admin/escrows' ]]; then
  printf '%s\n' '{"escrow_id":"9"}'
  exit 0
fi
if [[ "$url" == *'/v1/chat/completions' ]]; then
  output=''
  wants_status=false
  previous=''
  for arg in "$@"; do
    [[ "$previous" == -o ]] && output="$arg"
    [[ "$arg" == -w ]] && wants_status=true
    previous="$arg"
  done
  [[ -z "$output" || "$output" == /dev/null ]] || printf '%s\n' '{"choices":[{}]}' >"$output"
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
    GDC_GATEWAY_RECONCILIATION_URL=http://gateway \
    GDC_GATEWAY_CHAIN_REST=http://chain \
    "$RECONCILER"
}

run_case unknown '{"devshards":[{"id":"8","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "RECOVERING" and .reason == "chain_escrow_query_unavailable"' "$WORK/unknown/status.json" >/dev/null
! grep -Eq '/deactivate|DELETE|/v1/admin/escrows' "$WORK/unknown/curl.log"

mkdir -p "$WORK/pending"
printf '%s\n' '{"state":"RECOVERING","reason":"waiting_for_chain_confirmation","replacement_escrow":"123"}' >"$WORK/pending/status.json"
run_case pending '{"devshards":[{"id":"123","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "RECOVERING" and .reason == "waiting_for_chain_confirmation" and .replacement_escrow == "123"' "$WORK/pending/status.json" >/dev/null
! grep -Eq '/deactivate|DELETE|/v1/admin/escrows' "$WORK/pending/curl.log"

run_case inactive '{"devshards":[{"id":"7","active":false,"phase":"inactive","requests_blocked":false},{"id":"8","active":true,"phase":"active","requests_blocked":false}]}'
jq -e '.state == "READY" and .reason == "replacement_routable" and .replacement_escrow == "9"' "$WORK/inactive/status.json" >/dev/null
grep -Fq '/v1/admin/escrows' "$WORK/inactive/curl.log"

# A shell payload in an operator-owned configuration must remain inert when
# the root-owned timer reads its credentials.
marker="$WORK/root-execution-marker"
printf 'DEVSHARD_ADMIN_API_KEY=$(touch %s)\n' "$marker" >"$WORK/malicious.env"
GDC_GATEWAY_ENV="$WORK/malicious.env" \
  GDC_GATEWAY_RECONCILIATION_FILE="$WORK/malicious-status.json" \
  GDC_GATEWAY_RECONCILIATION_LOCK="$WORK/malicious.lock" \
  "$RECONCILER"
[[ ! -e "$marker" ]]
jq -e '.state == "FAILED" and .reason == "gateway_credentials_incomplete"' "$WORK/malicious-status.json" >/dev/null

printf 'PASS gateway escrow reconciliation safety contract\n'
