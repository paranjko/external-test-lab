#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
endpoint=''
while (($#)); do
  case "$1" in
    --node-address) endpoint="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$endpoint" >>"$REGISTRATION_ENDPOINT_TRACE"
case "$endpoint" in
  https://one.example) echo 'Response status code: 502' >&2; exit 1 ;;
  https://two.example) echo 'Response status code: 503' >&2; exit 1 ;;
  https://three.example) echo 'Response status code: 200'; exit 0 ;;
  *) echo "unexpected endpoint: $endpoint" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker"

cat >"$tmp/node.env" <<'EOF'
IS_GENESIS=false
CONSENSUS_PUBKEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
PUBLIC_URL=https://joining.example
ACCOUNT_PUBKEY=account-public-key
GDC_JOIN_REGISTRATION_ENDPOINTS=https://one.example,https://two.example,https://three.example
EOF

PATH="$tmp/bin:$PATH" REGISTRATION_ENDPOINT_TRACE="$tmp/trace" \
  "$ROOT/03-join/register-participant.sh" "$tmp/node.env" >"$tmp/out" 2>"$tmp/err"
cmp -s "$tmp/trace" <(printf '%s\n' https://one.example https://two.example https://three.example)
printf 'PASS participant registration fails over bootstrap endpoints\n'
