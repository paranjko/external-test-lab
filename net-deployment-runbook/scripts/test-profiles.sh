#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/profile.sh"

for release in testnet-0.2.14 testnet-0.2.15; do
  GDC_RELEASE_PROFILE="$release" GDC_MODEL_PROFILE=qwen3-0.6b load_profiles
  [[ "$GONKA_COMMIT" =~ ^[0-9a-f]{40}$ ]]
  [[ "$GENESIS_EPOCH_LENGTH" == 50 && "$GENESIS_EPOCH_SHIFT" == 0 ]]
  images=("$TMKMS_IMAGE" "$INFERENCED_IMAGE" "$DAPI_IMAGE" "$VERSIOND_IMAGE" "$PROXY_IMAGE" "$POSTGRES_IMAGE" "$MLNODE_GENERIC_IMAGE" "$MLNODE_BLACKWELL_IMAGE" "$MLNODE_PROXY_IMAGE")
  [[ "$EDGE_API_ENABLED" == false || "$EDGE_API_ENABLED" == true ]] || { echo "invalid EDGE_API_ENABLED in $release" >&2; exit 1; }
  [[ "$EDGE_API_ENABLED" != true ]] || images+=("$EDGE_API_IMAGE")
  for image in "${images[@]}"; do
    [[ "$image" != *:latest && "$image" != *:latest@* ]] || { echo "mutable image in $release: $image" >&2; exit 1; }
  done
  [[ "$DEVSHARD_V3_SHA256" =~ ^[0-9a-f]{64}$ && "$DEVSHARD_V4_SHA256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$BRIDGE_IMAGE" == *@sha256:* ]]
  if [[ "$release" == testnet-0.2.15 ]]; then
    [[ "$INFERENCED_UPGRADE_URL" == https://github.com/gonka-ai/gonka/releases/download/release%2Fv0.2.15/inferenced-amd64.zip ]]
    [[ "$DAPI_UPGRADE_URL" == https://github.com/gonka-ai/gonka/releases/download/release%2Fv0.2.15/decentralized-api-amd64.zip ]]
    [[ "$INFERENCED_UPGRADE_SHA256" == 91af67df9ef5c576a1695e5e85c8ee344f9f1a69d941bfc28fb339d9fd33617e ]]
    [[ "$DAPI_UPGRADE_SHA256" == c9cf1bfa2c994beca8a528d0ee3ad7197a582144769711600ec9df41faf4c9f7 ]]
  fi
done

GDC_RELEASE_PROFILE=testnet-0.2.14 GDC_MODEL_PROFILE=qwen3-0.6b load_profiles
for profile in a5000-24g t4-16g 4090-24g 3090-24g blackwell-16g; do
  out="$(mktemp)"
  trap 'rm -f "${out:-}"' EXIT
  "$ROOT/02-node/render-node-config.sh" --node-name gdc-node1 --profile "$profile" --output "$out" >/dev/null
  jq -e --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" '
    .[0].max_concurrent == 64
    and (.[0].models[$model].args | index("--dtype") != null)
    and (.[0].models[$model].args | index($revision) != null)
    and (.[0].models[$model].args | index("2048") != null)
  ' "$out" >/dev/null
  rm -f "$out"
  unset out
done
genesis_out="$(mktemp)"
trap 'rm -f "${genesis_out:-}"' EXIT
GDC_RELEASE_PROFILE=testnet-0.2.14 GDC_MODEL_PROFILE=qwen3-0.6b \
  "$ROOT/01-identities-genesis/render-genesis-overrides.sh" \
  --gateway-account gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq \
  --output "$genesis_out" >/dev/null
jq -e --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" '
  .app_state.inference.model_list[0] as $model_config
  | $model_config.id == $model
  and $model_config.hf_commit == $revision
  and $model_config.v_ram == "16"
  and $model_config.throughput_per_nonce == "10000"
  and .app_state.inference.params.devshard_escrow_params.approved_versions == []
  and .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses == []
  and .app_state.inference.params.poc_params.models[0].model_id == $model
  and .app_state.inference.params.epoch_params.epoch_length == "50"
  and .app_state.inference.params.epoch_params.epoch_shift == "0"
  and .app_state.inference.params.epoch_params.poc_stage_duration == "4"
  and .app_state.inference.params.epoch_params.poc_validation_duration == "4"
  and .app_state.gov.params.voting_period == "30s"
' "$genesis_out" >/dev/null
rm -f "$genesis_out"
unset genesis_out
printf 'PASS release/model profile invariants\n'
