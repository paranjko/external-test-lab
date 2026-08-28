#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2034 # fixture global is consumed by sourced lib.sh helpers
GDC_HOME="$tmp/operator"
init_gdc_paths
init_gdc_data_root
# shellcheck disable=SC2034 # fixture global is consumed by sourced lib.sh helpers
GDC_NODE_ALIASES='node0 node1 node2 node3 node4'
# shellcheck disable=SC2034 # fixture global is consumed by sourced lib.sh helpers
GDC_NODE_PUBLIC_HOSTS='node0=node0.example node1=node1.example node2=node2.example node3=node3.example node4=node4.example'
# shellcheck disable=SC2034 # fixture global is consumed by sourced lib.sh helpers
GDC_NODE_P2P_PORTS='node0=5000 node1=5001 node2=5002 node3=5003 node4=5004'
load_topology

address() { printf 'gonka1%020d\n' "$1"; }
for node in node0 node1 node2 node4; do
  mkdir -p "$(dirname "$(node_account_file "$node")")"
done
jq -n --arg address "$(address 0)" '{address:$address}' >"$(node_account_file node0)"
jq -n --arg address "$(address 1)" '{address:$address}' >"$(node_account_file node1)"
jq -n --arg address "$(address 2)" '{address:$address}' >"$(node_account_file node2)"
jq -n --arg address "$(address 4)" '{address:$address}' >"$(node_account_file node4)"

topology="$tmp/topology.json"
jq -n --arg chain test-chain --arg genesis aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --arg a0 "$(address 0)" --arg a1 "$(address 1)" --arg a2 "$(address 2)" --arg a3 "$(address 3)" --arg a4 "$(address 4)" '
  {schema_version:1,chain_id:$chain,genesis_sha256:$genesis,participants:[
    {address:$a0,validator_key:"key0",runtime_id:("qwen3-0.6b:"+$a0),public_host:"node0.example"},
    {address:$a1,validator_key:"key1",runtime_id:("qwen3-0.6b:"+$a1),public_host:"node1.example"},
    {address:$a2,validator_key:"key2",runtime_id:("qwen3-0.6b:"+$a2),public_host:"node2.example"},
    {address:$a3,validator_key:"key3",runtime_id:("qwen3-0.6b:"+$a3),public_host:"node3.example",operator_mode:"independent-host"},
    {address:$a4,validator_key:"key4",runtime_id:("qwen3-0.6b:"+$a4),public_host:"node4.example"}]}' >"$topology"

out="$tmp/expected.json"
resolve_expected_network_participants "$out" test-chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$topology"
[[ "$(jq length "$out")" == 5 ]]
[[ "$(jq -r '.[] | select(.node == "node3") | .source' "$out")" == sanitized-current-lineage-receipt ]]
[[ "$(jq -r '.[] | select(.node == "node4") | .source' "$out")" == coordinator-owned-public-account ]]

expect_reject() { if ( "$@" ) >/dev/null 2>&1; then echo "accepted invalid identity contract" >&2; exit 1; fi; }
expect_reject resolve_expected_network_participants "$out" other-chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$topology"
expect_reject resolve_expected_network_participants "$out" test-chain bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$topology"
jq '.participants[3].address = .participants[2].address | .participants[3].runtime_id = ("qwen3-0.6b:" + .participants[2].address)' "$topology" >"$tmp/duplicate.json"
expect_reject resolve_expected_network_participants "$out" test-chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$tmp/duplicate.json"
jq '.participants[3].public_host = "node2.example"' "$topology" >"$tmp/ambiguous.json"
expect_reject resolve_expected_network_participants "$out" test-chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$tmp/ambiguous.json"
jq '.participants[4].address = "gonka100000000000000000003" | .participants[4].runtime_id = "qwen3-0.6b:gonka100000000000000000003"' "$topology" >"$tmp/conflict.json"
expect_reject resolve_expected_network_participants "$out" test-chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$tmp/conflict.json"
rm "$(node_account_file node4)"
expect_reject resolve_expected_network_participants "$out" test-chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$tmp/empty.json"

printf 'PASS complete Host identity resolution rejects missing, duplicate, stale, conflicting, and ambiguous identities\n'
