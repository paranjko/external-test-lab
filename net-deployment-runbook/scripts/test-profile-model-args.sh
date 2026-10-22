#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/net-deployment-runbook"
mkdir -p "$fixture/scripts" "$fixture/01-identities-genesis" "$tmp/model"
cp "$ROOT/scripts/profile.sh" "$fixture/scripts/profile.sh"
cp "$ROOT/01-identities-genesis/render-genesis-overrides.sh" "$fixture/01-identities-genesis/render-genesis-overrides.sh"
cp "$ROOT/01-identities-genesis/genesis-overrides.template.json" "$fixture/01-identities-genesis/genesis-overrides.template.json"
cp -a "$ROOT/profiles" "$fixture/profiles"
cp "$ROOT/../model/qwen2.5-7b-instruct-devnet.lock" "$ROOT/../model/qwen3-4b-instruct-2507-devnet.lock" "$tmp/model/"

(
  source "$fixture/scripts/profile.sh"
  GDC_RELEASE_PROFILE=v2026.10.06 GDC_MODEL_PROFILE=qwen2.5-7b-instruct-devnet load_profiles
  [[ "$MODEL_ID" == Qwen/Qwen2.5-7B-Instruct ]]
  [[ "$MODEL_SOURCE_REVISION" == a09a35458c702b33eeacc393d103063234e8bc28 ]]
  [[ "$GDC_MODEL_PROFILE_SCOPE" == network ]]
  [[ "$MLNODE_VLLM_ARGS" == '--enable-auto-tool-choice --tool-call-parser hermes --kv-cache-dtype fp8 --kv-cache-memory-bytes 1073741824' ]]
)
(
  source "$fixture/scripts/profile.sh"
  GDC_RELEASE_PROFILE=v2026.10.06 GDC_MODEL_PROFILE=qwen3-4b-instruct-2507-devnet load_profiles
  [[ "$MODEL_ID" == Qwen/Qwen3-4B-Instruct-2507 ]]
  [[ "$MLNODE_VLLM_ARGS" == '--enable-auto-tool-choice --tool-call-parser hermes' ]]
)

jq -n '{app_state:{inference:{params:{poc_params:{model_id:"Qwen/Qwen2.5-7B-Instruct",seq_len:"777",models:[{model_id:"Qwen/Qwen2.5-7B-Instruct",seq_len:"777"}]}},model_list:[{id:"Qwen/Qwen2.5-7B-Instruct",hf_repo:"Qwen/Qwen2.5-7B-Instruct",hf_commit:"a09a35458c702b33eeacc393d103063234e8bc28",v_ram:"24",throughput_per_nonce:"10000",units_of_compute_per_token:"100"}]}}}' >"$tmp/config.json"
GDC_RELEASE_PROFILE=v2026.10.06 GDC_MODEL_PROFILE=qwen2.5-7b-instruct-devnet \
  "$fixture/01-identities-genesis/render-genesis-overrides.sh" \
  --gateway-account gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --genesis-guardian gonkavaloper1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --config-file "$tmp/config.json" --output "$tmp/7b-genesis-overrides.json" >/dev/null
jq -e '
  .app_state.inference.params.poc_params.model_id == "Qwen/Qwen2.5-7B-Instruct" and
  .app_state.inference.params.poc_params.models[0].seq_len == "777" and
  .app_state.inference.model_list == [{id:"Qwen/Qwen2.5-7B-Instruct",hf_repo:"Qwen/Qwen2.5-7B-Instruct",hf_commit:"a09a35458c702b33eeacc393d103063234e8bc28",v_ram:"24",throughput_per_nonce:"10000",units_of_compute_per_token:"100",proposed_by:"genesis"}]
' "$tmp/7b-genesis-overrides.json" >/dev/null

sed -i 's/--kv-cache-memory-bytes 1073741824/--kv-cache-memory-bytes 1073741824 --unreviewed-option/' \
  "$tmp/model/qwen2.5-7b-instruct-devnet.lock"
if (
  source "$fixture/scripts/profile.sh"
  GDC_RELEASE_PROFILE=v2026.10.06 GDC_MODEL_PROFILE=qwen2.5-7b-instruct-devnet load_profiles
) >"$tmp/unsupported.out" 2>"$tmp/unsupported.err"; then
  echo 'profile loader accepted an unreviewed vLLM argument' >&2
  exit 1
fi
grep -Fq 'unsupported MLNode vLLM arguments' "$tmp/unsupported.err"

printf 'PASS exact network 7B and 4B vLLM argument allowlist\n'
