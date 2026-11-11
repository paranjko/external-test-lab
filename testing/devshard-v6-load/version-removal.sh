#!/usr/bin/env bash
# Does the gateway stop sending requests to a DevShard version after it leaves the approved list?
# Usage: GONKA_DIR=<gonka-ai/gonka checkout> ./version-removal.sh [output dir]
set -euo pipefail

: "${GONKA_DIR:?set GONKA_DIR to a gonka-ai/gonka checkout}"
OBSERVE_SECONDS="${OBSERVE_SECONDS:-300}"
BASELINE_SECONDS="${BASELINE_SECONDS:-60}"
EPOCH_STEPS="${EPOCH_STEPS:-3}"
ROUTER_ALLOW_REMOVALS="${ROUTER_ALLOW_REMOVALS:-1}"
KEEP_STACK="${KEEP_STACK:-0}"
PORT_BASE="${PORT_BASE:-40000}"
VERSION=v2
hp() { echo $(($1 % 10000 + PORT_BASE)); }
ROUTER=http://127.0.0.1:$(hp 8080)
GATEWAY=http://127.0.0.1:$(hp 8081)
DAPI=http://127.0.0.1:$(hp 9100)
CHAIN=http://127.0.0.1:$(hp 9191)

OUT="${1:-version-removal-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"
TESTENV="$GONKA_DIR/devshard/testenv"
TAG="vr-$(git -C "$GONKA_DIR" rev-parse --short HEAD)"
PROJECT="$TAG-$(date -u +%H%M%S)"
SUMMARY="$OUT/summary.txt"

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$OUT/progress.log"; }
compose() { (cd "$TESTENV" && docker compose -p "$PROJECT" "$@"); }

wait_until() {
  local what=$1 timeout=$2; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS > deadline)); then log "FAIL timeout: $what"; exit 1; fi
    sleep 2
  done
  log "ready: $what"
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time "${MAX_TIME:-5}" "$@"; }
router_ok() { [[ "$(http_code "$ROUTER/$VERSION/healthz")" == 200 ]]; }
router_gone() { [[ "$(http_code "$ROUTER/$VERSION/healthz")" != 200 ]]; }
gateway_up() { [[ "$(http_code "$GATEWAY/v1/status")" == 200 ]]; }
chat_ok() { [[ "$(chat)" == 200 ]]; }

admin_key() { grep '^TESTENV_ADMIN_API_KEY=' "$TESTENV/.env" | cut -d= -f2-; }
gateway_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(compose ps -q devshardctl)"; }

chat() {
  MAX_TIME=60 http_code "$GATEWAY/v1/chat/completions" -H "Authorization: Bearer $(admin_key)" \
    -H 'Content-Type: application/json' \
    -d '{"model":"test-model","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
}

snapshot() {
  curl -s --max-time 5 -H "Authorization: Bearer $(admin_key)" "$GATEWAY/v1/admin/devshards" >"$OUT/$1-devshards.json" || true
  curl -s --max-time 5 "$GATEWAY/v1/status" >"$OUT/$1-status.json" || true
}

