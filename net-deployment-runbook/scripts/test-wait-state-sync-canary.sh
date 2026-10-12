#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
deploy="$tmp/deploy"
mkdir -p "$deploy" "$tmp/bin"
touch "$deploy/.env" "$deploy/compose.yaml"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
printf '%s\n' "$url" >>"${GDC_TEST_CURL_LOG:?}"
case "$url" in
  http://127.0.0.1:26657/status)
    state="${GDC_TEST_CANARY_STATE:?}"
    attempt="$(<"$state")"
    if [[ "$attempt" == 0 ]]; then
      printf '1\n' >"$state"
      printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"4980","catching_up":true}}}'
    elif [[ "$attempt" == 1 ]]; then
      printf '2\n' >"$state"
      printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"4990","catching_up":true}}}'
    else
      printf '%s\n' "{\"result\":{\"sync_info\":{\"latest_block_height\":\"${GDC_TEST_CANARY_LOCAL_HEIGHT:-5001}\",\"catching_up\":false}}}"
    fi
    ;;
  https://seed.example.test/chain-rpc/status)
    attempt="$(<"${GDC_TEST_CANARY_STATE:?}")"
    reference_height=5000
    if [[ "$attempt" == 2 && -n "${GDC_TEST_REFERENCE_SECOND_HEIGHT:-}" ]]; then
      reference_height="$GDC_TEST_REFERENCE_SECOND_HEIGHT"
    fi
    printf '%s\n' "{\"result\":{\"sync_info\":{\"latest_block_height\":\"$reference_height\",\"catching_up\":false}}}"
    ;;
  *) exit 22 ;;
esac
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exec /bin/sleep "${GDC_TEST_SLEEP_SECONDS:-0}"
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo 'wait-state-sync-canary must not require an in-container curl binary' >&2
exit 97
EOF
chmod 0755 "$tmp/bin/curl" "$tmp/bin/docker" "$tmp/bin/sleep"
printf '0\n' >"$tmp/canary-attempt"
PATH="$tmp/bin:$PATH" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_TEST_CANARY_STATE="$tmp/canary-attempt" GDC_TEST_SLEEP_SECONDS=1 \
  "$ROOT/02-node/wait-state-sync-canary.sh" "$deploy" https://seed.example.test/chain-rpc >"$tmp/out"
grep -Fq 'PASS signerless state-sync canary caught up height=5001 reference=5000 lag=-1' "$tmp/out"
grep -Eq '^WAIT signerless P2P canary syncing local_height=4980 reference_height=5000 lag=20 catching_up=true elapsed_seconds=[0-9]+ remaining_seconds=[0-9]+$' "$tmp/out"
progress_seen=false
while IFS= read -r line; do
  case "$line" in
    'WAIT signerless P2P canary progress local_delta=10 reference_delta=0 net_delta=10 state=advancing rate_blocks_per_minute='[1-9]*' estimated_remaining_seconds='[1-9]*)
      progress_seen=true
      ;;
  esac
done <"$tmp/out"
if [[ "$progress_seen" != true ]]; then
  echo 'canary wait did not report advancing catch-up progress and an ETA' >&2
  sed -n '1,40p' "$tmp/out" >&2
  exit 1
fi
grep -Fxq 'http://127.0.0.1:26657/status' "$tmp/curl.log"
if PATH="$tmp/bin:$PATH" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_JOIN_SYNC_TIMEOUT_SECONDS=3 GDC_JOIN_CANARY_MAX_LAG_BLOCKS=5 GDC_TEST_SLEEP_SECONDS=1 \
  GDC_TEST_CANARY_STATE="$tmp/canary-attempt" GDC_TEST_CANARY_LOCAL_HEIGHT=4990 "$ROOT/02-node/wait-state-sync-canary.sh" "$deploy" https://seed.example.test/chain-rpc >"$tmp/lag.out" 2>"$tmp/lag.err"; then
  echo 'canary beyond lag bound unexpectedly verified' >&2; exit 1
fi
grep -Fq 'exceeded lag bound' "$tmp/lag.err"
stalled_seen=false
while IFS= read -r line; do
  case "$line" in
    'WAIT signerless P2P canary progress local_delta=0 reference_delta=0 net_delta=0 state=stalled rate_blocks_per_minute=unknown estimated_remaining_seconds=unknown')
      stalled_seen=true
      ;;
  esac
done <"$tmp/lag.out"
if [[ "$stalled_seen" != true ]]; then
  echo 'canary wait did not identify a stalled catch-up attempt' >&2
  sed -n '1,40p' "$tmp/lag.out" >&2
  exit 1
fi
printf '0\n' >"$tmp/canary-attempt"; : >"$tmp/events"
if PATH="$tmp/bin:$PATH" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_JOIN_SYNC_TIMEOUT_SECONDS=3 GDC_JOIN_CANARY_MAX_LAG_BLOCKS=5 GDC_TEST_SLEEP_SECONDS=1 \
  GDC_TEST_CANARY_STATE="$tmp/canary-attempt" GDC_TEST_CANARY_LOCAL_HEIGHT=4990 GDC_TEST_REFERENCE_SECOND_HEIGHT=5015 "$ROOT/02-node/wait-state-sync-canary.sh" "$deploy" https://seed.example.test/chain-rpc >"$tmp/falling.out" 2>"$tmp/falling.err"; then
  echo 'canary falling behind unexpectedly verified' >&2
  exit 1
fi
falling_seen=false
while IFS= read -r line; do
  case "$line" in
    'WAIT signerless P2P canary progress local_delta=10 reference_delta=15 net_delta=-5 state=falling_behind rate_blocks_per_minute=unknown estimated_remaining_seconds=unknown')
      falling_seen=true
      ;;
  esac
done <"$tmp/falling.out"
if [[ "$falling_seen" != true ]]; then
  echo 'canary wait did not identify a reference chain that is pulling ahead' >&2
  sed -n '1,40p' "$tmp/falling.out" >&2
  exit 1
fi
if ! grep -Fq 'last_local_height=4990 last_reference_height=5000 last_lag=10 last_catching_up=false' "$tmp/lag.err"; then
  echo 'canary timeout omitted its final observed progress' >&2
  sed -n '1,20p' "$tmp/lag.out" >&2
  sed -n '1,20p' "$tmp/lag.err" >&2
  sed -n '1,20p' "$tmp/curl.log" >&2
  exit 1
fi
printf 'PASS signerless canary status is read from the Host loopback RPC\n'
