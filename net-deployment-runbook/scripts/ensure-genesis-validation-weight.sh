#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

# A guardian is intentionally absent from PoC-preserved model capacity.  The
# bootstrap proof must therefore accept any configured, joined model
# participant rather than assuming that the Genesis validator itself receives
# a validation weight. This also keeps non-guardian Genesis deployments valid.
candidates=()
for node in "${GDC_NODES[@]}"; do
  account="$ACCOUNTS/$node-cold.json"
  [[ -s "$account" ]] || continue
  [[ "$node" == "$GENESIS_NODE" || -e "$STATE/joined/$node" ]] || continue
  candidates+=("$(jq -er .address "$account")")
done
(( ${#candidates[@]} > 0 )) || die 'no configured Genesis or joined participant account is available for validation-weight verification'
run="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-genesis-validation-weight"
mkdir -p "$run"

step 'Wait for a chain-computed Genesis validation weight'
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  group="$(ssh -T "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data')"
  printf '%s\n' "$group" >"$run/current-epoch-group.json"
  if jq -e --argjson candidates "$(printf '%s\n' "${candidates[@]}" | jq -R . | jq -s .)" --arg model "$MODEL_ID" '
    .epoch_group_data as $group
    | ($group.epoch_index | tonumber) > 0
    and ($group.sub_group_models | index($model) != null)
    and ($group.validation_weights
      | any(.member_address as $address
            | ($candidates | index($address) != null)
            and (.weight | tonumber) > 0))
  ' <<<"$group" >/dev/null; then
    jq --argjson candidates "$(printf '%s\n' "${candidates[@]}" | jq -R . | jq -s .)" '
      .epoch_group_data.validation_weights
      | map(select(.member_address as $address | ($candidates | index($address) != null) and (.weight | tonumber) > 0))
    ' "$run/current-epoch-group.json" >"$run/eligible-validation-weights.json"
    printf 'PASS a configured model participant has an active chain-computed validation weight; evidence: %s\n' "$run"
    exit 0
  fi
  epoch="$(jq -er '.epoch_group_data.epoch_index' <<<"$group")"
  height="$(ssh -T "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:26657/status' | jq -er '.result.sync_info.latest_block_height')"
  printf 'WAIT  validation weight epoch=%s height=%s\n' "$epoch" "$height"
  sleep 3
done

ssh -T "$GENESIS_NODE" "docker logs --since 15m ${GENESIS_NODE}-api-1 2>&1" \
  | grep -E 'weight sum|writeValidationSnapshot|ComputeNewWeights' >"$run/dapi-poc.log" || true
die "$GENESIS_NODE did not acquire a positive model validation weight within 600 seconds; inspect $run"
