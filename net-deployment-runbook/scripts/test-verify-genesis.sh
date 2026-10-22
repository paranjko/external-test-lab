#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
verify="$ROOT/01-identities-genesis/verify-genesis.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

jq -n '{chain_id:"fixture-chain",app_state:{inference:{participant_list:[{address:"gonka1fixture"}],model_list:[{id:"Qwen/Qwen3-0.6B"}],params:{epoch_params:{epoch_length:"70",confirmation_poc_safety_window:"10",epoch_shift:"0",poc_stage_duration:"4",poc_exchange_duration:"8",poc_slot_allocation:{value:"5",exponent:-1}},poc_params:{validation_slots:2,poc_v2_enabled:true},devshard_escrow_params:{allowed_creator_addresses:[],approved_versions:[]}}},genutil:{gen_txs:[{}]},bank:{denom_metadata:[{base:"ngonka",denom_units:[{denom:"ngonka",exponent:0},{denom:"gonka",exponent:9}]}]}},consensus:{params:{block:{max_bytes:"123"}}}}' >"$tmp/genesis.json"
sha256sum "$tmp/genesis.json" | awk '{print $1"  genesis.json"}' >"$tmp/genesis.sha256"
bash "$verify" "$tmp/genesis.json" "$tmp/genesis.sha256" fixture-chain >/dev/null

registry='[{"name":"v4.1","binary":"https://example.test/v4.1.zip","sha256":"1111111111111111111111111111111111111111111111111111111111111111"},{"name":"v4.2","binary":"https://example.test/v4.2.zip","sha256":"2222222222222222222222222222222222222222222222222222222222222222"},{"name":"v6","binary":"https://example.test/v6.zip","sha256":"6666666666666666666666666666666666666666666666666666666666666666"}]'
jq -n --argjson registry "$registry" '{app_state:{inference:{model_list:[{proposed_by:"legacy-uploader",id:"model-a"},{proposed_by:"operator-account",id:"model-b"}],params:{epoch_params:{epoch_length:"900"},devshard_escrow_params:{allowed_creator_addresses:["gonka1reviewed"],approved_versions:["v9"]}},devshard_approved_versions:$registry}},consensus_params:{block:{max_bytes:"456"}}}' >"$tmp/config.json"
jq --slurpfile cfg "$tmp/config.json" '.app_state.inference.model_list=($cfg[0].app_state.inference.model_list | map(.proposed_by="genesis")) | .app_state.inference.params=$cfg[0].app_state.inference.params | .app_state.inference.devshard_approved_versions=$cfg[0].app_state.inference.devshard_approved_versions | .consensus.params=$cfg[0].consensus_params' "$tmp/genesis.json" >"$tmp/changed.json"
mv "$tmp/changed.json" "$tmp/genesis.json"
sha256sum "$tmp/genesis.json" | awk '{print $1"  genesis.json"}' >"$tmp/genesis.sha256"
bash "$verify" "$tmp/genesis.json" "$tmp/genesis.sha256" fixture-chain --config-file "$tmp/config.json" >/dev/null
jq '.app_state.inference.model_list[0].proposed_by="not-genesis"' "$tmp/genesis.json" >"$tmp/bad-proposed-by.json"
sha256sum "$tmp/bad-proposed-by.json" | awk '{print $1"  bad-proposed-by.json"}' >"$tmp/bad-proposed-by.sha256"
if bash "$verify" "$tmp/bad-proposed-by.json" "$tmp/bad-proposed-by.sha256" fixture-chain --config-file "$tmp/config.json" >/dev/null 2>&1; then
  echo 'Genesis with a non-genesis model proposer unexpectedly passed' >&2
  exit 1
fi

jq '.app_state.inference.devshard_approved_versions[0].sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$tmp/config.json" >"$tmp/mismatch.json"
if bash "$verify" "$tmp/genesis.json" "$tmp/genesis.sha256" fixture-chain --config-file "$tmp/mismatch.json" >/dev/null 2>&1; then
  echo 'reviewed-config mismatch unexpectedly passed' >&2
  exit 1
fi
echo 'Genesis verifier tests: PASS'
