#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBSERVE="$ROOT/scripts/observe-network-composition.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"9b29115a1090532546ce9cc1dfb7d37f09c661deb82cb4f20f41da832c98254d"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  *node0.example.test*) node=0; id=0123456789abcdef0123456789abcdef01234567 ;;
  *node1.example.test*) node=1; id=89abcdef0123456789abcdef0123456789abcdef ;;
  *) exit 2 ;;
esac
[[ "${MODE:-good}" != one_seed || "$node" != 1 ]] || exit 7
chain=gonka-devnet-community
[[ "${MODE:-good}" != wrong_chain || "$node" != 1 ]] || chain=other-chain
version=0.2.14
cometbft_version=0.38.19
commit=2bfd85c958732992c7a9c5be1d796affe29f3ab4
[[ "${MODE:-good}" != conflict || "$node" != 1 ]] || { version=0.2.15; commit=4d687ed6782bcea3931d2d9135bf322f84e190ab; }
[[ "${MODE:-good}" != unknown ]] || { version=9.9.9; commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
[[ "${MODE:-good}" != v5 ]] || { version=0.2.15; commit=4d687ed6782bcea3931d2d9135bf322f84e190ab; }
[[ "${MODE:-good}" != v3 ]] || { version=0.2.15; commit=4d687ed6782bcea3931d2d9135bf322f84e190ab; }
case "$url" in
  */status) printf '{"result":{"node_info":{"id":"%s","network":"%s","version":"%s"}}}\n' "$id" "$chain" "$cometbft_version" ;;
  */abci_info) printf '{"result":{"response":{"version":"%s"}}}\n' "$version" ;;
  */v1/versions)
    [[ "${MODE:-good}" != incomplete || "$node" != 1 ]] || { printf '{"node_version":{"version":"0.2.14"}}\n'; exit 0; }
    api_node_version="$version"; api_node_commit="$commit"
    [[ "${MODE:-good}" != api_mismatch || "$node" != 1 ]] || { api_node_version=0.2.15; api_node_commit=4d687ed6782bcea3931d2d9135bf322f84e190ab; }
    printf '{"node_version":{"version":"%s","commit":"%s"},"api_version":{"version":"0.2.14-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}}\n' "$api_node_version" "$api_node_commit"
    ;;
  */chain-api/productscience/inference/inference/params)
    target='[]'
    [[ "${MODE:-good}" != v5 ]] || target='[{"name":"v5"}]'
    [[ "${MODE:-good}" != v3 ]] || target='[{"name":"v3"}]'
    [[ "${MODE:-good}" != mixed_target || "$node" != 1 ]] || target='[{"name":"v5"}]'
    printf '{"params":{"devshard_escrow_params":{"approved_versions":%s}}}\n' "$target"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/curl"

run_case() {
  local mode="$1" output=''
  output="$tmp/$mode.env"
  MODE="$mode" PATH="$tmp/bin:$PATH" "$OBSERVE" --bootstrap-file "$tmp/bootstrap.json" --output "$output"
}
run_case good
# shellcheck source=/dev/null
source "$tmp/good.env"
[[ "$GDC_RELEASE_PROFILE" == v2026.07.23 ]]
[[ "$GDC_NETWORK_CHAIN_ID" == gonka-devnet-community && "$GDC_NETWORK_CORE_VERSION" == 0.2.14 ]]
[[ "$GDC_NETWORK_COMETBFT_VERSION" == 0.38.19 ]]
[[ "$GDC_NETWORK_DEVSHARD_TARGET" == '' && "$GDC_NETWORK_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
run_case v5
# shellcheck source=/dev/null
source "$tmp/v5.env"
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]]
[[ "$GDC_COMPOSITION" == core-v2026.08.06+devshard-v2026.08.27-rc.0 ]]
run_case v3
# shellcheck source=/dev/null
unset GDC_COMPOSITION
source "$tmp/v3.env"
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]]
[[ -z "${GDC_COMPOSITION:-}" ]]

for case_name in one_seed conflict wrong_chain incomplete unknown mixed_target api_mismatch; do
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
grep -Fq 'software_ambiguous:' "$tmp/mixed_target.err"
grep -Fq 'software_upgrade_required:' "$tmp/api_mismatch.err"

printf 'PASS seed-derived network composition selection is deterministic and fail-closed\n'
