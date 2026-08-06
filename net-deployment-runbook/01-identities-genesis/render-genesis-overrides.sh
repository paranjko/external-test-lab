#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --gateway-account ADDRESS --genesis-guardian ADDRESS --output FILE" >&2; }
GATEWAY=''; GUARDIAN=''; OUTPUT=''
while (($#)); do
  case "$1" in
    --gateway-account) GATEWAY="$2"; shift 2 ;;
    --genesis-guardian) GUARDIAN="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$GATEWAY" =~ ^gonka1[0-9a-z]{20,90}$ && "$GUARDIAN" =~ ^gonka1[0-9a-z]{20,90}$ && -n "$OUTPUT" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
load_profiles
TEMPLATE="$ROOT/01-identities-genesis/genesis-overrides.template.json"
mkdir -p "$(dirname "$OUTPUT")"
jq --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" --arg guardian "$GUARDIAN" \
  --argjson vram "$GENESIS_V_RAM" --argjson throughput "$GENESIS_THROUGHPUT_PER_NONCE" \
  --argjson units "$GENESIS_UNITS_OF_COMPUTE_PER_TOKEN" --argjson seq "$GENESIS_SEQ_LEN" \
  --argjson epoch_length "$GENESIS_EPOCH_LENGTH" --argjson epoch_shift "$GENESIS_EPOCH_SHIFT" '
  .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses = []
  | .app_state.inference.params.devshard_escrow_params.approved_versions = []
  | .app_state.inference.params.genesis_guardian_params.network_maturity_threshold = "2000000"
  | .app_state.inference.params.genesis_guardian_params.network_maturity_min_height = "0"
  | .app_state.inference.params.genesis_guardian_params.guardian_addresses = [$guardian]
  | .app_state.inference.genesis_only_params.genesis_guardian_enabled = true
  | .app_state.inference.genesis_only_params.genesis_guardian_network_maturity_threshold = "2000000"
  | .app_state.inference.genesis_only_params.genesis_guardian_multiplier = {value:"52", exponent:-2}
  | .app_state.inference.genesis_only_params.genesis_guardian_addresses = [$guardian]
  | .app_state.inference.params.poc_params.model_id = $model
  | .app_state.inference.params.poc_params.seq_len = ($seq | tostring)
  | .app_state.inference.params.poc_params.models[0].model_id = $model
  | .app_state.inference.params.poc_params.models[0].seq_len = ($seq | tostring)
  | .app_state.inference.params.epoch_params.epoch_length = ($epoch_length | tostring)
  | .app_state.inference.params.epoch_params.epoch_shift = ($epoch_shift | tostring)
  | .app_state.inference.model_list[0].id = $model
  | .app_state.inference.model_list[0].hf_repo = $model
  | .app_state.inference.model_list[0].hf_commit = $revision
  | .app_state.inference.model_list[0].v_ram = ($vram | tostring)
  | .app_state.inference.model_list[0].throughput_per_nonce = ($throughput | tostring)
  | .app_state.inference.model_list[0].units_of_compute_per_token = ($units | tostring)
' "$TEMPLATE" >"$OUTPUT"
echo "$OUTPUT"
