#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --gateway-account gonka1... --genesis-guardian gonkavaloper1... [--config-file PATH] --output FILE" >&2; }
GATEWAY=''; GUARDIAN=''; OUTPUT=''; CONFIG_FILE=''
while (($#)); do
  case "$1" in
    --gateway-account) GATEWAY="$2"; shift 2 ;;
    --genesis-guardian) GUARDIAN="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
# GenesisGuardianAddresses are validator operator addresses.  Passing the
# corresponding account address succeeds at genesis construction but makes
# the 0.2.14 allocation code reject the guardian during PoC preservation.
[[ "$GATEWAY" =~ ^gonka1[0-9a-z]{20,90}$ && "$GUARDIAN" =~ ^gonkavaloper1[0-9a-z]{20,90}$ && -n "$OUTPUT" ]] || { usage; exit 2; }
if [[ -n "$CONFIG_FILE" && ! -s "$CONFIG_FILE" ]]; then
  echo "Genesis config file is missing or empty: $CONFIG_FILE" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
load_profiles
TEMPLATE="$ROOT/01-identities-genesis/genesis-overrides.template.json"
GENESIS_GUARDIAN_ENABLED="${GDC_GENESIS_GUARDIAN_ENABLED:-false}"
[[ "$GENESIS_GUARDIAN_ENABLED" =~ ^(true|false)$ ]] || { echo 'GDC_GENESIS_GUARDIAN_ENABLED must be true or false' >&2; exit 2; }
guardian_addresses='[]'
guardian_threshold='0'
guardian_multiplier='{"value":"0","exponent":0}'
if [[ "$GENESIS_GUARDIAN_ENABLED" == true ]]; then
  guardian_addresses="[\"$GUARDIAN\"]"
  guardian_threshold='2000000'
  guardian_multiplier='{"value":"52","exponent":-2}'
fi
rendered="$(mktemp "${TMPDIR:-/tmp}/gdc-genesis-overrides.XXXXXX")"
trap 'rm -f "$rendered"' EXIT
jq --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" \
  --argjson vram "$GENESIS_V_RAM" --argjson throughput "$GENESIS_THROUGHPUT_PER_NONCE" \
  --argjson units "$GENESIS_UNITS_OF_COMPUTE_PER_TOKEN" --argjson seq "$GENESIS_SEQ_LEN" --argjson guardian_enabled "$GENESIS_GUARDIAN_ENABLED" \
  --argjson guardian_addresses "$guardian_addresses" --argjson guardian_threshold "$guardian_threshold" --argjson guardian_multiplier "$guardian_multiplier" \
  --argjson epoch_length "$GENESIS_EPOCH_LENGTH" --argjson epoch_shift "$GENESIS_EPOCH_SHIFT" --argjson confirmation_poc_safety_window "$GENESIS_CONFIRMATION_POC_SAFETY_WINDOW" '
  .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses = []
  | .app_state.inference.params.devshard_escrow_params.approved_versions = []
  | .app_state.inference.devshard_approved_versions = []
  | .app_state.inference.params.genesis_guardian_params.network_maturity_threshold = ($guardian_threshold | tostring)
  | .app_state.inference.params.genesis_guardian_params.network_maturity_min_height = "0"
  | .app_state.inference.params.genesis_guardian_params.guardian_addresses = $guardian_addresses
  | .app_state.inference.genesis_only_params.genesis_guardian_enabled = $guardian_enabled
  | .app_state.inference.genesis_only_params.genesis_guardian_network_maturity_threshold = ($guardian_threshold | tostring)
  | .app_state.inference.genesis_only_params.genesis_guardian_multiplier = $guardian_multiplier
  | .app_state.inference.genesis_only_params.genesis_guardian_addresses = $guardian_addresses
  | .app_state.inference.params.poc_params.model_id = $model
  | .app_state.inference.params.poc_params.seq_len = ($seq | tostring)
  | .app_state.inference.params.poc_params.models[0].model_id = $model
  | .app_state.inference.params.poc_params.models[0].seq_len = ($seq | tostring)
  | .app_state.inference.params.epoch_params.epoch_length = ($epoch_length | tostring)
  | .app_state.inference.params.epoch_params.epoch_shift = ($epoch_shift | tostring)
  | .app_state.inference.params.epoch_params.confirmation_poc_safety_window = ($confirmation_poc_safety_window | tostring)
  | .app_state.inference.model_list[0].id = $model
  | .app_state.inference.model_list[0].hf_repo = $model
  | .app_state.inference.model_list[0].hf_commit = $revision
  | .app_state.inference.model_list[0].v_ram = ($vram | tostring)
  | .app_state.inference.model_list[0].throughput_per_nonce = ($throughput | tostring)
  | .app_state.inference.model_list[0].units_of_compute_per_token = ($units | tostring)
 ' "$TEMPLATE" >"$rendered"

