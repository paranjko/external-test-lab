#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
deploy="$tmp/deploy"
mkdir -p "$deploy" "$tmp/bin"
touch "$deploy/.env" "$deploy/compose.yaml"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GDC_DOCKER_LOG"
cat <<'CONFIG'
enable = true
rpc_servers = "https://rpc-a.example.test/chain-rpc/,https://rpc-b.example.test/chain-rpc/"
trust_height = 3000
trust_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
persistent_peers = "0123456789abcdef0123456789abcdef01234567@rpc-a.example.test:5000,89abcdef0123456789abcdef0123456789abcdef@rpc-b.example.test:5000"
CONFIG
EOF
chmod 0755 "$tmp/bin/docker"
write_receipt() {
  jq -n --arg expires "$1" '{bootstrap:{trust:{height:3000,block_id:("a" * 64),expires_at:$expires},snapshot:{providers:["0123456789abcdef0123456789abcdef01234567@tcp://rpc-a.example.test:5000","89abcdef0123456789abcdef0123456789abcdef@tcp://rpc-b.example.test:5000"]}},fault_domains:[{rpc_url:"https://rpc-a.example.test/chain-rpc"},{rpc_url:"https://rpc-b.example.test/chain-rpc"}]}' >"$tmp/receipt.json"
}
write_receipt 2999-01-01T00:00:00Z
PATH="$tmp/bin:$PATH" GDC_DOCKER_LOG="$tmp/docker.log" "$ROOT/02-node/verify-state-sync-config.sh" "$deploy" "$tmp/receipt.json" >"$tmp/valid.out"
grep -Fq 'PASS signerless canary config matches receipt trust and P2P providers' "$tmp/valid.out"
write_receipt 2000-01-01T00:00:00Z
: >"$tmp/docker.log"
if PATH="$tmp/bin:$PATH" GDC_DOCKER_LOG="$tmp/docker.log" "$ROOT/02-node/verify-state-sync-config.sh" "$deploy" "$tmp/receipt.json" >"$tmp/expired.out" 2>"$tmp/expired.err"; then
  echo 'expired trust unexpectedly reached state-sync config verification' >&2; exit 1
fi
grep -Fq 'lineage_trust_expired:' "$tmp/expired.err"
[[ ! -s "$tmp/docker.log" ]] || { echo 'expired trust reached Docker before rejection' >&2; exit 1; }
printf 'PASS state-sync configuration rejects expired lineage trust before canary acceptance\n'
