#!/usr/bin/env bash
# Every typed summary the runbook writes must pass the reporter's own scanner.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
source <(sed -n '/^scan_public_text()/,/^}/p' "$ROOT/scripts/gdc-report-github.sh")
declare -F scan_public_text >/dev/null || { echo 'the report scanner could not be lifted out of the reporter' >&2; exit 1; }

# Prove the scanner is the real one before trusting a pass from it.
printf 'abandon ability able about above absent absorb abstract absurd abuse access accident\n' >"$tmp/twelve-words.txt"
if scan_public_text "$tmp/twelve-words.txt"; then
  echo 'the lifted scanner accepts twelve plain words; this contract would prove nothing' >&2
  exit 1
fi

checked=0 refused=0
check() { # origin, text
  local origin="$1" text="$2"
  [[ -n "$text" ]] || return 0
  checked=$((checked + 1))
  (( ${#text} <= 240 )) || { printf 'FAIL %s: %d characters exceed the envelope bound: %s\n' "$origin" "${#text}" "$text" >&2; refused=$((refused + 1)); return 0; }
  printf '%s\n' "$text" >"$tmp/summary.txt"
  scan_public_text "$tmp/summary.txt" || {
    printf 'FAIL %s: the report scanner would refuse this summary: %s\n' "$origin" "$text" >&2
    refused=$((refused + 1))
  }
}

# JOIN preflight: the summary is the first quoted sentence after each call.
preflight=0
while IFS= read -r text; do
  preflight=$((preflight + 1))
  check 'gdc.sh run_join_preflight' "$text"
done < <(awk '
  /run_join_preflight [a-z-]+ / { grab = 1 }
  grab && match($0, /\047[^\047]{20,}\047/) { print substr($0, RSTART + 1, RLENGTH - 2); grab = 0 }
' "$ROOT/gdc.sh")
(( preflight >= 10 )) || { printf 'only %d JOIN preflight summaries were found; the extractor has drifted\n' "$preflight" >&2; exit 1; }

# The launcher placeholder for a phase that recorded nothing of its own.
adapter="$(sed -n "s/.* none '\\(Phase stopped[^']*\\)'.*/\\1/p" "$ROOT/scripts/phase-diagnostic-adapter.sh")"
[[ -n "$adapter" ]] || { echo 'the adapter summary could not be found' >&2; exit 1; }
check 'phase-diagnostic-adapter.sh' "$adapter"

# Static JOIN refusals; the composed ones are measured in test-join-refusal-diagnostics.sh.
refusals=0
while IFS= read -r text; do
  refusals=$((refusals + 1))
  # A local-state clause is interpolated at run time; stand in its longest form.
  check 'phase-join.sh refusal' "${text//\$join_local_state/identity record present, cold account present, joined marker present}"
done < <(grep -o "Host JOIN stopped before any change: [^'\"]*" "$ROOT/scripts/phase-join.sh" | grep -v 'printf' | sort -u)
(( refusals >= 3 )) || { printf 'only %d JOIN refusal summaries were found; the extractor has drifted\n' "$refusals" >&2; exit 1; }

(( refused == 0 )) || { printf '%d of %d diagnostic summaries cannot be published\n' "$refused" "$checked" >&2; exit 1; }
printf 'PASS every diagnostic summary the runbook writes passes the report scanner (%d summaries)\n' "$checked"
