#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBSERVE="$ROOT/scripts/observe-network-composition.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"},{"node_id":"fedcba9876543210fedcba9876543210fedcba98","rpc":"https://node2.example.test/chain-rpc","p2p":"tcp://node2.example.test:5000","api":"https://node2.example.test"},{"node_id":"76543210fedcba9876543210fedcba9876543210","rpc":"https://node3.example.test/chain-rpc","p2p":"tcp://node3.example.test:5000","api":"https://node3.example.test"}],"brokers":[]}
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  *node0.example.test*) node=0; id=0123456789abcdef0123456789abcdef01234567 ;;
  *node1.example.test*) node=1; id=89abcdef0123456789abcdef0123456789abcdef ;;
  *node2.example.test*) node=2; id=fedcba9876543210fedcba9876543210fedcba98 ;;
  *node3.example.test*) node=3; id=76543210fedcba9876543210fedcba9876543210 ;;
  *) exit 2 ;;
esac
[[ "${MODE:-good}" != one_seed || "$node" == 0 ]] || exit 7
chain=gonka-devnet-community
[[ "${MODE:-good}" != wrong_chain || "$node" != 1 ]] || chain=other-chain
version=0.2.15
cometbft_version=0.38.19
commit=4d687ed6782bcea3931d2d9135bf322f84e190ab
[[ "${MODE:-good}" != conflict || "$node" != 1 ]] || { version=0.2.14; commit=2bfd85c958732992c7a9c5be1d796affe29f3ab4; }
[[ "${MODE:-good}" != unknown ]] || { version=9.9.9; commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
case "$url" in
  */status) printf '{"result":{"node_info":{"id":"%s","network":"%s","version":"%s"}}}\n' "$id" "$chain" "$cometbft_version" ;;
  */abci_info) printf '{"result":{"response":{"version":"%s"}}}\n' "$version" ;;
  */v1/versions)
    [[ "${MODE:-good}" != incomplete || "$node" != 1 ]] || { printf '{"node_version":{"version":"0.2.14"}}\n'; exit 0; }
    api_node_version="$version"; api_node_commit="$commit"
    [[ "${MODE:-good}" != api_mismatch || "$node" != 1 ]] || { api_node_version=0.2.14; api_node_commit=2bfd85c958732992c7a9c5be1d796affe29f3ab4; }
    printf '{"node_version":{"version":"%s","commit":"%s"},"api_version":{"version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}}\n' "$api_node_version" "$api_node_commit"
    ;;
  */chain-api/productscience/inference/inference/params)
    approvals='[{"name":"v3","binary":"https://example.test/devshard-v3.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"v4","binary":"https://example.test/devshard-v4.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},{"name":"v5","binary":"https://example.test/devshard-v5.zip","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]'
    [[ "${MODE:-good}" != reordered || "$node" != 1 ]] || approvals='[{"name":"v5","binary":"https://example.test/devshard-v5.zip","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},{"name":"v3","binary":"https://example.test/devshard-v3.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"v4","binary":"https://example.test/devshard-v4.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
    [[ "${MODE:-good}" != approval_outlier || "$node" != 3 ]] || approvals='[]'
    if [[ "${MODE:-good}" == conflicting_approvals && "$node" -ge 2 ]]; then
      approvals='[{"name":"v3","binary":"https://example.test/devshard-v3.zip","sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}]'
    fi
    [[ "${MODE:-good}" != malformed_approval || "$node" != 1 ]] || approvals='[{"name":"v3","binary":"http://example.test/devshard-v3.zip","sha256":"not-a-sha"}]'
    [[ "${MODE:-good}" != duplicate_approval || "$node" != 1 ]] || approvals='[{"name":"v3","binary":"https://example.test/a.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"v3","binary":"https://example.test/b.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
    printf '{"params":{"devshard_escrow_params":{"approved_versions":%s}}}\n' "$approvals"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/curl"

run_case() {
  local mode="$1" output=''
  output="$tmp/$mode.env"
  MODE="$mode" GDC_JOIN_FAULT_DOMAIN_MAP='node0.example.test=domain-0,node1.example.test=domain-1,node2.example.test=domain-2,node3.example.test=domain-3' PATH="$tmp/bin:$PATH" "$OBSERVE" --bootstrap-file "$tmp/bootstrap.json" --output "$output"
}
run_case good
# shellcheck source=/dev/null
source "$tmp/good.env"
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]]
[[ "$GDC_NETWORK_CHAIN_ID" == gonka-devnet-community && "$GDC_NETWORK_CORE_VERSION" == 0.2.15 ]]
[[ "$GDC_NETWORK_COMETBFT_VERSION" == 0.38.19 ]]
[[ "$GDC_NETWORK_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
[[ "$GDC_NETWORK_DEVSHARD_APPROVALS" == *'"name":"v3"'* && "$GDC_NETWORK_DEVSHARD_APPROVALS" == *'"name":"v4"'* && "$GDC_NETWORK_DEVSHARD_APPROVALS" == *'"name":"v5"'* ]]
[[ -z "${GDC_NETWORK_DEVSHARD_TARGET:-}" && -z "${GDC_COMPOSITION:-}" ]]
fingerprint="$GDC_NETWORK_FINGERPRINT"
run_case reordered
# shellcheck source=/dev/null
source "$tmp/reordered.env"
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]]
[[ "$GDC_NETWORK_FINGERPRINT" == "$fingerprint" ]]
run_case approval_outlier
# shellcheck source=/dev/null
source "$tmp/approval_outlier.env"
[[ "$GDC_NETWORK_FINGERPRINT" == "$fingerprint" ]]

for case_name in one_seed conflict wrong_chain incomplete unknown conflicting_approvals malformed_approval duplicate_approval api_mismatch; do
  if run_case "$case_name" >"$tmp/$case_name.out" 2>"$tmp/$case_name.err"; then
    echo "unsafe seed observation accepted: $case_name" >&2
    exit 1
  fi
done
grep -Fq 'software_incomplete:' "$tmp/one_seed.err"
grep -Fq 'software_ambiguous:' "$tmp/conflict.err"
grep -Fq 'software_ambiguous:' "$tmp/wrong_chain.err"
grep -Fq 'software_incomplete:' "$tmp/incomplete.err"
grep -Fq 'software_unsupported:' "$tmp/unknown.err"
grep -Fq 'software_ambiguous:' "$tmp/conflicting_approvals.err"
grep -Fq 'software_incomplete:' "$tmp/malformed_approval.err"
grep -Fq 'software_incomplete:' "$tmp/duplicate_approval.err"
grep -Fq 'software_upgrade_required:' "$tmp/api_mismatch.err"

printf 'PASS seed-derived network composition selection is deterministic and fail-closed\n'
