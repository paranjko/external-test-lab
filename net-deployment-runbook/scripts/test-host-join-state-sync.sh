#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/receipt.json" <<'EOF'
{"bootstrap":{"trust":{"height":3000}},"fault_domains":[{"rpc_url":"https://rpc-a.example.test/chain-rpc"},{"rpc_url":"https://rpc-b.example.test/chain-rpc"}]}
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  */status) printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"5000"}}}' ;;
  *height=5000)
    app=2222222222222222222222222222222222222222222222222222222222222222
    if [[ "${GDC_TEST_BAD_APPHASH:-false}" == true && "$url" == *join.example.test* ]]; then
      app=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    fi
    printf '{"result":{"block_id":{"hash":"1111111111111111111111111111111111111111111111111111111111111111"},"block":{"header":{"height":"5000","app_hash":"%s"}}}}\n' "$app"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$tmp/receipt.json" >"$tmp/out"
grep -Fq 'PASS JOIN fresh post-sync checkpoint matches' "$tmp/out"
if PATH="$tmp/bin:$PATH" GDC_TEST_BAD_APPHASH=true "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$tmp/receipt.json" >"$tmp/divergence.out" 2>"$tmp/divergence.err"; then
  echo 'fresh AppHash divergence unexpectedly verified' >&2; exit 1
fi
grep -Fq 'apphash_divergence:' "$tmp/divergence.err"
grep -Fq 'CONFIG_statesync__trust_height' "$ROOT/02-node/compose.yaml"
grep -Fq 'CONFIG_statesync__trust_hash' "$ROOT/02-node/compose.yaml"
grep -Fq 'CONFIG_statesync__rpc_servers' "$ROOT/02-node/compose.yaml"
grep -Fq 'CONFIG_p2p__persistent_peers' "$ROOT/02-node/compose.yaml"
grep -Fq 'GDC_JOIN_SNAPSHOT_PEERS' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'verify-join-lineage-state.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'gdc-stage.XXXXXX' "$ROOT/02-node/install-node.sh"
printf 'PASS JOIN pins receipt trust and verifies a fresh post-sync checkpoint\n'
