#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
deploy="$tmp/deploy"; mkdir -p "$deploy" "$tmp/bin"
touch "$deploy/.env" "$deploy/compose.yaml"
cp "$ROOT/test/fixtures/join-lineage-preflight-state-sync.json" "$tmp/receipt.json"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${GDC_TEST_CANARY_CATCHING_UP:-false}" == true ]]; then
  printf '%s\n' '{"result":{"node_info":{"id":"0123456789abcdef0123456789abcdef01234567"},"sync_info":{"latest_block_height":"5000","catching_up":true}}}'
else
  printf '%s\n' '{"result":{"node_info":{"id":"0123456789abcdef0123456789abcdef01234567"},"sync_info":{"latest_block_height":"5000","catching_up":false}}}'
fi
EOF
chmod 0755 "$tmp/bin/docker"
PATH="$tmp/bin:$PATH" "$ROOT/02-node/record-state-sync-canary.sh" "$deploy" "$tmp/receipt.json" >"$tmp/out"
jq -e '
  .bootstrap.snapshot.discovery == "p2p_canary_caught_up"
  and .bootstrap.snapshot.canary_height == 5000
  and .bootstrap.snapshot.canary_node_id == "0123456789abcdef0123456789abcdef01234567"
  and .signer.state == "LINEAGE_VERIFIED"
  and .result.terminal_state == "canary_verified"
' "$tmp/receipt.json" >/dev/null
cp "$ROOT/test/fixtures/join-lineage-preflight-state-sync.json" "$tmp/pending.json"
if PATH="$tmp/bin:$PATH" GDC_TEST_CANARY_CATCHING_UP=true "$ROOT/02-node/record-state-sync-canary.sh" "$deploy" "$tmp/pending.json" >"$tmp/pending.out" 2>"$tmp/pending.err"; then
  echo 'catching-up canary unexpectedly produced a verified receipt' >&2; exit 1
fi
grep -Fq 'canary is still catching up' "$tmp/pending.err"
printf 'PASS JOIN records only an observed caught-up P2P canary receipt\n'
