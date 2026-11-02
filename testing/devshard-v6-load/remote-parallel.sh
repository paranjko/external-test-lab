#!/usr/bin/env bash
# The same closed-loop load through several live gateways at once with cmd/wrap-load, one run per gateway.
# Starts in a window that fits the run before the next PoC; a cPoC does not stop the run, chain.tsv marks it.
# Gateway logs are followed for the whole run.
# Usage: remote-parallel.sh <gonka-devshard-contrib checkout> <output directory> <name>:<env file>:<workers>:<ssh host>:<container> ...
# The env file holds GONKA_BASE and GONKA_API_KEY of that gateway.
# Env: LOAD_DATASET; MINUTES (30), WAIT (1, 0 starts at once), SETTLE (300), MARGIN (2), REQUEST_TIMEOUT (3m), POLL (15),
# CHAIN_API (https://node2.gonka-dev.net/chain-api), POC_BLOCKS (130), BLOCK_SECONDS (5.5).
set -euo pipefail

gonka=${1:?gonka-devshard-contrib checkout with devshard/testenv/cmd/wrap-load}
out=${2:?new output directory}
shift 2
[ $# -gt 0 ] || { echo "give at least one <name>:<env file>:<workers>:<ssh host>:<container>" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
: "${LOAD_DATASET:?}"
minutes=${MINUTES:-30} settle=${SETTLE:-300}
chain=${CHAIN_API:-https://node2.gonka-dev.net/chain-api}
poc_blocks=${POC_BLOCKS:-130} block_seconds=${BLOCK_SECONDS:-5.5} poll=${POLL:-15}
names=()
declare -A env_of workers_of ssh_of container_of
for spec in "$@"; do
  IFS=: read -r n e w h c <<<"$spec"
  [ -n "$c" ] && [ -f "$e" ] || { echo "bad spec or missing env file: $spec" >&2; exit 1; }
  env -i bash -c 'set -a; . "$1"; : "${GONKA_BASE:?}" "${GONKA_API_KEY:?}"' _ "$e" ||
    { echo "$e needs GONKA_BASE and GONKA_API_KEY" >&2; exit 1; }
  names+=("$n") env_of[$n]=$e workers_of[$n]=$w ssh_of[$n]=$h container_of[$n]=$c
done
! pgrep -f '/wrap-load -scenario' > /dev/null || { echo "another wrap-load runs on this machine" >&2; exit 1; }

mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/parallel.conf" ] || { echo "$out already holds a parallel run" >&2; exit 1; }
dataset=$(cd "$(dirname "$LOAD_DATASET")" && pwd)/$(basename "$LOAD_DATASET")
sha256sum "$dataset" > "$out/dataset.sha256"
(cd "$gonka/devshard" && go build -o "$out/wrap-load" ./testenv/cmd/wrap-load)
git -C "$gonka" rev-parse HEAD > "$out/gonka.sha"
{ printf 'minutes=%s\nchain=%s\n' "$minutes" "$chain"
  for n in "${names[@]}"; do
    printf '%s=%s workers=%s logs=%s/%s\n' "$n" "$(env -i bash -c 'set -a; . "$1"; echo "$GONKA_BASE"' _ "${env_of[$n]}")" \
      "${workers_of[$n]}" "${ssh_of[$n]}" "${container_of[$n]}"
  done; } > "$out/parallel.conf"

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

need_blocks=$(awk -v m="$minutes" -v x="${MARGIN:-2}" -v b="$block_seconds" 'BEGIN { printf "%d", (m + 3 + x) * 60 / b + 20 }')
wait_window() {
  local state next said="" last_blocked=0
  while :; do
    read -r state next _ < <(chain_state)
    if [ "$state" != clear ] && [ "$state" != cpoc ]; then
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
  local n=$1
  (while [ ! -e "$out/DONE" ]; do
    timeout 4h ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 "${ssh_of[$n]}" \
      "docker logs -f --since $(date -u +%FT%TZ) ${container_of[$n]}" < /dev/null >> "$out/gateway-$n.log" 2>&1 || true
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

for n in "${names[@]}"; do follow_logs "$n"; done
watch_chain
[ "${WAIT:-1}" = 0 ] || wait_window
pids=()
for n in "${names[@]}"; do
  log "start P-$n: ${workers_of[$n]} workers, ${minutes}m"
  mkdir -p "$out/.runs/$n"
  (unset "${!GONKA_@}"; set -a; . "${env_of[$n]}"; set +a
  cd "$gonka/devshard/testenv" && exec "$out/wrap-load" -scenario loadtest/scenarios/normal-load.yaml \
    -dataset "$dataset" -closed-loop -max-in-flight "${workers_of[$n]}" -duration "${minutes}m" \
    -request-timeout "${REQUEST_TIMEOUT:-3m}" -source-revision "$(cat "$out/gonka.sha")" \
    -output-parent "$out/.runs/$n" < /dev/null > "$out/P-$n.log" 2>&1) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
for n in "${names[@]}"; do
  dir=$(ls -d "$out/.runs/$n"/run-* 2>/dev/null | head -1 || true)
  if [ -z "$dir" ]; then log "end P-$n: no run directory, see P-$n.log"; continue; fi
  mv "$dir" "$out/P-$n"
  log "end P-$n: $(tail -2 "$out/P-$n.log" | tr '\n' ' ')"
  python3 "$here/remote-ladder-table.py" "$out/P-$n" --windows 300 > "$out/P-$n.windows.tsv"
done
python3 "$here/remote-ladder-table.py" "$out" --runs | tee "$out/runs.tsv"
date -u +%FT%TZ > "$out/DONE"
for p in "${followers[@]}"; do pkill -P "$p" 2>/dev/null || true; done
wait
for n in "${names[@]}"; do gzip -f "$out/gateway-$n.log"; done
log "done"
