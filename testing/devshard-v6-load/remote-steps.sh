#!/usr/bin/env bash
# Constant-rate steps through one live gateway with cmd/wrap-load: ramp to each rate, hold it, hold the last rate longest.
# wrap-load takes one rate per run, so every ramp slice and every hold is its own run, started on schedule; a run that
# is still draining overlaps the next one. A hold whose errors pass STOP_PCT (PoC and cPoC 503 not counted) stops the
# steps: running runs are interrupted and no new ones start.
# Usage: remote-steps.sh <gonka-devshard-contrib checkout> <output directory> <env file with GONKA_BASE and GONKA_API_KEY>
# Env: LOAD_DATASET; STEPS ("5 10 15 20 25 30"), RAMP (60), RAMP_SLICES (6), HOLD (300), LAST_HOLD (3600),
# MAX_IN_FLIGHT (1024, per run), STOP_PCT (20), REQUEST_TIMEOUT (3m), START_AFTER (file to wait for), START_DELAY (0),
# GATEWAY_SSH and GATEWAY_CONTAINER (follow the gateway log), LOG_HOSTS (ssh hosts whose wrapper, API and ML node logs are
# followed), LOG_CONTAINERS (mlnode|versiond|proxy|-api-1), CHAIN_API (https://node2.gonka-dev.net/chain-api), POLL (15).
# Logs are followed from the start of the steps and written as .log.gz that stays complete if the run is killed.
set -euo pipefail

gonka=${1:?gonka-devshard-contrib checkout with devshard/testenv/cmd/wrap-load}
out=${2:?new output directory}
envfile=${3:?env file with GONKA_BASE and GONKA_API_KEY}
here=$(cd "$(dirname "$0")" && pwd)
: "${LOAD_DATASET:?}"
read -ra steps <<<"${STEPS:-5 10 15 20 25 30}"
ramp=${RAMP:-60} slices=${RAMP_SLICES:-6} hold=${HOLD:-300} last_hold=${LAST_HOLD:-3600}
inflight=${MAX_IN_FLIGHT:-1024} stop_pct=${STOP_PCT:-20} poll=${POLL:-15}
chain=${CHAIN_API:-https://node2.gonka-dev.net/chain-api}
env -i bash -c 'set -a; . "$1"; : "${GONKA_BASE:?}" "${GONKA_API_KEY:?}"' _ "$envfile" ||
  { echo "$envfile needs GONKA_BASE and GONKA_API_KEY" >&2; exit 1; }

mkdir -p "$out"
out=$(cd "$out" && pwd)
[ ! -e "$out/steps.conf" ] || { echo "$out already holds a steps run" >&2; exit 1; }
dataset=$(cd "$(dirname "$LOAD_DATASET")" && pwd)/$(basename "$LOAD_DATASET")
sha256sum "$dataset" > "$out/dataset.sha256"
(cd "$gonka/devshard" && go build -o "$out/wrap-load" ./testenv/cmd/wrap-load)
git -C "$gonka" rev-parse HEAD > "$out/gonka.sha"

# plan.tsv: run name, start offset in seconds, duration in seconds, rate.
printf 'run\tstart_s\tduration_s\trps\n' > "$out/plan.tsv"
t=0 prev=0 slice=$((ramp / slices))
for s in "${steps[@]}"; do
  for i in $(seq 1 "$slices"); do
    rate=$(awk -v a="$prev" -v b="$s" -v i="$i" -v n="$slices" 'BEGIN { printf "%.3f", a + (b - a) * i / n }')
    printf 'R-%02d-%d\t%d\t%d\t%s\n' "$s" "$i" "$t" "$slice" "$rate" >> "$out/plan.tsv"
    t=$((t + slice))
  done
  d=$hold; [ "$s" = "${steps[-1]}" ] && d=$last_hold
  printf 'S-%02d\t%d\t%d\t%s\n' "$s" "$t" "$d" "$s" >> "$out/plan.tsv"
  t=$((t + d)) prev=$s
done
printf 'base=%s\nsteps=%s\nramp_s=%s slices=%s hold_s=%s last_hold_s=%s\nmax_in_flight=%s stop_pct=%s\ntotal_s=%s\n' \
  "$(env -i bash -c 'set -a; . "$1"; echo "$GONKA_BASE"' _ "$envfile")" "${steps[*]}" "$ramp" "$slices" "$hold" \
  "$last_hold" "$inflight" "$stop_pct" "$t" > "$out/steps.conf"

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$out/events.log"; }

followers=() gzips=()
kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill "$1" 2>/dev/null || true; }
stop_followers() {
  touch "$out/.followers-stop"
  for p in "${followers[@]}"; do kill_tree "$p"; done
  for p in "${gzips[@]}"; do wait "$p" 2>/dev/null || true; done
  followers=() gzips=()
}
trap stop_followers EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

# gzip ignores HUP, INT and TERM and ends when its writer closes, so the file gets its trailer even in a killed session.
follow_gz() {
  local file=$1 fifo
  shift
  fifo=$(mktemp -u "$out/.fifo.XXXXXX")
  mkfifo "$fifo"
  (trap '' HUP INT TERM; exec gzip -c < "$fifo" > "$file") &
  gzips+=($!)
  (exec > "$fifo"; rm -f "$fifo"
  while [ ! -e "$out/.followers-stop" ]; do
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 "$@" < /dev/null 2>&1 || true
    sleep 5
  done) &
  followers+=($!)
}

