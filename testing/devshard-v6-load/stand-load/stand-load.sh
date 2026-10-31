#!/usr/bin/env bash
# Constant background load through one gateway, as a systemd service. Every step is one remote-loadtest run with its own
# scenario: one dataset row and a per-request suffix, because -load-dataset sends rows without a suffix and the gateway
# answers them from its cache. The next step starts on schedule, so a step that is still draining leaves no gap.
# Usage: stand-load install | check | start | stop [--now] | status
# Settings: stand-load.env.example. stop finishes the current step; stop --now ends it at once. Both also stay stopped after a reboot.
set -uo pipefail

self=$(readlink -f "$0")
here=$(dirname "$self")
root=${INSTALL_ROOT:-}
env_file=${STAND_LOAD_ENV:-$root/etc/stand-load.env}
unit=stand-load

die() { echo "stand-load: $*" >&2; exit 1; }

load_env() {
  [ -r "$env_file" ] || die "no $env_file; run install, then edit it"
  # shellcheck disable=SC1090
  . "$env_file"
  : "${GATEWAY_BASE:?}" "${MODEL:?}" "${DATASET:?}" "${KEY_FILE:?}"
  rps=${RPS:-6} step=${STEP:-5m} timeout=${REQUEST_TIMEOUT:-3m} keep_days=${KEEP_DAYS:-7}
  state=${STATE_DIR:-/srv/stand-load} bin=${LOADTEST_BIN:-/usr/local/bin/remote-loadtest}
  inflight=${MAX_IN_FLIGHT:-$(awk -v r="$rps" 'BEGIN { n = int(r * 32 + 0.999); print n < 32 ? 32 : n }')}
  [[ $rps =~ ^[0-9]+([.][0-9]+)?$ ]] || die "RPS must be a number"
  [[ $step =~ ^[1-9][0-9]*[smh]$ ]] || die "STEP must look like 5m"
  [[ $keep_days =~ ^[1-9][0-9]*$ ]] || die "KEEP_DAYS must be a whole number of days"
  [[ $state =~ ^/.+/.+ ]] || die "STATE_DIR must be an absolute path below a directory"
  results=$state/results stop_flag=$state/stop-after-step
}

