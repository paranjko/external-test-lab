#!/usr/bin/env bash
# Logs, docker events, inspect, metrics and health of the wrapper containers of one host, through a wrapper update.
# Containers come from docker ps every second and logs follow the container ID, so a recreated container gets its own
# stream from its first line. Nothing is written on the host: every command is a read over ssh with its output on stdout.
# A remote command ends when its ssh channel closes, so a stopped run leaves nothing on the host.
# Usage: remote-wrapper-watch.sh <ssh host> <new output directory>
#        remote-wrapper-watch.sh <ssh host> --leftovers
# Stop: touch <output directory>/STOP, or STOP_AFTER, MAX_SECONDS, Ctrl+C. Result: <output directory>.tar.gz and .sha256.
# Env: LOG_CONTAINERS (proxy|versiond|caddy|mlnode|-api-1|-inference-1), EXCLUDE_CONTAINERS (edge-api), VERSIONS (v4.1 v4.2 v6),
# PUBLIC_URL (https://<host without gdc->.gonka-dev.net), PROBE_PATHS, METRICS_EVERY (5), STOP_AFTER (file), STOP_DELAY (60),
# MAX_SECONDS (21600), MIN_FREE_MB (500).
set -uo pipefail

host=${1:?ssh host, e.g. gdc-node8}
out=${2:?new output directory or --leftovers}
here=$(cd "$(dirname "$0")" && pwd)
pattern=${LOG_CONTAINERS:-proxy|versiond|caddy|mlnode|-api-1|-inference-1}
exclude=${EXCLUDE_CONTAINERS:-edge-api}
versions=${VERSIONS:-v4.1 v4.2 v6}
public=${PUBLIC_URL:-https://${host#gdc-}.gonka-dev.net}
paths=${PROBE_PATHS:-devshard/healthz devshard/v4.1/healthz devshard/v4.2/healthz devshard/v6/healthz v1/versions}
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ControlPath=none)

leftovers() {
  ssh "${ssh_opts[@]}" "$host" "pgrep -af '[e]xec 3<&0|[d]ocker logs -f -t|[d]ocker events --filter type=container' | cut -c1-120; echo end-of-list" </dev/null 2>&1 |
    sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g'
}
if [ "$out" = --leftovers ]; then
  leftovers
  exit 0
fi

mkdir -p "$out/logs" "$out/inspect" || exit 1
out=$(cd "$out" && pwd)
[ ! -e "$out/STARTED" ] || { echo "$out already holds a run" >&2; exit 1; }
date -u +%FT%TZ > "$out/STARTED"
trap '' PIPE
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$out/watch.log"; }

# Public addresses become a stable hash for this run, private ones stay; values after key words are hidden.
MASK_SALT=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
export MASK_SALT
mask_py='
import hashlib, os, re, sys
salt = os.environ["MASK_SALT"].encode()
ip = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])")
private = re.compile(r"(10\.|127\.|0\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)")
auth = re.compile(r"(?i)(authorization:\s*)\S+(?:\s+[^\s\"\x27,]+)?")
secret = re.compile(r"(?i)(bearer\s+|(?:api[_-]?key|password|secret|token)[\"\x27=:\s]+)[^\s\"\x27,]+")
def one(m):
    a = m.group(0)
    return a if private.match(a) else "ip-" + hashlib.sha256(salt + a.encode()).hexdigest()[:8]
for raw in sys.stdin.buffer:
    line = secret.sub(r"\1<hidden>", auth.sub(r"\1<hidden>", ip.sub(one, raw.decode("utf-8", "replace"))))
    sys.stdout.buffer.write(line.encode())
    sys.stdout.buffer.flush()
'
mask() { python3 -u -c "$mask_py"; }

# The remote command runs in the background; when the channel closes, stdin ends and the command is killed.
held() {
  printf 'exec 3<&0; { %s\n} </dev/null & p=$!; { cat <&3; kill $p; } >/dev/null 2>&1 & w=$!; wait $p; r=$?; kill $w 2>/dev/null; exit $r' "$1"
}

mkfifo "$out/.hold" "$out/.ps"
exec 9<>"$out/.hold" 8<>"$out/.ps"
gzips=() gz_files=() groups_all=() last_group=