(printf 'time_utc\theight\tpoc_start\tcpoc_active\n' > "$out/chain.tsv"
while [ ! -e "$out/.followers-stop" ]; do
  info=$(curl -fsS -m 15 "$chain/productscience/inference/inference/epoch_info" 2>/dev/null || echo '{}')
  printf '%s\t%s\n' "$(date -u +%FT%TZ)" \
    "$(jq -r '[.block_height, .latest_epoch.poc_start_block_height, .is_confirmation_poc_active] | @tsv' <<<"$info" 2>/dev/null)" >> "$out/chain.tsv"
  sleep "$poll"
done) &
followers+=($!)

if [ -n "${START_AFTER:-}" ]; then
  log "waiting for $START_AFTER"
  until [ -e "$START_AFTER" ]; do sleep 5; done
fi
[ "${START_DELAY:-0}" = 0 ] || { log "waiting ${START_DELAY}s"; sleep "$START_DELAY"; }

if [ -n "${GATEWAY_SSH:-}" ] && [ -n "${GATEWAY_CONTAINER:-}" ]; then
  follow_gz "$out/gateway.log.gz" "$GATEWAY_SSH" "docker logs -f -t --since 10s $GATEWAY_CONTAINER"
fi
host_cmd='for c in $(docker ps --format "{{.Names}}" | grep -E "PATTERN" | grep -v edge-api); do
  (t=1m; while :; do docker logs -f -t --since $t $c 2>&1; t=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "=== detached $t"; sleep 2; done) |
  sed -u "s/^/$c /" & done; wait'
host_cmd=${host_cmd/PATTERN/${LOG_CONTAINERS:-mlnode|versiond|proxy|-api-1}}
for h in ${LOG_HOSTS:-}; do follow_gz "$out/host-$h.log.gz" "$h" "$host_cmd"; done

# Share of a finished hold that failed or was dropped, PoC and cPoC refusals left out.
failed_pct() {
  python3 - "$1/requests.jsonl" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
rows = [r for r in rows if "temporarily unavailable during" not in (r.get("error") or "")]
bad = sum(r["outcome"] in ("error", "dropped_by_generator") for r in rows)
print(f"{100 * bad / len(rows):.1f}" if rows else "100.0")
EOF
}

watchers=()
watch_hold() {
  local name=$1 pid=$2
  (while kill -0 "$pid" 2>/dev/null; do sleep 5; done
  dir=$(ls -d "$out/.runs/$name"/run-* 2>/dev/null | head -1 || true)
  [ -n "$dir" ] || { log "$name: no run directory"; exit 0; }
  pct=$(failed_pct "$dir")
  log "$name: ${pct}% failed or dropped (PoC refusals not counted)"
  awk -v p="$pct" -v l="$stop_pct" 'BEGIN { exit !(p > l) }' && { echo "$name $pct" > "$out/STOP"; log "stop: $name over ${stop_pct}%"; }
  exit 0) &
  watchers+=($!)
}

date -u +%FT%TZ > "$out/STARTED"
t0=$(date +%s)
pids=()
while IFS=$'\t' read -r name start dur rate; do
  until [ $(( $(date +%s) - t0 )) -ge "$start" ] || [ -e "$out/STOP" ]; do sleep 1; done
  [ ! -e "$out/STOP" ] || break
  log "start $name: ${rate} rps, ${dur}s"
  mkdir -p "$out/.runs/$name"
  (unset "${!GONKA_@}"; set -a; . "$envfile"; set +a
  cd "$gonka/devshard/testenv" && exec "$out/wrap-load" -scenario loadtest/scenarios/normal-load.yaml \
    -dataset "$dataset" -rps "$rate" -max-in-flight "$inflight" -duration "${dur}s" \
    -request-timeout "${REQUEST_TIMEOUT:-3m}" -source-revision "$(cat "$out/gonka.sha")" \
    -output-parent "$out/.runs/$name" < /dev/null > "$out/$name.log" 2>&1) &
  pids+=($!)
  case $name in S-*) watch_hold "$name" "$!" ;; esac
done < <(tail -n +2 "$out/plan.tsv")

if [ -e "$out/STOP" ]; then
  log "stopping: $(cat "$out/STOP")"
  for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done
fi
for p in "${pids[@]}" "${watchers[@]}"; do wait "$p" 2>/dev/null || true; done
mkdir -p "$out/all"
: > "$out/all/requests.jsonl"
for d in "$out"/.runs/*/run-*; do
  [ -d "$d" ] || continue
  name=$(basename "$(dirname "$d")")
  mv "$d" "$out/$name"
  cat "$out/$name/requests.jsonl" >> "$out/all/requests.jsonl"
done
python3 "$here/remote-ladder-table.py" "$out" --runs | tee "$out/runs.tsv"
python3 "$here/remote-ladder-table.py" "$out/all" --windows 60 > "$out/windows.tsv"
stop_followers
date -u +%FT%TZ > "$out/DONE"
log "done"