read_key() {
  [ -f "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ] || die "no key file $KEY_FILE"
  [ "$(stat -c '%a:%u' "$KEY_FILE")" = "600:$(id -u)" ] || die "$KEY_FILE must be mode 600 and owned by this user"
  key=$(head -n 1 "$KEY_FILE")
  [ -n "$key" ] || die "$KEY_FILE is empty"
}

# Writes the scenario of one step; JSON is valid YAML once the characters YAML refuses are escaped.
write_scenario() {
  python3 -I - "$DATASET" "$MODEL" "$1" "$rps" "$step" "$inflight" "$timeout" "$2" <<'PY'
import json, random, re, sys
dataset, model, name, rps, step, inflight, timeout, out = sys.argv[1:]
rows = [line for line in open(dataset, encoding="utf-8") if line.strip()]
row = json.loads(random.choice(rows))
request = {"model": model, "messages": row["messages"], "stream": row["stream"], "max_tokens": row["max_tokens"]}
text = re.sub("[\x7f-\x9f\ud800-\udfff﻿￾￿]", lambda m: "\\u%04x" % ord(m.group()), json.dumps(request, ensure_ascii=False))
with open(out, "w", encoding="utf-8") as f:
    f.write(f"""schema_version: v1
scenario: {name}
seed: 42
topology:
  versiond_mode: multi
  storage: per_participant
  participants: 3
  chain: {{escrow_amount: 2000000000000000, max_nonce: 100000}}
  mock_ml:
    allocator: round_robin
    nodes: [{{name: mock-0, profile: fast}}, {{name: mock-1, profile: fast}}]
workload:
  duration: {step}
  request_timeout: {timeout}
  report_interval: 30s
  max_in_flight: {inflight}
  traffic: {{type: constant, rps: {rps}}}
  request: {text}
assertions:
  requests: {{http_status: 200, terminal_outcome: completed, error_rate: 0, dropped_rate: 0}}
drain_timeout: 3m
""")
PY
}

run_service() {
  load_env
  read_key
  [ -x "$bin" ] || die "no $bin"
  [ -r "$DATASET" ] || die "no $DATASET"
  mkdir -p "$results" || exit 1
  exec 7>"$state/run.lock"
  flock -n 7 || die "already running"
  stopping=''
  trap 'stopping=1; kill $(jobs -p) 2>/dev/null' TERM INT
  echo "start: $rps rps, $MODEL, $GATEWAY_BASE, step $step"
  while [ -z "$stopping" ] && [ ! -e "$stop_flag" ]; do
    find "$results" -mindepth 1 -maxdepth 1 -type d -name '20*' -mmin +$((keep_days * 1440)) -exec rm -rf {} +
    id=$(date -u +%Y%m%dT%H%M%SZ)
    name=stand-load-$id-$$-$RANDOM
    dir=$results/$id
    mkdir "$dir" || { sleep 1; continue; }
    if write_scenario "$name" "$dir/scenario.yaml"; then
      echo "step $id"
      GONKA_API_KEY=$key "$bin" -base "$GATEWAY_BASE" -model "$MODEL" -scenario "$dir/scenario.yaml" -duration "$step" \
        -output "$dir/run" > "$dir/run.log" 2>&1 7>&- </dev/null &
    else
      echo "step $id: no scenario written"
    fi
    sleep "$step" 7>&- &
    wait $!
  done
  wait
  echo "stopped"
  exit 0
}

status() {
  load_env
  echo "service: $(systemctl is-active $unit) / $(systemctl is-enabled $unit 2>/dev/null)$([ -e "$stop_flag" ] && echo ', stops after this step')"
  echo "processes: $(pgrep -f "[r]emote-loadtest -base" | wc -l)"
  echo "config: $rps rps, $MODEL, $GATEWAY_BASE, step $step, kept $keep_days days, $(du -sh "$results" 2>/dev/null | cut -f1)"
  printf '%-18s %8s %8s %6s %6s %6s %6s %7s %7s\n' step offered "done" failed drop rps err% p50_s p95_s
  find "$results" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | LC_ALL=C sort | tail -n "${1:-6}" | while read -r d; do
    if [ -s "$d/run/summary.json" ]; then
      jq -r --arg id "${d##*/}" '[$id, .offered_requests, .completed, .failed, .dropped_by_generator,
        (.completed / (.duration / 1e9) * 100 | round / 100), (.error_rate * 10000 | round / 100),
        (.p50_latency / 1e7 | round / 100), (.p95_latency / 1e7 | round / 100)] | @tsv' "$d/run/summary.json" |
        awk -F'\t' '{printf "%-18s %8s %8s %6s %6s %6s %6s %7s %7s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9}'
    else
      echo "${d##*/}  running or ended without a summary; $d/run.log"
    fi
  done
}

check() {
  load_env
  read_key
  [ -x "$bin" ] && echo "PASS $bin" || echo "FAIL no $bin"
  [ -r "$DATASET" ] && echo "PASS dataset, $(grep -c . "$DATASET") rows" || echo "FAIL no $DATASET"
  if printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -fsS -m 20 -K - "$GATEWAY_BASE/v1/models" | jq -e --arg m "$MODEL" '.data[] | select(.id == $m)' >/dev/null; then
    echo "PASS $GATEWAY_BASE lists $MODEL"
  else
    echo "FAIL $GATEWAY_BASE does not list $MODEL with this key"
  fi
}

install_service() {
  ln -sf "$self" "$root/usr/local/bin/stand-load"
  install -m 644 "$here/stand-load.service" "$root/etc/systemd/system/stand-load.service"
  [ -e "$env_file" ] || install -m 600 "$here/stand-load.env.example" "$env_file"
  load_env
  install -d -m 700 "$state" "$results"
  systemctl daemon-reload
  echo "installed; edit $env_file, put the key in $KEY_FILE (mode 600), then: stand-load check"
}

case ${1:-} in
  install) install_service ;;
  check) check ;;
  start)
    load_env
    rm -f "$stop_flag"
    systemctl enable --now $unit ;;
  stop)
    load_env
    systemctl disable $unit
    if [ "${2:-}" = --now ]; then
      systemctl stop $unit
    elif [ "$(systemctl is-active $unit)" = active ]; then
      touch "$stop_flag"
      echo "stops when the current step ends"
    fi ;;
  status) status "${2:-6}" ;;
  _run) run_service ;;
  *) sed -n 5p "$self" >&2; exit 2 ;;
esac
