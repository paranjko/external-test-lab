#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

check_state() {
  local raw="$1" expected="$2" actual
  actual="$(participant_onboarding_state "$raw")"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected participant status %q to classify as %s, got %s\n' "$raw" "$expected" "$actual" >&2
    return 1
  }
}

check_state '' new
check_state ACTIVE active
check_state PARTICIPANT_STATUS_ACTIVE active
check_state 1 active
check_state REGISTERED registered
check_state PARTICIPANT_STATUS_REGISTERED registered
check_state INVALID invalid
check_state PARTICIPANT_STATUS_INVALID invalid
check_state 3 invalid

printf 'PASS participant onboarding state contract\n'
