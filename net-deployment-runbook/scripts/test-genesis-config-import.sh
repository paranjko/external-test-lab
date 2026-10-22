#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="$ROOT/01-identities-genesis/render-genesis-overrides.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gateway='gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
guardian='gonkavaloper1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
registry='[{"name":"v4.1","binary":"https://example.test/devshard-v4.1.zip","sha256":"1111111111111111111111111111111111111111111111111111111111111111"},{"name":"v4.2","binary":"https://example.test/devshard-v4.2.zip","sha256":"2222222222222222222222222222222222222222222222222222222222222222"},{"name":"v6","binary":"https://example.test/devshard-v6.zip","sha256":"6666666666666666666666666666666666666666666666666666666666666666"}]'

env GDC_RELEASE_PROFILE=v2026.07.23 GDC_DEPLOYMENT_PROFILE=community-lab GENESIS_V_RAM=8 GENESIS_THROUGHPUT_PER_NONCE=1 GENESIS_UNITS_OF_COMPUTE_PER_TOKEN=1 GENESIS_SEQ_LEN=8192 \
  "$renderer" --gateway-account "$gateway" --genesis-guardian "$guardian" --output "$tmp/default.json" >/dev/null
jq -e '.app_state.inference.model_list | length == 1 and .[0].id == "Qwen/Qwen3-0.6B"' "$tmp/default.json" >/dev/null
jq -e '.app_state.inference.params.devshard_escrow_params.allowed_creator_addresses == [] and .app_state.inference.params.devshard_escrow_params.approved_versions == []' "$tmp/default.json" >/dev/null

jq -n --arg guardian "$guardian" --argjson registry "$registry" '{
  app_state: {
    inference: {
      params: {
        devshard_escrow_params: {allowed_creator_addresses:["gonka1cccccccccccccccccccccccccccccccccccc"],approved_versions:["v9"]},
        poc_params:{model_id:"Qwen/Qwen2.5-7B-Instruct",models:[{model_id:"Qwen/Qwen2.5-7B-Instruct",seq_len:"8192"},{model_id:"Qwen/Qwen3-4B-Instruct-2507",seq_len:"8192"}]},
        genesis_guardian_params:{guardian_addresses:[$guardian]}
      },
      model_list:[
        {proposed_by:"legacy-uploader",id:"Qwen/Qwen2.5-7B-Instruct",hf_repo:"Qwen/Qwen2.5-7B-Instruct",hf_commit:"abc",v_ram:"16",throughput_per_nonce:"4",units_of_compute_per_token:"1"},
        {id:"Qwen/Qwen3-4B-Instruct-2507",hf_repo:"Qwen/Qwen3-4B-Instruct-2507",hf_commit:"def",v_ram:"8",throughput_per_nonce:"8",units_of_compute_per_token:"1"}
      ],
      devshard_approved_versions:$registry
    }, gov:{params:{voting:{voting_period:"72h"}}},
    collateral:{params:{unbonding_period_epochs:"1"}},
    streamvesting:{params:{reward_vesting_period:"180"}},
    bls:{params:{i_total_slots:100}}
  }, consensus_params:{block:{max_bytes:"123"}}
}' >"$tmp/config.json"
env GDC_RELEASE_PROFILE=v2026.07.23 GDC_DEPLOYMENT_PROFILE=community-lab GENESIS_V_RAM=8 GENESIS_THROUGHPUT_PER_NONCE=1 GENESIS_UNITS_OF_COMPUTE_PER_TOKEN=1 GENESIS_SEQ_LEN=8192 \
  "$renderer" --gateway-account "$gateway" --genesis-guardian "$guardian" --config-file "$tmp/config.json" --output "$tmp/imported.json" >/dev/null
jq -e --argjson registry "$registry" '
  [.app_state.inference.model_list[].id] == ["Qwen/Qwen2.5-7B-Instruct","Qwen/Qwen3-4B-Instruct-2507"]
  and [.app_state.inference.model_list[].proposed_by] == ["genesis","genesis"]
  and .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses == ["gonka1cccccccccccccccccccccccccccccccccccc"]
  and .app_state.inference.params.devshard_escrow_params.approved_versions == ["v9"]
  and .app_state.inference.devshard_approved_versions == $registry
  and .app_state.gov.params.voting.voting_period == "72h"
  and .consensus.params.block.max_bytes == "123"
  and .app_state.collateral.params.unbonding_period_epochs == "1"
  and .app_state.streamvesting.params.reward_vesting_period == "180"
  and .app_state.bls.params.i_total_slots == 100
' "$tmp/imported.json" >/dev/null

reject() {
  local name="$1" json="$2"
  printf '%s\n' "$json" >"$tmp/$name.json"
  if env GDC_RELEASE_PROFILE=v2026.07.23 GDC_DEPLOYMENT_PROFILE=community-lab GENESIS_V_RAM=8 GENESIS_THROUGHPUT_PER_NONCE=1 GENESIS_UNITS_OF_COMPUTE_PER_TOKEN=1 GENESIS_SEQ_LEN=8192 \
    "$renderer" --gateway-account "$gateway" --genesis-guardian "$guardian" --config-file "$tmp/$name.json" --output "$tmp/$name-out.json" >/dev/null 2>&1; then
    echo "expected rejection: $name" >&2
    exit 1
  fi
  [[ ! -e "$tmp/$name-out.json" ]] || { echo "partial output created: $name" >&2; exit 1; }
}
reject stateful '{"app_state":{"inference":{"params":{},"model_list":[],"accounts":[]}}}'
reject account '{"accounts":[]}'
reject unknown '{"metadata":{},"app_state":{}}'
reject null-params '{"app_state":{"gov":{"params":null}}}'
reject duplicate-models '{"app_state":{"inference":{"params":{},"model_list":[{"id":"Qwen/Qwen2.5-7B-Instruct"},{"id":"Qwen/Qwen2.5-7B-Instruct"}]}}}'
reject missing-selected '{"app_state":{"inference":{"params":{},"model_list":[{"id":"Qwen/Qwen3-4B-Instruct-2507"}]}}}'
reject registry-missing-sha '{"app_state":{"inference":{"params":{"poc_params":{"model_id":"Qwen/Qwen2.5-7B-Instruct"}},"model_list":[{"id":"Qwen/Qwen2.5-7B-Instruct"}],"devshard_approved_versions":[{"name":"v4.1","binary":"https://example.test/v4.zip"}]}}}'
reject registry-query-envelope '{"app_state":{"inference":{"params":{"poc_params":{"model_id":"Qwen/Qwen2.5-7B-Instruct"}},"model_list":[{"id":"Qwen/Qwen2.5-7B-Instruct"}],"devshard_approved_versions":{"params":{"devshard_approved_versions":[]}}}}}'
reject registry-duplicate-name '{"app_state":{"inference":{"params":{"poc_params":{"model_id":"Qwen/Qwen2.5-7B-Instruct"}},"model_list":[{"id":"Qwen/Qwen2.5-7B-Instruct"}],"devshard_approved_versions":[{"name":"v4.1","binary":"https://example.test/v4.zip","sha256":"1111111111111111111111111111111111111111111111111111111111111111"},{"name":"v4.1","binary":"https://example.test/v4b.zip","sha256":"2222222222222222222222222222222222222222222222222222222222222222"}]}}}'
reject malformed '{not-json'
echo 'Genesis config import tests: PASS'