if [[ -n "$CONFIG_FILE" ]]; then
  jq -e '
    def valid_registry:
      type == "array"
      and all(.[];
        type == "object"
        and (keys|sort) == ["binary", "name", "sha256"]
        and (.name | type == "string" and test("^v[1-9][0-9]*(\\.[0-9]+)*$"))
        and (.binary | type == "string" and test("^https://[^/[:space:]]+(/[^[:space:]]*)?$"))
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
      and ([.[].name] | length == (unique | length));
    def reject_stateful:
      (keys - ["app_state", "consensus_params"] | length == 0)
      and ((.app_state | type) == "object")
      and ((has("consensus_params") | not) or ((.consensus_params | type) == "object"));
    def allowed_module($name):
      ($name == "inference" or $name == "gov" or $name == "bank" or
       $name == "staking" or $name == "slashing" or $name == "mint" or
       $name == "distribution" or $name == "crisis" or $name == "auth" or
       $name == "genutil" or $name == "params" or $name == "upgrade" or
       $name == "feegrant" or $name == "authz" or $name == "group" or
       $name == "evidence" or $name == "vesting" or $name == "ibc" or
       $name == "transfer" or $name == "capability" or $name == "consensus" or
       $name == "collateral" or $name == "streamvesting" or $name == "bls");
    def valid_modules:
      all(.app_state | to_entries[];
        allowed_module(.key)
        and ((.value | type) == "object")
        and (if .key == "inference" then
               ((.value | keys - ["params", "model_list", "devshard_approved_versions"] | length) == 0)
               and ((.value.params | type) == "object")
               and ((.value.model_list | type) == "array")
               and ((.value | has("devshard_approved_versions") | not) or (.value.devshard_approved_versions | valid_registry))
             else
               ((.value | keys - ["params"] | length) == 0)
               and ((.value.params | type) == "object")
             end));
    def valid_inference:
      if .app_state.inference == null then true else
        ((.app_state.inference | type) == "object")
        and ((.app_state.inference | keys - ["params", "model_list", "devshard_approved_versions"] | length) == 0)
        and ((.app_state.inference.params | type) == "object")
        and ((.app_state.inference.model_list | type) == "array")
        and all(.app_state.inference.model_list[]; type == "object" and (.id | type) == "string" and (.id | length) > 0)
        and ([.app_state.inference.model_list[].id] | length == (unique | length))
        and ((.app_state.inference.params.poc_params.model_id) as $selected
             | ($selected | type) == "string"
             and ([.app_state.inference.model_list[].id] | index($selected) != null))
        and ((.app_state.inference | has("devshard_approved_versions") | not) or (.app_state.inference.devshard_approved_versions | valid_registry))
      end;
    if (type != "object") then error("configuration must be a JSON object")
    elif (reject_stateful | not) then error("configuration contains unsupported top-level or stateful fields; only app_state module params, inference model_list, and consensus_params are accepted")
    elif (valid_modules | not) then error("app_state may contain only module objects with a params object")
    elif (valid_inference | not) then error("inference config must contain params and a unique model_list including the selected model")
    else . end
  ' "$CONFIG_FILE" >/dev/null || exit 2
  # Import files use the SDK-exported `consensus_params` section, whereas
  # native CometBFT Genesis stores those values at consensus.params.
  jq 'if has("consensus_params") then .consensus = ((.consensus // {}) + {params:.consensus_params}) | del(.consensus_params) else . end
    | .app_state.inference.model_list |= map(.proposed_by = "genesis")' \
    "$CONFIG_FILE" >"$rendered.config" || exit 2
  jq -s '.[0] * .[1]' "$rendered" "$rendered.config" >"$rendered.merged" || exit 2
  mv "$rendered.merged" "$rendered"
fi

mkdir -p "$(dirname "$OUTPUT")"
cat "$rendered" >"$OUTPUT"
echo "$OUTPUT"
