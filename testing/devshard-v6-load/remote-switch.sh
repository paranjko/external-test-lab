#!/usr/bin/env bash
# Switch from the v4.2 gateway to the v6 gateway under one steady closed-loop load with cmd/wrap-load:
# phase A all workers on v4.2, B half on each gateway at once, C all on v6, then an idle tail.
# Starts in a window that fits A to C before the next PoC; a cPoC does not stop the run, chain.log marks it.
# Gateway logs of both containers are followed for the whole run.
# Usage: remote-switch.sh <gonka-devshard-contrib checkout> <output directory>
# Env: V42_ENV, V6_ENV (files with GONKA_BASE and GONKA_API_KEY), LOAD_DATASET; WORKERS (32), MINUTES (30 per phase),
# TAIL (15, idle minutes after C), WAIT (1, 0 starts at once), SETTLE (300), MARGIN (2), REQUEST_TIMEOUT (3m), POLL (15),
# GW_SSH (gdc-node0), V42_CONTAINER (park-gateway-gateway-v4-2-1), V6_CONTAINER (park-gateway-gateway-v6-1),
# CHAIN_API (https://node2.gonka-dev.net/chain-api), POC_BLOCKS (130), BLOCK_SECONDS (5.5).
set -euo pipefail

gonka=${1:?gonka-devshard-contrib checkout with devshard/testenv/cmd/wrap-load}
out=${2:?new output directory}
here=$(cd "$(dirname "$0")" && pwd)
: "${V42_ENV:?}" "${V6_ENV:?}" "${LOAD_DATASET:?}"
workers=${WORKERS:-32} minutes=${MINUTES:-30} tail_min=${TAIL:-15} settle=${SETTLE:-300}
chain=${CHAIN_API:-https://node2.gonka-dev.net/chain-api}
poc_blocks=${POC_BLOCKS:-130} block_seconds=${BLOCK_SECONDS:-5.5} poll=${POLL:-15}
gw=${GW_SSH:-gdc-node0}
declare -A env_of=([v42]=$V42_ENV [v6]=$V6_ENV)
declare -A container_of=([v42]=${V42_CONTAINER:-park-gateway-gateway-v4-2-1} [v6]=${V6_CONTAINER:-park-gateway-gateway-v6-1})
for g in v42 v6; do
  env -i bash -c 'set -a; . "$1"; : "${GONKA_BASE:?}" "${GONKA_API_KEY:?}"' _ "${env_of[$g]}" ||
    { echo "${env_of[$g]} needs GONKA_BASE and GONKA_API_KEY" >&2; exit 1; }
done
! pgrep -f '/wrap-load -scenario' > /dev/null || { echo "another wrap-load runs on this machine" >&2; exit 1; }

mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/switch.conf" ] || { echo "$out already holds a switch run" >&2; exit 1; }
dataset=$(cd "$(dirname "$LOAD_DATASET")" && pwd)/$(basename "$LOAD_DATASET")
sha256sum "$dataset" > "$out/dataset.sha256"
(cd "$gonka/devshard" && go build -o "$out/wrap-load" ./testenv/cmd/wrap-load)
git -C "$gonka" rev-parse HEAD > "$out/gonka.sha"
printf 'v42=%s\nv6=%s\nworkers=%s\nminutes=%s\ntail_min=%s\nchain=%s\n' \
  "$(env -i bash -c 'set -a; . "$1"; echo "$GONKA_BASE"' _ "$V42_ENV")" \
  "$(env -i bash -c 'set -a; . "$1"; echo "$GONKA_BASE"' _ "$V6_ENV")" \
  "$workers" "$minutes" "$tail_min" "$chain" > "$out/switch.conf"

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$out/events.log"; }

# Prints "<state> <blocks to next PoC> <height>"; state is poc, cpoc, cutoff or clear.
chain_state() {
  local info height start
  info=$(curl -fsS -m 15 "$chain/productscience/inference/inference/epoch_info") || { echo "unknown 0 0"; return; }
  height=$(jq -r .block_height <<<"$info")
  start=$(jq -r .latest_epoch.poc_start_block_height <<<"$info")
  local since=$((height - start)) next=$((start + 1500 - height))
  if [ "$(jq -r .is_confirmation_poc_active <<<"$info")" = true ]; then echo "cpoc $next $height"
  elif [ "$since" -lt "$poc_blocks" ]; then echo "poc $next $height"
  elif [ "$next" -le 20 ]; then echo "cutoff $next $height"
  else echo "clear $next $height"; fi
}

# A to C with three request timeouts of drain between phases.
need_blocks=$(awk -v m="$minutes" -v x="${MARGIN:-2}" -v b="$block_seconds" 'BEGIN { printf "%d", (3 * m + 9 + x) * 60 / b + 20 }')
wait_window() {
  local state next said="" last_blocked=0
  while :; do
    read -r state next _ < <(chain_state)
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
    sleep "$poll"
  done
}

followers=()
follow_logs() {
  local g=$1
  (while [ ! -e "$out/DONE" ]; do
    timeout 4h ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 "$gw" \
      "docker logs -f --since $(date -u +%FT%TZ) ${container_of[$g]}" < /dev/null >> "$out/gateway-$g.log" 2>&1 || true
    sleep 5
  done) &
  followers+=($!)
}

watch_chain() {
  (said=""
  printf 'time_utc\theight\tstate\tblocks_to_poc\n' > "$out/chain.tsv"
  while [ ! -e "$out/DONE" ]; do
    read -r state next height < <(chain_state)
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$height" "$state" "$next" >> "$out/chain.tsv"
    [ "$said" = "$state" ] || { log "chain: $state at $height"; said=$state; }
    sleep "$poll"
  done) &
  followers+=($!)
}

# load <run name> <gateway> <workers>: starts one wrap-load in the background, its pid goes to pids.
pids=()
load() {
  local run=$1 g=$2 w=$3
  mkdir -p "$out/.runs/$run"
  (unset "${!GONKA_@}"; set -a; . "${env_of[$g]}"; set +a
  cd "$gonka/devshard/testenv" && exec "$out/wrap-load" -scenario loadtest/scenarios/normal-load.yaml \
    -dataset "$dataset" -closed-loop -max-in-flight "$w" -duration "${minutes}m" \
    -request-timeout "${REQUEST_TIMEOUT:-3m}" -source-revision "$(cat "$out/gonka.sha")" \
    -output-parent "$out/.runs/$run" < /dev/null > "$out/$run.log" 2>&1) &
  pids+=($!)
}

phase() {
  local name=$1; shift
  log "start $name: $*"
  pids=()
  local spec
  for spec in "$@"; do load "$name-${spec%%:*}" "${spec%%:*}" "${spec#*:}"; done
  for p in "${pids[@]}"; do wait "$p" || true; done
  for spec in "$@"; do
    local run=$name-${spec%%:*} dir
    dir=$(ls -d "$out/.runs/$run"/run-* 2>/dev/null | head -1 || true)
    if [ -z "$dir" ]; then log "end $run: no run directory, see $run.log"; continue; fi
    mv "$dir" "$out/$run"
    log "end $run: $(tail -2 "$out/$run.log" | tr '\n' ' ')"
    python3 "$here/remote-ladder-table.py" "$out/$run" --windows 300 > "$out/$run.windows.tsv"
  done
}

follow_logs v42
follow_logs v6
watch_chain
[ "${WAIT:-1}" = 0 ] || wait_window
half=$((workers / 2))
phase A v42:"$workers"
phase B v42:"$half" v6:"$((workers - half))"
phase C v6:"$workers"
log "tail: ${tail_min}m without load"
sleep "$((tail_min * 60))"
python3 "$here/remote-ladder-table.py" "$out" --runs | tee "$out/phases.tsv"
date -u +%FT%TZ > "$out/DONE"
for p in "${followers[@]}"; do pkill -P "$p" 2>/dev/null || true; done
wait
gzip -f "$out"/gateway-v42.log "$out"/gateway-v6.log
log "done"
