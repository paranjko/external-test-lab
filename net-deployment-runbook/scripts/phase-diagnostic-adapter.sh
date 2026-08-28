#!/usr/bin/env bash
# Translate a known lifecycle phase to typed diagnostic metadata. The adapter
# only consumes structured phase identifiers and an exit code; it never parses
# terminal prose or raw logs.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -eq 3 ]] || { echo "usage: $0 OUTPUT PHASE EXIT_CODE" >&2; exit 2; }
output="$1" phase="$2" exit_code="$3"
[[ "$phase" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo 'unsafe phase identifier' >&2; exit 1; }
[[ "$exit_code" =~ ^[1-9][0-9]*$ && "$exit_code" -le 255 ]] || { echo 'unsafe exit code' >&2; exit 1; }

family=observability
category=unknown
decision=not_applicable
case "$phase" in
  genesis*) family='genesis'; category='configuration'; decision='manual_action_required' ;;
  *qualification*|prepare*) family='qualification'; category='dependency'; decision='manual_action_required' ;;
  join*|operator-state-recovery*) family='join'; category='identity'; decision='manual_action_required' ;;
  *poc*) family='poc'; category='chain'; decision='manual_action_required' ;;
  gateway*|settle*) family='gateway'; category='network'; decision='manual_action_required' ;;
  *upgrade*|governance*|vote*) family='upgrade'; category='chain'; decision='manual_action_required' ;;
  bridge*) family='bridge'; category='dependency'; decision='manual_action_required' ;;
  *observability*|verify*|audit*) family='observability'; category='network' ;;
esac

"$ROOT/scripts/diagnostic-envelope.sh" write "$output" "$family" "$phase" terminal interrupted "$category" shell "$exit_code" "$decision" none 'Phase stopped before a terminal result; unavailable observations are intentionally recorded as unavailable.'
