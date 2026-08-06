#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 BASELINE_GROUP PRE_PARTICIPANTS POST_GROUP POST_PARTICIPANTS OUTPUT_DIR MODEL_ID MAX_POWER_CHANGE_PERCENT" >&2
}

[[ $# -eq 7 ]] || { usage; exit 2; }
BASELINE_GROUP="$1"
PRE_PARTICIPANTS="$2"
POST_GROUP="$3"
POST_PARTICIPANTS="$4"
OUTPUT_DIR="$5"
MODEL_ID="$6"
MAX_POWER_CHANGE_PERCENT="$7"

for input in "$BASELINE_GROUP" "$PRE_PARTICIPANTS" "$POST_GROUP" "$POST_PARTICIPANTS"; do
  [[ -s "$input" ]] || { echo "error: missing upgrade comparison input: $input" >&2; exit 2; }
done
[[ "$MAX_POWER_CHANGE_PERCENT" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || { echo 'error: MAX_POWER_CHANGE_PERCENT must be non-negative' >&2; exit 2; }
mkdir -p "$OUTPUT_DIR"

# Participant identity and ACTIVE state are durable upgrade invariants. The
# Comet validator set and current epoch group are deliberately not compared as
# identical point-in-time sets: Gonka derives them again every PoC and may
# legitimately rotate a participant between adjacent epochs.
jq -n \
  --slurpfile before "$PRE_PARTICIPANTS" \
  --slurpfile after "$POST_PARTICIPANTS" '
  def active($doc):
    [$doc.participant[]
     | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1")
     | {address,validator_key}]
    | sort_by(.address);
  (active($before[0])) as $b
  | (active($after[0])) as $a
  | {same_active_participants:($a == $b),before:$b,after:$a}
' >"$OUTPUT_DIR/participant-comparison.json"
jq -e '.same_active_participants and (.before | length > 0)' \
  "$OUTPUT_DIR/participant-comparison.json" >/dev/null \
  || { echo 'error: ACTIVE participant identity or validator keys changed across upgrade' >&2; exit 1; }

# Use the accepted baseline verify bundle for power comparison. An arbitrary
# pre-upgrade epoch snapshot can be missing a normally rotated validator and is
# therefore observation data, not a stable baseline. PASS requires the full
# prepared ACTIVE set to have positive committed PoC power after the upgrade.
jq -n \
  --slurpfile baseline "$BASELINE_GROUP" \
  --slurpfile after "$POST_GROUP" \
  --slurpfile participants "$PRE_PARTICIPANTS" \
  --arg model "$MODEL_ID" \
  --argjson limit "$MAX_POWER_CHANGE_PERCENT" '
  def weights($doc):
    [$doc.epoch_group_data.validation_weights[]?
     | {key:.member_address,value:(.weight | tonumber)}]
    | from_entries;
  def models($doc): ($doc.epoch_group_data.sub_group_models // []);
  ([$participants[0].participant[]
    | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1")
    | .address] | sort) as $expected
  | (weights($baseline[0])) as $b
  | (weights($after[0])) as $a
  | [$expected[] as $address
     | {address:$address,
        before:($b[$address] // 0),
        after:($a[$address] // 0),
        percent:(if ($b[$address] // 0) == 0
                 then 100
                 else (((($a[$address] // 0)-$b[$address]) | abs) * 100 / $b[$address])
                 end)}] as $changes
  | {
      model:$model,
      model_present_before:(models($baseline[0]) | index($model) != null),
      model_present_after:(models($after[0]) | index($model) != null),
      same_prepared_set:(($b | keys | sort) == $expected and ($a | keys | sort) == $expected),
      all_positive:([$changes[] | .before > 0 and .after > 0] | all),
      claimed_total_before:($baseline[0].epoch_group_data.total_weight | tonumber),
      claimed_total_after:($after[0].epoch_group_data.total_weight | tonumber),
      total_before:([$changes[].before] | add),
      total_after:([$changes[].after] | add),
      limit_percent:$limit,
      changes:$changes
    }
' >"$OUTPUT_DIR/power-comparison.json"

jq -e '
  . as $root
  | .model_present_before
    and .model_present_after
    and .same_prepared_set
    and .all_positive
    and (.claimed_total_before == .total_before)
    and (.claimed_total_after == .total_after)
    and (([.changes[].percent] | max) <= $root.limit_percent)
    and (((.total_after - .total_before) | abs) * 100 / .total_before <= .limit_percent)
' "$OUTPUT_DIR/power-comparison.json" >/dev/null \
  || { echo 'error: post-upgrade prepared miner set or PoC power violates the rehearsal threshold' >&2; exit 1; }

printf 'PASS upgrade participant and PoC power comparison\n'
