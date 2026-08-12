#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
  echo 'usage: check-validation-weight-evidence.sh <epoch-group.json> <participant-address>' >&2
  exit 2
}

group="$1"
participant="$2"
[[ -s "$group" && "$participant" =~ ^gonka1[0-9a-z]{20,90}$ ]] || {
  echo 'epoch-group evidence or participant address is invalid' >&2
  exit 2
}

jq -e --arg participant "$participant" '
  .epoch_group_data as $group
  | ($group.validation_weights | if type == "array" then . else error("validation_weights is not an array") end) as $weights
  | ($group.total_weight | tonumber) as $committed_total
  | ([ $weights[] | .weight | tonumber ] | add // 0) as $accepted_weight_sum
  | ([ $weights[] | select(.member_address == $participant) | .weight | tonumber ] | add // 0) as $participant_weight
  | {
      participant_address:$participant,
      participant_weight:$participant_weight,
      accepted_weight_sum:$accepted_weight_sum,
      committed_total:$committed_total,
      distribution_integrity:($accepted_weight_sum == $committed_total),
      participant_eligible:($participant_weight > 0 and $accepted_weight_sum > 0 and $accepted_weight_sum == $committed_total)
    }
' "$group"
