#!/usr/bin/env bash
# Step load through a live gateway with cmd/remote-loadtest: one run per step, stop at the first degraded step.
# Usage: remote-ladder.sh <gonka checkout> <output directory> [workers ...]
# Env: GONKA_BASE, GONKA_API_KEY, GONKA_MODEL; SCENARIO, LOAD_DATASET, STEP_DURATION, REQUEST_TIMEOUT, NO_STOP=1.
set -euo pipefail

gonka=${1:?gonka-ai/gonka checkout with devshard/testenv/cmd/remote-loadtest}
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
(cd "$gonka/devshard/testenv" && go build -o "$out/remote-loadtest" ./cmd/remote-loadtest)
git -C "$gonka" rev-parse HEAD > "$out/gonka.sha"
printf 'base=%s\nmodel=%s\nscenario=%s\nsteps=%s\nstep_duration=%s\nrequest_timeout=%s\n' \
  "$GONKA_BASE" "$GONKA_MODEL" "$scenario" "${steps[*]}" "${STEP_DURATION:-4m}" "${REQUEST_TIMEOUT:-3m}" > "$out/ladder.conf"

for w in "${steps[@]}"; do
  step=$(printf 'w%03d' "$w")
  [ ! -e "$out/$step" ] || { echo "$step repeats in this ladder; repeat steps in a new output directory" >&2; exit 1; }
  echo "$(date -u +%FT%TZ) start $step"
  (cd "$gonka/devshard/testenv" && "$out/remote-loadtest" -scenario "$scenario" "${dataset[@]}" \
    -concurrency "$w" -duration "${STEP_DURATION:-4m}" -request-timeout "${REQUEST_TIMEOUT:-3m}" \
    -report-interval 30s -output "$out/$step" < /dev/null > "$out/$step.log" 2>&1) || true
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
