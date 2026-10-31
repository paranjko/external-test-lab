#!/usr/bin/env bash
# Steady closed-loop load through a live gateway with cmd/wrap-load, only between PoC windows.
# Starts when no PoC or cPoC runs, SETTLE seconds have passed since the last one and the run ends before the
# next PoC; a PoC or cPoC during the run stops it, keeps the partial artifacts and starts the run again.
# Usage: remote-soak.sh <gonka-devshard-contrib checkout> <output directory>
# Env: GONKA_BASE, GONKA_API_KEY, LOAD_DATASET; WORKERS (32), MINUTES (60), SETTLE (300), ATTEMPTS (3),
# MARGIN (2, minutes left before the next PoC), REQUEST_TIMEOUT (3m), POLL (15),
# CHAIN_API (https://node2.gonka-dev.net/chain-api), POC_BLOCKS (130), BLOCK_SECONDS (5.5).
set -euo pipefail

gonka=${1:?gonka-devshard-contrib checkout with devshard/testenv/cmd/wrap-load}
out=${2:?new output directory}
here=$(cd "$(dirname "$0")" && pwd)
: "${GONKA_BASE:?}" "${GONKA_API_KEY:?}" "${LOAD_DATASET:?}"
workers=${WORKERS:-32} minutes=${MINUTES:-60} settle=${SETTLE:-300} attempts=${ATTEMPTS:-3}
chain=${CHAIN_API:-https://node2.gonka-dev.net/chain-api}
poc_blocks=${POC_BLOCKS:-130} block_seconds=${BLOCK_SECONDS:-5.5}

mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/soak.conf" ] || { echo "$out already holds a soak run" >&2; exit 1; }
dataset=$(cd "$(dirname "$LOAD_DATASET")" && pwd)/$(basename "$LOAD_DATASET")
sha256sum "$dataset" > "$out/dataset.sha256"
(cd "$gonka/devshard" && go build -o "$out/wrap-load" ./testenv/cmd/wrap-load)
git -C "$gonka" rev-parse HEAD > "$out/gonka.sha"
printf 'base=%s\nworkers=%s\nminutes=%s\nsettle_s=%s\nattempts=%s\nchain=%s\n' \
  "$GONKA_BASE" "$workers" "$minutes" "$settle" "$attempts" "$chain" > "$out/soak.conf"

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$out/events.log"; }

# Prints "<state> <blocks to next PoC>"; state is poc, cpoc, cutoff or clear.
chain_state() {
  local info height start
  info=$(curl -fsS -m 15 "$chain/productscience/inference/inference/epoch_info") || { echo "unknown 0"; return; }
  height=$(jq -r .block_height <<<"$info")
  start=$(jq -r .latest_epoch.poc_start_block_height <<<"$info")
  local since=$((height - start)) next=$((start + 1500 - height))
  if [ "$(jq -r .is_confirmation_poc_active <<<"$info")" = true ]; then echo "cpoc $next"
  elif [ "$since" -lt "$poc_blocks" ]; then echo "poc $next"
  elif [ "$next" -le 20 ]; then echo "cutoff $next"
  else echo "clear $next"; fi
}

need_blocks=$(awk -v m="$minutes" -v x="${MARGIN:-2}" -v b="$block_seconds" 'BEGIN { printf "%d", (m + x) * 60 / b + 20 }')
last_blocked=0
wait_window() {
  local state next said=""
  while :; do
    read -r state next < <(chain_state)
    if [ "$state" != clear ]; then
      last_blocked=$(date +%s)
      [ "$said" = "$state" ] || { log "waiting: $state"; said=$state; }
    elif [ $(( $(date +%s) - last_blocked )) -lt "$settle" ]; then
      [ "$said" = settle ] || { log "waiting: ${settle}s after PoC"; said=settle; }
    elif [ "$next" -lt "$need_blocks" ]; then
      [ "$said" = short ] || { log "waiting: next PoC in $next blocks, the run needs $need_blocks"; said=short; }
    else
      return 0
    fi
    sleep "${POLL:-15}"
  done
}

for attempt in $(seq 1 "$attempts"); do
  wait_window
  run=$(printf 'attempt%d' "$attempt")
  log "start $run: $workers workers, ${minutes}m"
  (cd "$gonka/devshard/testenv" && exec "$out/wrap-load" -scenario loadtest/scenarios/normal-load.yaml \
    -dataset "$dataset" -closed-loop -max-in-flight "$workers" -duration "${minutes}m" \
    -request-timeout "${REQUEST_TIMEOUT:-3m}" -source-revision "$(cat "$out/gonka.sha")" \
    -output-parent "$out/.runs" < /dev/null > "$out/$run.log" 2>&1) &
  pid=$!
  stopped=""
  while kill -0 "$pid" 2>/dev/null; do
    read -r state _ < <(chain_state)
    if [ "$state" = poc ] || [ "$state" = cpoc ]; then
      stopped=$state
      last_blocked=$(date +%s)
      log "stop $run: $state"
      kill -INT "$pid" 2>/dev/null || true
      for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 5; done
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    sleep "${POLL:-15}"
  done
  wait "$pid" 2>/dev/null || true
  dir=$(ls -d "$out"/.runs/run-* 2>/dev/null | head -1 || true)
  if [ -n "$stopped" ]; then
    [ -z "$dir" ] || mv "$dir" "$out/$run-stopped-$stopped"
    continue
  fi
  [ -n "$dir" ] || { log "end $run: no run directory, see $run.log"; break; }
  mv "$dir" "$out/$run"
  log "end $run: $(tail -2 "$out/$run.log" | tr '\n' ' ')"
  python3 "$here/remote-ladder-table.py" "$out/$run" --windows 300 | tee "$out/windows.tsv"
  break
done
date -u +%FT%TZ > "$out/DONE"
