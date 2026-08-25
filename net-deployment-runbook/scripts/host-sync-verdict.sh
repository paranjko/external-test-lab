#!/usr/bin/env bash
# Shared, deterministic Host synchronization acceptance predicate.
set -Eeuo pipefail

host_sync_record() {
  local host="$1" first_height="$2" height="$3" central_height="$4" block_time="$5" now="$6" catching="$7"
  local lag block_age
  [[ "$first_height" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ && "$central_height" =~ ^[0-9]+$ ]] || return 2
  [[ "$block_time" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$catching" =~ ^(true|false)$ ]] || return 2
  lag=$(( central_height - height )); (( lag < 0 )) && lag=$(( -lag ))
  block_age=$(( now - block_time ))
  jq -nc --arg host "$host" --argjson first_height "$first_height" --argjson height "$height" \
    --argjson lag "$lag" --argjson block_age_seconds "$block_age" --argjson catching_up "$catching" \
    '{host:$host,first_height:$first_height,height:$height,lag:$lag,block_age_seconds:$block_age_seconds,catching_up:$catching_up,progressing:($height > $first_height)}'
}

host_sync_accepts() {
  local first_height="$1" height="$2" central_height="$3" block_time="$4" now="$5" catching="$6" max_age="$7"
  local record
  [[ "$max_age" =~ ^[1-9][0-9]*$ ]] || return 2
  record="$(host_sync_record host "$first_height" "$height" "$central_height" "$block_time" "$now" "$catching")" || return $?
  jq -e --argjson max_age "$max_age" '
    .lag <= 5 and .block_age_seconds >= 0 and .block_age_seconds <= $max_age
    and .progressing == true and .catching_up == false
  ' <<<"$record" >/dev/null
}
