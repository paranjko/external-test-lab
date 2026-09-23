#!/usr/bin/env bash

# Print Unix time in milliseconds without relying on date's non-portable %3N
# width handling. Some implementations emit all nine nanosecond digits for
# %3N, which turns a millisecond deadline into a nanosecond-scale value.
epoch_millis() {
  local timestamp seconds nanoseconds milliseconds extra
  timestamp="$(date '+%s %N')" || return 1
  read -r seconds nanoseconds extra <<<"$timestamp"
  [[ "$seconds" =~ ^[0-9]+$ && -z "${extra:-}" ]] || return 1
  if [[ "$nanoseconds" =~ ^[0-9]{3,9}$ ]]; then
    milliseconds="${nanoseconds:0:3}"
  else
    # BSD date prints a literal %N. Second precision is conservative and keeps
    # deadlines and freshness receipts in the documented millisecond unit.
    milliseconds=000
  fi
  printf '%s%s\n' "$seconds" "$milliseconds"
}
