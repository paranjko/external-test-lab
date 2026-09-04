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
    printf '%s\n' "{\"result\":{\"sync_info\":{\"latest_block_height\":\"${GDC_TEST_CANARY_LOCAL_HEIGHT:-5001}\",\"catching_up\":false}}}"
    ;;
  https://seed.example.test/chain-rpc/status)
    printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"5000","catching_up":false}}}'
    ;;
  *) exit 22 ;;
esac
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo 'wait-state-sync-canary must not require an in-container curl binary' >&2
exit 97
EOF
chmod 0755 "$tmp/bin/curl" "$tmp/bin/docker"
PATH="$tmp/bin:$PATH" GDC_TEST_CURL_LOG="$tmp/curl.log" \
  "$ROOT/02-node/wait-state-sync-canary.sh" "$deploy" https://seed.example.test/chain-rpc >"$tmp/out"
grep -Fq 'PASS signerless state-sync canary caught up height=5001 reference=5000 lag=-1' "$tmp/out"
grep -Fxq 'http://127.0.0.1:26657/status' "$tmp/curl.log"
if PATH="$tmp/bin:$PATH" GDC_JOIN_SYNC_TIMEOUT_SECONDS=0 GDC_JOIN_CANARY_MAX_LAG_BLOCKS=5 \
  GDC_TEST_CANARY_LOCAL_HEIGHT=4990 "$ROOT/02-node/wait-state-sync-canary.sh" "$deploy" https://seed.example.test/chain-rpc >"$tmp/lag.out" 2>"$tmp/lag.err"; then
  echo 'canary beyond lag bound unexpectedly verified' >&2; exit 1
fi
grep -Fq 'exceeded lag bound' "$tmp/lag.err"
printf 'PASS signerless canary status is read from the Host loopback RPC\n'
