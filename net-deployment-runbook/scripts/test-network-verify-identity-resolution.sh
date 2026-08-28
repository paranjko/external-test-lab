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
  jq -n --arg address "$(address "${node#node}")" '{address:$address}' >"$(node_account_file "$node")"
done

chain="$tmp/participants-chain.json"
jq -n --arg a0 "$(address 0)" --arg a1 "$(address 1)" --arg a2 "$(address 2)" --arg a3 "$(address 3)" --arg a4 "$(address 4)" '
  {participant:[
    {address:$a0,validator_key:"key0",inference_url:"https://node0.example",status:"ACTIVE"},
    {address:$a1,validator_key:"key1",inference_url:"https://node1.example",status:"ACTIVE"},
    {address:$a2,validator_key:"key2",inference_url:"https://node2.example",status:"ACTIVE"},
    {address:$a3,validator_key:"key3",inference_url:"https://node3.example/",status:"ACTIVE"},
    {address:$a4,validator_key:"key4",inference_url:"https://node4.example",status:"ACTIVE"}]}' >"$chain"

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
resolve() {
  resolve_expected_network_participants "$out" test-chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$1" "$2"
}
expect_reject() { if ( "$@" ) >/dev/null 2>&1; then echo 'accepted invalid identity contract' >&2; exit 1; fi; }

resolve "$topology" "$chain"
[[ "$(jq -r '.chain_id' "$out")" == test-chain ]]
[[ "$(jq -r '.genesis_sha256' "$out")" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
[[ "$(jq '.participants | length' "$out")" == 5 ]]
[[ "$(jq -r '.participants[] | select(.node == "node3") | .source' "$out")" == public-chain-participant ]]
[[ "$(jq -r '.participants[] | select(.node == "node3") | .validator_key' "$out")" == key3 ]]
[[ "$(jq -r '.participants[] | select(.node == "node4") | .source' "$out")" == coordinator-owned-public-account ]]

# An independent Host remains resolvable from public chain state with no receipt.
resolve "$tmp/no-receipt.json" "$chain"

jq '.genesis_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$topology" >"$tmp/stale.json"
expect_reject resolve "$tmp/stale.json" "$chain"
jq '.participants[3].validator_key = "other-key"' "$topology" >"$tmp/conflicting-receipt.json"
expect_reject resolve "$tmp/conflicting-receipt.json" "$chain"
jq '.participant[4].inference_url = "https://node3.example/"' "$chain" >"$tmp/duplicate-endpoint.json"
expect_reject resolve "$tmp/no-receipt.json" "$tmp/duplicate-endpoint.json"
jq 'del(.participant[3])' "$chain" >"$tmp/missing.json"
expect_reject resolve "$tmp/no-receipt.json" "$tmp/missing.json"
jq '.participant[3].status = "INACTIVE"' "$chain" >"$tmp/inactive.json"
expect_reject resolve "$tmp/no-receipt.json" "$tmp/inactive.json"
jq '.participant[3].inference_url = "http://node3.example"' "$chain" >"$tmp/non-https.json"
expect_reject resolve "$tmp/no-receipt.json" "$tmp/non-https.json"
jq '.participant[0].address = "gonka100000000000000000099"' "$chain" >"$tmp/local-host-conflict.json"
expect_reject resolve "$tmp/no-receipt.json" "$tmp/local-host-conflict.json"

printf 'PASS complete Host identity resolution uses public chain state and rejects invalid mappings\n'