# start_stream <file> <once|again> <first since> <remote command with __SINCE__>
start_stream() {
  local file=$1 mode=$2 since=$3 cmd=$4 fifo
  fifo=$(mktemp -u "$out/.fifo.XXXXXX")
  mkfifo "$fifo"
  (trap '' HUP INT TERM; exec gzip -c <"$fifo" >"$file") &
  gzips+=($!) gz_files+=("$file")
  set -m
  ( (
    while [ ! -e "$out/.stop" ]; do
      ssh "${ssh_opts[@]}" "$host" "$(held "${cmd//__SINCE__/${since:+--since $since}}")" <&9 2>&1
      rc=$?
      if [ "$mode" = once ] && [ "$rc" != 255 ]; then break; fi
      lost=$(date +%s)
      echo "=== stream lost rc=$rc at $(date -u +%FT%TZ)"
      sleep 3
      since=$(($(date +%s) - lost + 30))s
    done
  ) | mask >"$fifo" ) &
  last_group=$!
  set +m
  groups_all+=("$last_group")
}

targets_sh='
targets() {
  docker ps -q | xargs -r docker inspect --format "{{.Name}}{{range \$n,\$v := .NetworkSettings.Networks}} {{\$n}} {{\$v.IPAddress}}{{end}}" |
    awk "{ip=\$3; for(i=2;i<NF;i+=2) if(\$i ~ /_default\$/) ip=\$(i+1); print substr(\$1,2), ip}" | grep -E "__PATTERN__" | grep -vE "__EXCLUDE__"
}
'
targets_sh=${targets_sh//__PATTERN__/$pattern}
targets_sh=${targets_sh//__EXCLUDE__/$exclude}

# Status code and time of every component, once a second, addresses only inside the curl call.
health_cmd=$targets_sh'
probe() { curl -s -o /dev/null -m 2 -w "$(date -u +%FT%T.%3NZ)\t$1\t$2\t%{http_code}\t%{time_total}\n" "$3"; }
while :; do
  while read -r c ip; do
    case $c in
      *caddy*) probe "$c" admin/metrics http://127.0.0.1:2019/metrics & ;;
      *-proxy-policy*) probe "$c" health "http://$ip:8081/health" & ;;
      *-proxy-[0-9]*) probe "$c" metrics "http://$ip:8405/metrics" & ;;
      *versiond-router*) probe "$c" readyz "http://$ip:8404/readyz" & ;;
      *versiond*)
        probe "$c" healthz "http://$ip:8080/healthz" &
        for v in __VERSIONS__; do probe "$c" "$v/healthz" "http://$ip:8080/$v/healthz" & done ;;
    esac
  done < <(targets)
  wait
  sleep 1
done'
health_cmd=${health_cmd//__VERSIONS__/$versions}

metrics_cmd=$targets_sh'
scrape() { echo "=== $(date -u +%FT%T.%3NZ) $1 $2"; curl -s -m 4 -w "\n=== code %{http_code}\n" "$3"; }
while :; do
  while read -r c ip; do
    case $c in
      *caddy*) scrape "$c" metrics http://127.0.0.1:2019/metrics ;;
      *-proxy-[0-9]*|*versiond-router*) scrape "$c" metrics "http://$ip:8405/metrics" ;;
      *versiond*)
        scrape "$c" metrics "http://$ip:8080/metrics"
        for v in __VERSIONS__; do scrape "$c" "$v/metrics" "http://$ip:8080/$v/metrics"; done ;;
    esac
  done < <(targets)
  sleep __EVERY__
