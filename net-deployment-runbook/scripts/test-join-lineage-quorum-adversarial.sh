#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-fixture","genesis":{"sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://rpc-a.example.test/chain-rpc","p2p":"tcp://rpc-a.example.test:5000","api":"https://rpc-a.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://rpc-b.example.test/chain-rpc","p2p":"tcp://rpc-b.example.test:5000","api":"https://rpc-b.example.test"},{"node_id":"1111111111111111111111111111111111111111","rpc":"https://rpc-c.example.test/chain-rpc","p2p":"tcp://rpc-c.example.test:5000","api":"https://rpc-c.example.test"},{"node_id":"2222222222222222222222222222222222222222","rpc":"https://rpc-d.example.test/chain-rpc","p2p":"tcp://rpc-d.example.test:5000","api":"https://rpc-d.example.test"}],"brokers":[]}
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
url="${!#}"; host="${url#https://}"; host="${host%%.*}"
[[ "$MODE" != unavailable || "$host" != rpc-c ]] || exit 22
height=5000
[[ "$MODE" != ahead || "$host" != rpc-c ]] || height=100000
case "$url" in
  */status) printf '{"result":{"node_info":{"network":"gonka-fixture"},"sync_info":{"latest_block_height":"%s"}}}\n' "$height" ;;
  */last_upgrade_height) printf '%s\n' '{"lastUpgradeHeight":"100","found":true}' ;;
  */chain-api/productscience/inference/inference/params)
    printf '%s\n' '{"params":{"devshard_escrow_params":{"approved_versions":[{"name":"v3","binary":"https://downloads.example.test/devshard-v3","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}}'
    ;;
  */block?height=*)
    h="${url##*=}"; [[ "$MODE" != incomplete || "$host" != rpc-c || "$h" != 5000 ]] || exit 22
    block=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    app=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    if [[ "$MODE" == aabc && "$host" == rpc-c ]]; then block=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc; fi
    if [[ "$MODE" == aabc && "$host" == rpc-d ]]; then block=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd; fi
    [[ "$h" == 5 ]] && block=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    [[ "$h" == 3000 ]] && block=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    [[ "$h" == 101 ]] && block=9999999999999999999999999999999999999999999999999999999999999999
    printf '{"result":{"block_id":{"hash":"%s"},"block":{"header":{"height":"%s","app_hash":"%s"}}}}\n' "$block" "$h" "$app"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"
run() { PATH="$tmp/bin:$PATH" MODE="$1" GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=a,rpc-b.example.test=b,rpc-c.example.test=c,rpc-d.example.test=d' "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --composition-env "$tmp/composition.env" --receipt "$tmp/$1.json" --env "$tmp/$1.env"; }
run ahead
run unavailable
run incomplete
if run aabc >"$tmp/aabc.out" 2>"$tmp/aabc.err"; then
  echo 'A,A,B,C quorum unexpectedly passed' >&2; exit 1
fi
grep -Fq 'lineage_rpc_quorum_conflict:' "$tmp/aabc.err"
printf 'PASS lineage quorum ignores one ahead or unavailable non-voter and rejects A,A,B,C\n'