# Counts the gateway's requests in the router access log between two UTC timestamps.
# HAProxy routers (v5+) log "ip:port [date] ... status ... "request"", nginx (v4) logs "ip - - [date] "request" status".
phase() {
  local name=$1 since=$2 until=$3 seconds=$4 ip lines
  ip="$(gateway_ip)"
  lines="$OUT/$name-requests.txt"
  compose logs --no-log-prefix --since "$since" --until "$until" versiond-router 2>/dev/null |
    awk -v ip="$ip" 'index($0, ip ":") == 1 || index($0, ip " ") == 1 {
      d = substr($0, index($0, "[") + 1, 20); split($0, q, "\""); split(q[2], r, " ")
      if ($0 ~ /^[0-9.]+:[0-9]+ \[/) st = $6; else { split(q[3], t, " "); st = t[1] }
      print d, r[1], r[2], st
    }' >"$lines" || true
  awk '{print $2, $3, $4}' "$lines" | sed -E 's#/sessions/[^/]+/#/sessions/*/#' | sort | uniq -c | sort -rn >"$OUT/$name-paths.txt"
  local healthz max_s posts statuses
  healthz=$(grep -cE " GET /(devshard/)?$VERSION/healthz " "$lines" || true)
  max_s=$(grep -E " GET /(devshard/)?$VERSION/healthz " "$lines" | awk '{print $1}' | uniq -c | sort -rn | awk 'NR==1{print $1}' || true)
  posts=$(grep -cE " POST /(devshard/)?$VERSION/" "$lines" || true)
  statuses=$(awk '{print $4}' "$lines" | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')
  printf '%-14s seconds=%-4s requests=%-6s healthz=%-6s healthz_per_s=%-6s healthz_max_s=%-3s post=%-5s statuses=%s devshards=%s\n' \
    "$name" "$seconds" "$(wc -l <"$lines" | tr -d ' ')" "$healthz" "$(awk -v n="$healthz" -v s="$seconds" 'BEGIN{printf "%.2f", n/s}')" \
    "${max_s:-0}" "$posts" "${statuses:-none}" \
    "$(jq 'if type=="array" then length elif .devshards then (.devshards|length) else "?" end' "$OUT/$name-devshards.json" 2>/dev/null || echo '?')" |
    tee -a "$SUMMARY"
}

observe() {
  local name=$1 seconds=$2 since
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "observe $name for ${seconds}s"
  sleep "$seconds"
  snapshot "$name"
  phase "$name" "$since" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$seconds"
}

cleanup() {
  local rc=$?
  compose logs --no-log-prefix devshardctl >"$OUT/gateway.log" 2>&1 || true
  if ((rc != 0)); then
    compose logs >"$OUT/compose.log" 2>&1 || true
    echo "result: FAIL rc=$rc, see progress.log and compose.log" >>"$SUMMARY"
  fi
  if [[ "$KEEP_STACK" != 1 ]]; then compose down -v >/dev/null 2>&1 || true; fi
  exit "$rc"
}

{
  echo "gonka: $(git -C "$GONKA_DIR" rev-parse --short HEAD) $(git -C "$GONKA_DIR" describe --tags --always 2>/dev/null)"
  echo "started: $(date -u +%FT%TZ) project=$PROJECT observe=${OBSERVE_SECONDS}s epochs=$EPOCH_STEPS router_allow_removals=$ROUTER_ALLOW_REMOVALS"
} | tee "$SUMMARY"

trap cleanup EXIT
trap 'log "FAIL line $LINENO: $BASH_COMMAND"' ERR
log "build stack"
# Compose mounts ./config.yaml; a failed run leaves Docker's empty directory in its place.
if [[ -d "$TESTENV/config.yaml" ]]; then rmdir "$TESTENV/config.yaml"; fi
(cd "$TESTENV" && go run ./cmd/gencompose -config config.yaml && make build-devshardd) </dev/null >>"$OUT/build.log" 2>&1
# Own image tags and project keep a parallel harness run on :latest untouched.
sed -i -E "s#(image: devshard-[a-z-]+):latest#\1:$TAG#" "$TESTENV/docker-compose.yml"
sed -i '/^\s*VERSIOND_FORCE:/d' "$TESTENV/docker-compose.yml"
# Published ports move to PORT_BASE+ so the node's own services and harness stacks keep theirs.
perl -pi -e 's/^(\s*- ")(\d+):(\d+)"/$1.(($2 % 10000)+'"$PORT_BASE"').":$3\""/e' "$TESTENV/docker-compose.yml"
while read -r port; do
  if ss -ltn | awk '{print $4}' | grep -qE "[:.]$port\$"; then log "FAIL port $port is busy"; exit 1; fi
done < <(grep -oE '^\s*- "[0-9]+:' "$TESTENV/docker-compose.yml" | grep -oE '[0-9]+')
if [[ "$ROUTER_ALLOW_REMOVALS" == 1 ]]; then
  sed -i '/VERSIOND_ROUTING_CATALOG_POLL_SECONDS:/a\      VERSIOND_ROUTING_CATALOG_ALLOW_REMOVALS: "true"' "$TESTENV/docker-compose.yml"
fi
compose build >>"$OUT/build.log" 2>&1
compose up -d --wait >>"$OUT/build.log" 2>&1

wait_until "router serves $VERSION" 300 router_ok
wait_until "gateway status" 300 gateway_up
wait_until "first chat" 300 chat_ok
for _ in 1 2 3 4; do echo "chat $(chat)" >>"$OUT/progress.log"; done

observe baseline "$BASELINE_SECONDS"

log "remove $VERSION from the approved list"
curl -s -X POST "$DAPI/testenv/versions" -H 'Content-Type: application/json' \
  -d '{"versions":[{"name":"v-pending","binary":"http://mock-dapi:9100/testenv/binaries/missing.zip","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}' \
  >>"$OUT/progress.log"
wait_until "router stops serving $VERSION" 180 router_gone
echo "router after removal: $(http_code "$ROUTER/$VERSION/healthz")" | tee -a "$SUMMARY"
observe removed "$OBSERVE_SECONDS"

log "restart gateway"
compose restart devshardctl >>"$OUT/progress.log" 2>&1
wait_until "gateway status after restart" 300 gateway_up
observe restarted "$OBSERVE_SECONDS"

for i in $(seq "$EPOCH_STEPS"); do
  log "advance epoch $i/$EPOCH_STEPS"
  curl -s -X POST "$CHAIN/testenv/epoch" -H 'Content-Type: application/json' -d '{"advance":true}' >>"$OUT/progress.log"
  sleep 40
done
observe after-epochs "$OBSERVE_SECONDS"

retired=$(compose logs --no-log-prefix devshardctl 2>/dev/null | grep -c escrow_epoch_retention_retire || true)
echo "retention_retire_lines=$retired" | tee -a "$SUMMARY"
echo "finished: $(date -u +%FT%TZ)" | tee -a "$SUMMARY"
