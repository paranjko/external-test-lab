#!/usr/bin/env bash
# Shared durable state for a bounded Host join acceptance run.  This file is
# sourced by the phase and its focused regression test.

join_acceptance_state_initialize() {
  local run="$1" run_id="$2" genesis_sha256="$3" participant_address="$4" runtime_id="$5" current_epoch="$6" epochs="$7"
  local state="$run/acceptance-state.json" observations="$run/poc-acceptance-observations.json" temporary preserved_initial
  [[ "$current_epoch" =~ ^[1-9][0-9]*$ && "$epochs" =~ ^[1-9][0-9]*$ ]] || return 2
  if [[ -s "$state" ]]; then
    jq -e --arg run_id "$run_id" --arg genesis_sha256 "$genesis_sha256" --arg participant_address "$participant_address" --arg runtime_id "$runtime_id" '
      .schema_version == 1
      and .run_id == $run_id
      and .genesis_sha256 == $genesis_sha256
      and .participant_address == $participant_address
      and .runtime_id == $runtime_id
      and (.initial_epoch | tonumber) > 0
      and (.deadline_epoch | tonumber) >= (.initial_epoch | tonumber)
    ' "$state" >/dev/null || return 1
  else
    # Runs created before this state file already retain epoch observations.
    # Adopt their first observed epoch instead of silently granting a new
    # bounded window from the resume epoch.
    preserved_initial="$(jq -er '[.[]?.epoch | tonumber] | min // empty' "$observations" 2>/dev/null || true)"
    [[ "$preserved_initial" =~ ^[1-9][0-9]*$ ]] || preserved_initial="$current_epoch"
    temporary="$(mktemp "$run/.acceptance-state.tmp.XXXXXX")"
    jq -n --arg run_id "$run_id" --arg genesis_sha256 "$genesis_sha256" --arg participant_address "$participant_address" --arg runtime_id "$runtime_id" \
      --argjson initial_epoch "$preserved_initial" --argjson deadline_epoch "$((preserved_initial + epochs))" \
      '{schema_version:1,run_id:$run_id,genesis_sha256:$genesis_sha256,participant_address:$participant_address,runtime_id:$runtime_id,initial_epoch:$initial_epoch,deadline_epoch:$deadline_epoch,strongest_observed:null}' \
      >"$temporary"
    mv "$temporary" "$state"
  fi
  printf '%s\t%s\n' "$(jq -er '.initial_epoch | tonumber' "$state")" "$(jq -er '.deadline_epoch | tonumber' "$state")"
}

join_acceptance_state_epoch_within_deadline() {
  local epoch="$1" deadline_epoch="$2"
  [[ "$epoch" =~ ^[1-9][0-9]*$ && "$deadline_epoch" =~ ^[1-9][0-9]*$ ]] \
    && (( epoch <= deadline_epoch ))
}

join_acceptance_state_record_strongest() {
  local run="$1" epoch="$2" participant_weight="$3" accepted_weight_sum="$4" committed_total="$5" temporary
  local state="$run/acceptance-state.json"
  temporary="$(mktemp "$run/.acceptance-state.tmp.XXXXXX")"
  jq --argjson epoch "$epoch" --argjson participant_weight "$participant_weight" \
    --argjson accepted_weight_sum "$accepted_weight_sum" --argjson committed_total "$committed_total" '
      .strongest_observed as $previous
      | if $previous == null or ($epoch >= ($previous.epoch | tonumber)) then
          .strongest_observed = {epoch:$epoch,participant_weight:$participant_weight,accepted_weight_sum:$accepted_weight_sum,committed_total:$committed_total}
        else . end
    ' "$state" >"$temporary"
  mv "$temporary" "$state"
}

# A positive PoC distribution is immutable chain evidence for the bounded
# acceptance window.  Keep the first successfully reconciled transaction so
# a later, still-open epoch group cannot discard proof that was already
# established for this same participant and runtime.
join_acceptance_state_record_distribution() {
  local run="$1" stage="$2" tx_hash="$3" tx_code="$4" temporary
  local state="$run/acceptance-state.json"
  [[ "$stage" =~ ^[1-9][0-9]*$ && "$tx_hash" =~ ^[A-F0-9]{64}$ && "$tx_code" == 0 ]] || return 2
  temporary="$(mktemp "$run/.acceptance-state.tmp.XXXXXX")"
  jq --argjson stage "$stage" --arg tx_hash "$tx_hash" --argjson tx_code "$tx_code" '
    if .distribution_evidence? == null then
      .distribution_evidence = {stage:$stage,tx_hash:$tx_hash,tx_code:$tx_code}
    else . end
  ' "$state" >"$temporary"
  mv "$temporary" "$state"
}

join_acceptance_state_restore_distribution() {
  local run="$1"
  local state="$run/acceptance-state.json"
  jq -ce '
    .distribution_evidence?
    | select((.stage | tonumber) > 0)
    | select(.tx_hash | test("^[A-F0-9]{64}$"))
    | select((.tx_code | tonumber) == 0)
  ' "$state"
}

join_acceptance_state_restore_strongest() {
  local run="$1"
  local state="$run/acceptance-state.json" observations="$run/poc-acceptance-observations.json"
  if jq -e '.strongest_observed? != null and (.strongest_observed.participant_weight | tonumber) > 0' "$state" >/dev/null 2>&1; then
    jq -c '.strongest_observed' "$state"
    return 0
  fi
  [[ -s "$observations" ]] || return 1
  jq -ce '[.[]
    | select(.weight_evidence.participant_eligible == true)
    | {epoch,participant_weight:(.weight_evidence.participant_weight | tonumber),accepted_weight_sum:(.weight_evidence.accepted_weight_sum | tonumber),committed_total:(.weight_evidence.committed_total | tonumber)}]
    | max_by(.epoch) // empty' "$observations"
}
