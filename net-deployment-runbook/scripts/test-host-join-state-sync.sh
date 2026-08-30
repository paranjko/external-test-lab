#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/receipt.json" <<'EOF'
{"bootstrap":{"trust":{"expires_at":"2099-01-01T00:00:00Z"}},"checkpoints":{"early":{"height":5,"block_id":"1111111111111111111111111111111111111111111111111111111111111111","app_hash":"2222222222222222222222222222222222222222222222222222222222222222"},"post_upgrade":{"height":101,"block_id":"3333333333333333333333333333333333333333333333333333333333333333","app_hash":"4444444444444444444444444444444444444444444444444444444444444444"},"trust":{"height":3000,"block_id":"5555555555555555555555555555555555555555555555555555555555555555","app_hash":"6666666666666666666666666666666666666666666666666666666666666666"}}}
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${!#}" in
  *height=5) printf '%s\n' '{"result":{"block_id":{"hash":"1111111111111111111111111111111111111111111111111111111111111111"},"block":{"header":{"height":"5","app_hash":"2222222222222222222222222222222222222222222222222222222222222222"}}}}' ;;
  *height=101)
    app=4444444444444444444444444444444444444444444444444444444444444444
    [[ "${GDC_TEST_BAD_APPHASH:-false}" != true ]] || app=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf '{"result":{"block_id":{"hash":"3333333333333333333333333333333333333333333333333333333333333333"},"block":{"header":{"height":"101","app_hash":"%s"}}}}\n' "$app"
    ;;
  *height=3000) printf '%s\n' '{"result":{"block_id":{"hash":"5555555555555555555555555555555555555555555555555555555555555555"},"block":{"header":{"height":"3000","app_hash":"6666666666666666666666666666666666666666666666666666666666666666"}}}}' ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$tmp/receipt.json" >"$tmp/out"
grep -Fq 'PASS JOIN lineage checkpoints match' "$tmp/out"
if PATH="$tmp/bin:$PATH" GDC_TEST_BAD_APPHASH=true "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$tmp/receipt.json" >"$tmp/divergence.out" 2>"$tmp/divergence.err"; then
  echo 'AppHash divergence unexpectedly verified' >&2; exit 1
fi
grep -Fq 'apphash_divergence:' "$tmp/divergence.err"
sed 's/2099-01-01/2000-01-01/' "$tmp/receipt.json" >"$tmp/expired.json"
if PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$tmp/expired.json" >"$tmp/expired.out" 2>"$tmp/expired.err"; then
  echo 'expired lineage receipt unexpectedly verified' >&2; exit 1
fi
grep -Fq 'trust_expired:' "$tmp/expired.err"
grep -Fq 'SYNC_WITH_SNAPSHOTS=$([[' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'GDC_JOIN_RPC_SERVER_1' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'SEED_NODE_RPC_URL=${GDC_JOIN_RPC_SERVER_1:-https://$GENESIS_PUBLIC_HOST/chain-rpc/}' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'verify-join-lineage-state.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'gdc-stage.XXXXXX' "$ROOT/02-node/install-node.sh"
grep -Fq 'docker compose --env-file "$STAGE/.env" -f "$STAGE/compose.yaml" config --quiet' "$ROOT/02-node/install-node.sh"
grep -Fq 'mv "$STAGE" "$DEST"' "$ROOT/02-node/install-node.sh"
grep -Fq 'mv "$BACKUP" "$DEST"' "$ROOT/02-node/install-node.sh"
printf 'PASS JOIN state sync renders independent RPCs and verifies checkpoints\n'
