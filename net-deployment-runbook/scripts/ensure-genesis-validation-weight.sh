#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

participant="$(jq -er .address "$ACCOUNTS/gdc-node0-cold.json")"
run="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-genesis-validation-weight"
mkdir -p "$run"

step 'Wait for a chain-computed Genesis validation weight'
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  group="$(ssh -T gdc-node0 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data')"
  printf '%s\n' "$group" >"$run/current-epoch-group.json"
  if jq -e --arg participant "$participant" --arg model "$MODEL_ID" '
    .epoch_group_data as $group
    | ($group.epoch_index | tonumber) > 0
    and ($group.sub_group_models | index($model) != null)
    and ($group.validation_weights
      | any(.member_address == $participant and (.weight | tonumber) > 0))
  ' <<<"$group" >/dev/null; then
    printf 'PASS Genesis participant model validation weight is active; evidence: %s\n' "$run"
    exit 0
  fi
  epoch="$(jq -er '.epoch_group_data.epoch_index' <<<"$group")"
  height="$(ssh -T gdc-node0 'curl -fsS http://127.0.0.1:26657/status' | jq -er '.result.sync_info.latest_block_height')"
  printf 'WAIT  validation weight epoch=%s height=%s\n' "$epoch" "$height"
  sleep 3
done

ssh -T gdc-node0 'docker logs --since 15m gdc-node0-api-1 2>&1' \
  | grep -E 'weight sum|writeValidationSnapshot|ComputeNewWeights' >"$run/dapi-poc.log" || true
die "gdc-node0 did not acquire a positive model validation weight within 600 seconds; inspect $run"
