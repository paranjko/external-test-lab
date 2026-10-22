#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --bootstrap-file FILE --accelerator-receipt FILE --model-id MODEL_ID --output FILE [--plan]" >&2; }
die() { printf 'join_model_selection_%s: %s\n' "$1" "$2" >&2; exit 1; }

bootstrap=''; accelerator=''; requested_model=''; output=''; plan_only=false
while (($#)); do
  case "$1" in
    --bootstrap-file) bootstrap="${2:-}"; shift 2 ;;
    --accelerator-receipt) accelerator="${2:-}"; shift 2 ;;
    --model-id) requested_model="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --plan) plan_only=true; shift ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$bootstrap" && -r "$accelerator" && -n "$output" ]] || { usage; exit 2; }
[[ "$requested_model" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$ ]] || die input 'model ID is required and must be safe'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/network-bootstrap.sh" verify "$bootstrap" >/dev/null
command -v curl >/dev/null || die dependency 'curl is required'
command -v jq >/dev/null || die dependency 'jq is required'
vram_mib=null
if [[ "$plan_only" != true ]]; then
  vram_mib="$(jq -er 'select(.vendor == "nvidia" and (.vram_mib | type == "number" and floor == . and . > 0)) | .vram_mib' "$accelerator")" \
    || die hardware 'the accelerator receipt has no usable VRAM value'
fi

registry_path='/chain-api/productscience/inference/inference/models_all'
registry=''; registry_api=''
while IFS= read -r api; do
  response="$(mktemp)"
  if curl -fsS --connect-timeout 10 --max-time 20 "$api$registry_path" >"$response" 2>/dev/null \
    && jq -ce '
      if type != "object" or (.model | type) != "array" or (.model | length) == 0 then empty
      else .model as $raw |
        [$raw[] | {id,hf_repo,hf_commit} |
          select(.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")) |
          select(.hf_repo | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")) |
          select(.hf_commit | type == "string" and test("^[a-f0-9]{40}$"))] as $models |
        if ($models | length) == ($raw | length) then $models else empty end
      end
    ' "$response" >"$response.valid"; then
    registry="$(<"$response.valid")"; registry_api="$api"; rm -f "$response" "$response.valid"; break
  fi
  rm -f "$response" "$response.valid"
done < <(jq -r '[.seeds[].api] | unique[]' "$bootstrap")
[[ -n "$registry" ]] || die registry_unavailable 'no Bootstrap API returned a valid model registry'

target_model="$requested_model"
jq -e --arg id "$target_model" 'any(.[]; .id == $id)' <<<"$registry" >/dev/null \
  || die model_not_registered "model $target_model is absent from the current network registry"
selected=''
legacy_selected=''
for lock in "$ROOT"/../model/*.lock; do
  profile="${lock##*/}"; profile="${profile%.lock}"
  model_id="$(awk -F= '$1 == "MODEL_ID" {print $2; exit}' "$lock")"
  revision="$(awk -F= '$1 == "MODEL_SOURCE_REVISION" {print $2; found=1; exit} $1 == "MODEL_REVISION" {fallback=$2} END {if (!found && fallback) print fallback}' "$lock")"
  source_id="$(awk -F= '$1 == "MODEL_SOURCE_ID" {print $2; exit}' "$lock")"; source_id="${source_id:-$model_id}"
  minimum_vram_mib="$(awk -F= '$1 == "MODEL_MIN_VRAM_MIB" {print $2; exit}' "$lock")"
  scope="$(awk -F= '$1 == "GDC_MODEL_PROFILE_SCOPE" {print $2; exit}' "$lock")"
  [[ "$model_id" == "$target_model" && "$minimum_vram_mib" =~ ^[1-9][0-9]*$ ]] || continue
  # Qualification-only locks are evidence for testing, not JOIN admission.
  # The original 0.6B lock predates scoped locks and remains the sole implicit
  # legacy network profile; every newer model must declare network scope.
  case "$scope" in
    network) ;;
    qualification-only) continue ;;
    '') [[ "$model_id" == "Qwen/Qwen3-0.6B" ]] || continue ;;
    *) continue ;;
  esac
  [[ "$plan_only" == true || "$minimum_vram_mib" -le "$vram_mib" ]] || continue
  jq -e --arg id "$model_id" --arg source "$source_id" --arg revision "$revision" \
    'any(.[]; .id == $id and .hf_repo == $source and .hf_commit == $revision)' <<<"$registry" >/dev/null || continue
  candidate="$(jq -cn --arg profile "$profile" --arg id "$model_id" --arg source "$source_id" --arg revision "$revision" --argjson minimum "$minimum_vram_mib" '{profile:$profile,model_id:$id,source_id:$source,source_revision:$revision,minimum_vram_mib:$minimum}')"
  if [[ -z "$scope" ]]; then
    [[ -z "$legacy_selected" ]] || die profile_ambiguous "more than one eligible legacy local profile matches $target_model"
    legacy_selected="$candidate"
  else
    [[ -z "$selected" ]] || die profile_ambiguous "more than one eligible network local profile matches $target_model"
    selected="$candidate"
  fi
done
selected="${selected:-$legacy_selected}"
if [[ -z "$selected" ]]; then
  [[ "$plan_only" != true ]] || die profile_unavailable "no registered local profile matches $target_model"
  die profile_unavailable "no registered local profile for $target_model fits ${vram_mib} MiB VRAM"
fi

mkdir -p "$(dirname "$output")"
temporary="$(mktemp "$(dirname "$output")/.join-model-selection.XXXXXX")"
# Bind confirmation to the selected profile and immutable model source, not the responding API
selection_identity="$(jq -Sc . <<<"$selected")"
if command -v sha256sum >/dev/null; then
  selection_id="$(printf '%s' "$selection_identity" | sha256sum | awk '{print $1}')"
else
  selection_id="$(printf '%s' "$selection_identity" | shasum -a 256 | awk '{print $1}')"
fi
jq -cn --arg api "$registry_api" --arg requested "$requested_model" --argjson vram "$vram_mib" --argjson selected "$selected" \
  --arg selection_id "$selection_id" \
  '{schema_version:1,kind:"gdc-join-model-selection",selection_id:$selection_id,requested_model_id:$requested,hardware:{vram_mib:$vram,vram_checked:($vram != null)},registry_api:$api,selected:$selected}' >"$temporary"
chmod 0600 "$temporary"; mv -f "$temporary" "$output"
printf 'PASS selected JOIN model profile=%s model=%s minimum_vram_mib=%s\n' \
  "$(jq -r .selected.profile "$output")" "$(jq -r .selected.model_id "$output")" "$(jq -r .selected.minimum_vram_mib "$output")"