done'
metrics_cmd=${metrics_cmd//__VERSIONS__/$versions}
metrics_cmd=${metrics_cmd//__EVERY__/${METRICS_EVERY:-5}}

events_cmd="exec docker events __SINCE__ --filter type=container --filter event=create --filter event=start --filter event=kill --filter event=die --filter event=stop --filter event=destroy --filter event=rename --filter event=restart --filter event=oom --filter event=health_status --format '{{.TimeNano}} {{.Action}} {{.Actor.ID}} {{index .Actor.Attributes \"name\"}} {{index .Actor.Attributes \"image\"}} exit={{index .Actor.Attributes \"exitCode\"}} signal={{index .Actor.Attributes \"signal\"}}'"

# Image, digest, compose labels and allowed settings. Env values pass by name and never leave for a secret-like name.
inspect_jq='.[0] | {Id, Name, Created, RestartCount, Image, ImageRef: .Config.Image,
  State: (.State | {Status, StartedAt, FinishedAt, ExitCode, OOMKilled, Error, Health: .Health.Status}),
  Networks: (.NetworkSettings.Networks | map_values(.Aliases)), Ports: .NetworkSettings.Ports,
  Labels: (.Config.Labels | with_entries(select(.key | test("^(com[.]docker[.]compose|ai[.]gonka)")))),
  Env: [.Config.Env[] | select(test("^(VERSIOND_|PROXY_|GONKA_HA=|POOL_)")) | select(test("^[^=]*(KEY|SECRET|TOKEN|PASS|PRIVATE|CRED)"; "i") | not)]}'
inspect_one="
inspect_one() {
  docker inspect \"\$1\" | jq '$inspect_jq'
  echo \"digests \$(docker image inspect --format '{{json .RepoDigests}}' \"\$(docker inspect --format '{{.Image}}' \"\$1\")\")\"
}
"
snapshot_cmd=$targets_sh$inspect_one'
echo "== $(date -u +%FT%TZ)"
docker ps -a --format "{{.ID}} {{.Names}} {{.Image}} {{.State}} {{.Status}}" | grep -E "__PATTERN__" | grep -vE "__EXCLUDE__"
wd=
while read -r c ip; do
  echo "== $c"
  inspect_one "$c"
  [ -n "$wd" ] || wd=$(docker inspect --format "{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}" "$c")
done < <(targets)
echo "== compose files"
[ -z "$wd" ] || { cd "$wd" && sha256sum compose*.yaml; for f in compose.sr.yaml compose.v6-rc1.yaml; do [ ! -f "$f" ] || { echo "-- $f"; cat "$f"; }; done; }
'
snapshot_cmd=${snapshot_cmd//__PATTERN__/$pattern}
snapshot_cmd=${snapshot_cmd//__EXCLUDE__/$exclude}

snapshot() {
  log "snapshot $1"
  ssh "${ssh_opts[@]}" "$host" "$snapshot_cmd" </dev/null 2>&1 | mask > "$out/snapshot-$1.txt"
  "$here/remote-preflight.sh" "$host" 2>&1 </dev/null | mask > "$out/preflight-$1.txt"
}

start_probes() {
  local p f
  for p in $paths; do
    f=$out/public-health.tsv
    set -m
    (last=
    while [ ! -e "$out/.stop" ]; do
      r=$(curl -s -o /dev/null -m 3 -w '%{http_code} %{time_total}' "$public/$p")
      printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$p" "${r// /$'\t'}" >> "$f"
      if [ "${r%% *}" != "$last" ]; then log "public $p ${r%% *}"; last=${r%% *}; fi
      sleep 1
    done) &
    groups_all+=($!)
    set +m
  done
}

start_ps() {
  set -m
  (while [ ! -e "$out/.stop" ]; do
    ssh "${ssh_opts[@]}" "$host" "$(held 'while :; do docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}"; echo "=== tick"; sleep 1; done')" <&9 2>/dev/null
    sleep 3
  done) >&8 &
  groups_all+=($!)
  set +m
}

declare -A follower=() last_state=() ended=() runs=() retry_at=()
ticks=0

follow() {
  local id=$1 base=$2 since=$3 n
  n=$((${runs[$id]:-0} + 1))
  runs[$id]=$n
  start_stream "$out/logs/$base.$id.$n.log.gz" once "$since" "exec docker logs -f -t __SINCE__ $id 2>&1"
  follower[$id]=$last_group
  log "logs of $base $id part $n${since:+ since $since}"
}

on_container() {
  local id=$1 name=$2 image=$3 state=$4 status=$5 base=$2 health='' now since
  [[ $name =~ ^[0-9a-f]{12}_(.+)$ ]] && base=${BASH_REMATCH[1]}
  [[ $base =~ $pattern ]] || return 0
  [[ ! $base =~ $exclude ]] || return 0
  [[ $status =~ \((healthy|unhealthy|health:\ starting)\) ]] && health=${BASH_REMATCH[1]}
  if [ "${last_state[$id]:-}" != "$name $state $health" ]; then
    if [ -n "${last_state[$id]:-}" ] || [ "$ticks" != 0 ] || [ "$state" = running ]; then
      (ssh "${ssh_opts[@]}" "$host" "$inspect_one inspect_one $id" </dev/null 2>&1 | mask > "$out/inspect/$base.$id.$(date +%s).txt") &
    fi
    last_state[$id]="$name $state $health"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$id" "$name" "$image" "$state" "$health" >> "$out/containers.tsv"
    log "$name $id $image $state $health"
  fi
  [ -z "${follower[$id]:-}" ] || return 0
  now=$(date +%s)
  [ "$now" -ge "${retry_at[$id]:-0}" ] || return 0
  if [ -n "${ended[$id]:-}" ]; then
    [ "$state" = running ] || return 0
    since=$((now - ended[$id] + 30))s
  elif [ "$ticks" = 0 ]; then
    [ "$state" = running ] || { ended[$id]=$now; return 0; }
    since=1m
  else
    since=
  fi
  follow "$id" "$base" "$since"
  retry_at[$id]=$((now + 3))
}

stopping=
trap 'stopping=signal' INT TERM HUP

start_stream "$out/docker-events.log.gz" again 1m "$events_cmd"
start_stream "$out/health.tsv.gz" again "" "$health_cmd"
start_stream "$out/metrics.log.gz" again "" "$metrics_cmd"
start_probes
start_ps
snapshot before &

started=$(date +%s) after_seen='' disk_at=0 line=''
log "watching $host, stop with: touch $out/STOP"
while [ -z "$stopping" ]; do
  now=$(date +%s)
  [ ! -e "$out/STOP" ] || stopping="STOP file"
  [ $((now - started)) -lt "${MAX_SECONDS:-21600}" ] || stopping=MAX_SECONDS
  if [ -n "${STOP_AFTER:-}" ] && [ -e "$STOP_AFTER" ]; then
    after_seen=${after_seen:-$now}
    [ $((now - after_seen)) -lt "${STOP_DELAY:-60}" ] || stopping=STOP_AFTER
  fi
  if [ $((now - disk_at)) -ge 60 ]; then
    disk_at=$now
    [ "$(df -Pk "$out" | awk 'NR==2 {print int($4/1024)}')" -ge "${MIN_FREE_MB:-500}" ] || stopping="disk under ${MIN_FREE_MB:-500} MB"
  fi
  for id in "${!follower[@]}"; do
    kill -0 -- "-${follower[$id]}" 2>/dev/null && continue
    ended[$id]=$now
    unset "follower[$id]"
  done
  IFS= read -r -t 2 line <&8 || continue
  case $line in
    '=== tick') ticks=$((ticks + 1)) ;;
    *'|'*'|'*) IFS='|' read -r c_id c_name c_image c_state c_status <<<"$line"
      on_container "$c_id" "$c_name" "$c_image" "$c_state" "$c_status" ;;
  esac
done
log "stopping: $stopping"
trap '' INT TERM HUP

snapshot after
touch "$out/.stop"
for g in "${groups_all[@]}" "${follower[@]}"; do kill -TERM -- "-$g" 2>/dev/null; done
deadline=$(($(date +%s) + 30))
for i in "${!gzips[@]}"; do
  while kill -0 "${gzips[$i]}" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
  kill -0 "${gzips[$i]}" 2>/dev/null || continue
  log "FAIL: ${gz_files[$i]##*/} still open after 30 s, killed"
  kill -9 "${gzips[$i]}" 2>/dev/null
done
rm -f "$out"/.fifo.* "$out/.hold" "$out/.ps" "$out/.stop"

for g in "$out"/*.gz "$out"/logs/*.gz; do
  gzip -t "$g" 2>/dev/null || log "FAIL: ${g##*/} does not pass gzip -t"
done
sleep 3
leftovers > "$out/leftovers.txt"
log "still on $host: $(($(wc -l < "$out/leftovers.txt") - 1)) (leftovers.txt)"
date -u +%FT%TZ > "$out/DONE"
log "done"
(cd "$out" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS)
(cd "$(dirname "$out")" && tar -czf "$(basename "$out").tar.gz" "$(basename "$out")" && sha256sum "$(basename "$out").tar.gz" > "$(basename "$out").tar.gz.sha256")
echo "archive: $out.tar.gz"
