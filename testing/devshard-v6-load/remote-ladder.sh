#!/usr/bin/env bash
# Step load through a live gateway with cmd/remote-loadtest: one run per step, stop at the first degraded step.
# Usage: remote-ladder.sh <gonka checkout> <output directory> [workers ...]
# Env: GONKA_BASE, GONKA_API_KEY, GONKA_MODEL; SCENARIO, LOAD_DATASET, STEP_DURATION, REQUEST_TIMEOUT, NO_STOP=1;
# TOOL=wrap-load runs cmd/wrap-load of a gonka-devshard-contrib checkout instead: unique requests, no response cache.
set -euo pipefail

gonka=${1:?gonka checkout with devshard/testenv/cmd/remote-loadtest or cmd/wrap-load}
tool=${TOOL:-remote-loadtest}
out=${2:?new output directory}
shift 2
[ $# -gt 0 ] || set -- 2 4 8 16 24 32 48 64
steps=("$@")
here=$(cd "$(dirname "$0")" && pwd)
scenario=${SCENARIO:-$here/remote-512.yaml}
: "${GONKA_BASE:?}" "${GONKA_API_KEY:?}" "${GONKA_MODEL:?}"

mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/ladder.conf" ] || { echo "$out already holds a ladder" >&2; exit 1; }
dataset=()
if [ -n "${LOAD_DATASET:-}" ]; then
  dataset=(-load-dataset "$(cd "$(dirname "$LOAD_DATASET")" && pwd)/$(basename "$LOAD_DATASET")")
  sha256sum "${dataset[1]}" > "$out/dataset.sha256"
fi
case $tool in
  remote-loadtest) (cd "$gonka/devshard/testenv" && go build -o "$out/$tool" ./cmd/remote-loadtest) ;;
  wrap-load)
    [ -n "${LOAD_DATASET:-}" ] || { echo "wrap-load needs LOAD_DATASET" >&2; exit 1; }
    scenario=${SCENARIO:-loadtest/scenarios/normal-load.yaml}
    (cd "$gonka/devshard" && go build -o "$out/$tool" ./testenv/cmd/wrap-load) ;;
  *) echo "unknown TOOL $tool" >&2; exit 1 ;;
esac
git -C "$gonka" rev-parse HEAD > "$out/gonka.sha"
printf 'tool=%s\nbase=%s\nmodel=%s\nscenario=%s\nsteps=%s\nstep_duration=%s\nrequest_timeout=%s\n' "$tool" \
  "$GONKA_BASE" "$GONKA_MODEL" "$scenario" "${steps[*]}" "${STEP_DURATION:-4m}" "${REQUEST_TIMEOUT:-3m}" > "$out/ladder.conf"

for w in "${steps[@]}"; do
  step=$(printf 'w%03d' "$w")
  [ ! -e "$out/$step" ] || { echo "$step repeats in this ladder; repeat steps in a new output directory" >&2; exit 1; }
  echo "$(date -u +%FT%TZ) start $step"
  if [ "$tool" = wrap-load ]; then
    (cd "$gonka/devshard/testenv" && "$out/$tool" -scenario "$scenario" -dataset "${dataset[1]}" -closed-loop \
      -max-in-flight "$w" -duration "${STEP_DURATION:-4m}" -request-timeout "${REQUEST_TIMEOUT:-3m}" \
      -source-revision "$(cat "$out/gonka.sha")" -output-parent "$out/.runs" < /dev/null > "$out/$step.log" 2>&1) || true
    mv "$out"/.runs/run-* "$out/$step" 2>/dev/null || { echo "$step: no run directory, see $step.log"; break; }
  else
    (cd "$gonka/devshard/testenv" && "$out/$tool" -scenario "$scenario" "${dataset[@]}" \
      -concurrency "$w" -duration "${STEP_DURATION:-4m}" -request-timeout "${REQUEST_TIMEOUT:-3m}" \
      -report-interval 30s -output "$out/$step" < /dev/null > "$out/$step.log" 2>&1) || true
  fi
  echo "$(date -u +%FT%TZ) end $step"
  python3 "$here/remote-ladder-table.py" "$out" > "$out/ladder.tsv"
  tail -1 "$out/ladder.tsv"
  verdict=$(tail -1 "$out/ladder.tsv" | awk -F'\t' '{print $NF}')
  if [ "$verdict" != ok ] && [ "${NO_STOP:-0}" != 1 ]; then
    echo "stop: $step $verdict"
    break
  fi
done
date -u +%FT%TZ > "$out/DONE"
