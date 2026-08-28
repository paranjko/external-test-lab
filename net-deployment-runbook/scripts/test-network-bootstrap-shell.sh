#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/network-bootstrap.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bootstrap="$tmp/bootstrap.json"
genesis="$tmp/genesis.json"
printf '%s\n' '{"chain_id":"gonka-fixture","genesis":{"sha256":"__SHA__"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://one.example/chain-rpc","p2p":"tcp://one.example:5000","api":"https://one.example"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://two.example/chain-rpc","p2p":"tcp://two.example:5000"}],"brokers":[{"api_urls":["https://broker.example/v1"]}],"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json"}' >"$bootstrap"
printf '%s\n' '{"chain_id":"gonka-fixture"}' >"$genesis"
digest="$(sha256sum "$genesis" | awk '{print $1}')"
sed -i "s/__SHA__/$digest/" "$bootstrap"

"$TOOL" verify "$bootstrap" >"$tmp/verify"
grep -Fq 'PASS offline network bootstrap' "$tmp/verify"
"$TOOL" env "$bootstrap" >"$tmp/bootstrap.env"
grep -Fq 'export SEED_NODE_RPC_URL=https://one.example/chain-rpc' "$tmp/bootstrap.env"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/inferenced" <<'EOF'
#!/usr/bin/env bash
cp "$BOOTSTRAP_TEST_GENESIS" "$3"
EOF
chmod 0755 "$tmp/bin/inferenced"
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$genesis" "$TOOL" stage "$bootstrap" "$tmp/stage" >"$tmp/stage.out"
cmp -s "$genesis" "$tmp/stage/genesis.json"
[[ "$(stat -c '%a' "$tmp/stage/genesis.json")" == 600 ]]

if INFERENCED=missing-inferenced "$TOOL" stage "$bootstrap" "$tmp/missing-cli-stage" >"$tmp/missing-cli.out" 2>"$tmp/missing-cli.err"; then
  echo 'bootstrap staging unexpectedly worked without inferenced' >&2
  exit 1
fi
grep -Fq 'stage=dependency field=inferenced' "$tmp/missing-cli.err"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
cp "$BOOTSTRAP_TEST_DOCUMENT" "$output"
printf '200'
EOF
cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
echo 'python3 must not be called by the operator bootstrap path' >&2
exit 127
EOF
chmod 0755 "$tmp/bin/curl" "$tmp/bin/python3"
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_DOCUMENT="$bootstrap" "$ROOT/scripts/fetch-network-bootstrap.sh" --url https://bootstrap.example/bootstrap.json --output "$tmp/fetched.json" >"$tmp/fetch.out"
cmp -s "$bootstrap" "$tmp/fetched.json"
grep -Fq 'PASS downloaded and validated network bootstrap' "$tmp/fetch.out"

printf '%s\n' '{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","$schema":"https://gonka-dev.net/v1.bootstrap.schema.json"}' >"$tmp/duplicate.json"
if "$TOOL" verify "$tmp/duplicate.json" >/dev/null 2>&1; then
  echo 'duplicate bootstrap keys unexpectedly validated' >&2
  exit 1
fi
printf 'PASS operator bootstrap shell path has no Python dependency\n'
