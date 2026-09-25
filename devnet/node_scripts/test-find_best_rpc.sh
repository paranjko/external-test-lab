#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/bin"
cat >"$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '+%s%3N' ]]; then
  exec /bin/date '+%s%N'
fi
exec /bin/date "$@"
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
  */chain-rpc/status)
    printf '%s\n' '{"result":{"sync_info":{"catching_up":false,"latest_block_height":"100"}}}' ;;
  */chain-rpc/net_info)
    printf '%s\n' '{"result":{"peers":[],"n_peers":"5"}}' ;;
  */chain-rpc/validators)
    printf '%s\n' '{"result":{"validators":[{}]}}' ;;
  */chain-rpc/block)
    printf '{"result":{"block":{"header":{"time":"%s"}}}}\n' "$(/bin/date -u +%FT%TZ)" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/date" "$tmp/bin/curl"

PATH="$tmp/bin:$PATH" bash "$ROOT/find_best_rpc.sh" >"$tmp/output"
grep -Fq 'RPC_SERVER_URL_1=http://' "$tmp/output"
awk '
  $1 ~ /^http:\/\// && NF == 4 {
    found = 1
    if ($4 < 0 || $4 > 10000) exit 1
  }
  END { if (!found) exit 1 }
' "$tmp/output"

printf 'PASS RPC latency uses milliseconds with uutils-style date\n'
