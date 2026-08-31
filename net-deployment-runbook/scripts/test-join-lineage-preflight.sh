#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-fixture","genesis":{"sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://rpc-a.example.test/chain-rpc","p2p":"tcp://rpc-a.example.test:5000","api":"https://rpc-a.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://rpc-b.example.test/chain-rpc","p2p":"tcp://rpc-b.example.test:5000","api":"https://rpc-b.example.test"},{"node_id":"fedcba9876543210fedcba9876543210fedcba98","rpc":"https://rpc-stale.example.test/chain-rpc","p2p":"tcp://rpc-stale.example.test:5000","api":"https://rpc-stale.example.test"}],"brokers":[]}
EOF
cat >"$tmp/composition.env" <<'EOF'
GDC_NETWORK_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
GDC_NETWORK_CHAIN_ID=gonka-fixture
GDC_NETWORK_GENESIS_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
GDC_NETWORK_CORE_VERSION=0.2.15
GDC_NETWORK_CORE_COMMIT=4d687ed6782bcea3931d2d9135bf322f84e190ab
GDC_NETWORK_DAPI_VERSION=0.2.15-post3
GDC_NETWORK_DAPI_COMMIT=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0
GDC_RELEASE_PROFILE=v2026.08.06
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
block() {
  local height="$1" block app
  case "$height" in
    5) block=1111111111111111111111111111111111111111111111111111111111111111; app=2222222222222222222222222222222222222222222222222222222222222222 ;;
    3000) block=3333333333333333333333333333333333333333333333333333333333333333; app=4444444444444444444444444444444444444444444444444444444444444444 ;;
    101) block=5555555555555555555555555555555555555555555555555555555555555555; app=6666666666666666666666666666666666666666666666666666666666666666 ;;
    *) exit 22 ;;
  esac
  printf '{"result":{"block_id":{"hash":"%s"},"block":{"header":{"height":"%s","app_hash":"%s"}}}}\n' "$block" "$height" "$app"
}
case "$url" in
  *rpc-stale.example.test*/status) printf '%s\n' '{"result":{"node_info":{"network":"gonka-fixture"},"sync_info":{"latest_block_height":"4"}}}' ;;
  */status) printf '%s\n' '{"result":{"node_info":{"network":"gonka-fixture"},"sync_info":{"latest_block_height":"5000"}}}' ;;
  */applied_plan/v0.2.15) printf '%s\n' '{"height":"100"}' ;;
  */block?height=*) block "${url##*=}" ;;
  */snapshots)
    [[ "${GDC_TEST_NO_SNAPSHOT:-false}" != true ]] || exit 22
    printf '%s\n' '{"result":{"snapshots":[{"height":200,"format":1,"chunks":2,"hash":"7777777777777777777777777777777777777777777777777777777777777777"}]}}'
    ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"

run_preflight() {
  PATH="$tmp/bin:$PATH" GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=domain-a,rpc-b.example.test=domain-b,rpc-stale.example.test=domain-stale' \
    "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --composition-env "$tmp/composition.env" --receipt "$tmp/receipt.json" --env "$tmp/lineage.env"
}
run_preflight >"$tmp/out"
jq -e '
  .runtime.observed_runtime_profile == "v2026.08.06" and
  .bootstrap.mode == "state_sync" and .bootstrap.snapshot.height == 200 and
  (.fault_domains | length == 2) and .signer.state == "PREPARED" and
  .result.terminal_state == "prepared"
' "$tmp/receipt.json" >/dev/null
grep -qx 'GDC_JOIN_BOOTSTRAP_MODE=state_sync' "$tmp/lineage.env"
grep -qx 'GDC_JOIN_RPC_SERVER_1=https://rpc-a.example.test/chain-rpc/' "$tmp/lineage.env"

if PATH="$tmp/bin:$PATH" GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=one,rpc-b.example.test=one,rpc-stale.example.test=one' \
  "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --composition-env "$tmp/composition.env" --receipt "$tmp/alias.json" --env "$tmp/alias.env" >"$tmp/alias.out" 2>"$tmp/alias.err"; then
  echo 'two aliases for one RPC fault domain unexpectedly passed' >&2; exit 1
fi
grep -Fq 'lineage_rpc_fault_domain_alias:' "$tmp/alias.err"

if PATH="$tmp/bin:$PATH" GDC_TEST_NO_SNAPSHOT=true GDC_JOIN_LINEAGE_FAILURE_FILE="$tmp/failure.category" GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=domain-a,rpc-b.example.test=domain-b,rpc-stale.example.test=domain-stale' \
  "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --composition-env "$tmp/composition.env" --receipt "$tmp/missing.json" --env "$tmp/missing.env" >"$tmp/missing.out" 2>"$tmp/missing.err"; then
  echo 'missing state-sync snapshot unexpectedly passed' >&2; exit 1
fi
grep -Fq 'lineage_snapshot_unavailable:' "$tmp/missing.err"
grep -qx snapshot_unavailable "$tmp/failure.category"
printf 'PASS JOIN lineage preflight requires independent RPCs and a compatible snapshot\n'
