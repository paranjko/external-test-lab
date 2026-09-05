#!/usr/bin/env bash
# Validate and compare public TMKMS anti-double-sign state without coercing
# its decimal string heights through a lossy shell or JSON number.
set -Eeuo pipefail

usage() { echo "Usage: $0 --minimum FILE --observed FILE [--fence-height HEIGHT] [--require-advance]" >&2; }
minimum=''; observed=''; fence_height=''
require_advance=false
while (($#)); do
  case "$1" in
    --minimum) minimum="${2:-}"; shift 2 ;;
    --observed) observed="${2:-}"; shift 2 ;;
    --fence-height) fence_height="${2:-}"; shift 2 ;;
    --require-advance) require_advance=true; shift ;;
    *) usage; exit 2 ;;
  esac
done
[[ -f "$minimum" && ! -L "$minimum" && -f "$observed" && ! -L "$observed" ]] || { usage; exit 2; }
[[ -z "$fence_height" || "$fence_height" =~ ^[0-9]+$ ]] || { usage; exit 2; }

validate_state() {
  jq -e '
    type == "object" and (keys | sort) == ["block_id","height","round","step"] and
    (.height | type == "string" and test("^[0-9]+$")) and
    (.round | type == "string" and test("^[0-9]+$")) and
    (.step | type == "number" and floor == . and . >= -128 and . <= 127) and
    (.block_id == null or (
      (.block_id | type == "object") and
      (.block_id.hash | type == "string" and test("^[0-9A-Fa-f]{64}$")) and
      ((.block_id.parts // .block_id.part_set_header) as $parts |
        ($parts | type == "object") and ($parts.total | type == "number" and floor == . and . >= 0) and
        ($parts.hash | type == "string" and test("^[0-9A-Fa-f]{64}$")))
    ))
  ' "$1" >/dev/null
}

normalize_decimal() {
  local value="$1"
  while [[ "$value" == 0* && ${#value} -gt 1 ]]; do value="${value#0}"; done
  [[ -n "$value" ]] || value=0
  printf '%s\n' "$value"
}

decimal_compare() {
  local left right
  left="$(normalize_decimal "$1")"; right="$(normalize_decimal "$2")"
  if ((${#left} < ${#right})); then printf '%s\n' -1; return; fi
  if ((${#left} > ${#right})); then printf '%s\n' 1; return; fi
  if [[ "$left" < "$right" ]]; then printf '%s\n' -1
  elif [[ "$left" > "$right" ]]; then printf '%s\n' 1
  else printf '%s\n' 0
  fi
}

validate_state "$minimum" || { echo 'invalid minimum TMKMS signing state' >&2; exit 1; }
validate_state "$observed" || { echo 'invalid observed TMKMS signing state' >&2; exit 1; }
minimum_height="$(jq -r .height "$minimum")"; observed_height="$(jq -r .height "$observed")"
minimum_round="$(jq -r .round "$minimum")"; observed_round="$(jq -r .round "$observed")"
minimum_step="$(jq -r .step "$minimum")"; observed_step="$(jq -r .step "$observed")"
height_cmp="$(decimal_compare "$observed_height" "$minimum_height")"
if (( height_cmp < 0 )); then echo 'TMKMS signing state regressed in height' >&2; exit 1; fi
if (( height_cmp == 0 )); then
  round_cmp="$(decimal_compare "$observed_round" "$minimum_round")"
  if (( round_cmp < 0 )); then echo 'TMKMS signing state regressed in round' >&2; exit 1; fi
  if (( round_cmp == 0 && observed_step < minimum_step )); then echo 'TMKMS signing state regressed in step' >&2; exit 1; fi
  if (( round_cmp == 0 && observed_step == minimum_step )); then
    minimum_hash="$(jq -r '.block_id.hash? // empty | ascii_downcase' "$minimum")"
    observed_hash="$(jq -r '.block_id.hash? // empty | ascii_downcase' "$observed")"
    [[ -z "$minimum_hash" || -z "$observed_hash" || "$minimum_hash" == "$observed_hash" ]] || {
      echo 'TMKMS signing state has a conflicting block identity at the same tuple' >&2; exit 1;
    }
  fi
fi
if [[ -n "$fence_height" ]] && (( $(decimal_compare "$observed_height" "$fence_height") < 0 )); then
  echo 'TMKMS signing state is behind the external signer fence height' >&2; exit 1
fi
if [[ "$require_advance" == true && "$height_cmp" -eq 0 ]]; then
  round_cmp="$(decimal_compare "$observed_round" "$minimum_round")"
  if (( round_cmp == 0 && observed_step == minimum_step )); then
    echo 'TMKMS signing state did not advance after signer enablement' >&2
    exit 1
  fi
fi
jq -cn --slurpfile minimum "$minimum" --slurpfile observed "$observed" \
  '{state:"non_regressing",minimum:$minimum[0],observed:$observed[0]}'
