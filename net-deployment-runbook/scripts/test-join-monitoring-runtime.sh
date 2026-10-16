#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
collector="gdc-monitoring-fixture-$$"
prometheus="$collector-prometheus"
cleanup() {
  local result=$?
  if (( result != 0 )); then docker logs "$prometheus" >&2 || true; fi
  docker rm -f "$prometheus" "$collector" >/dev/null 2>&1 || true
  rm -rf -- "$stage"
  exit "$result"
}
trap cleanup EXIT
image="$(sed -n 's/^PROMETHEUS_IMAGE=//p' "$ROOT/profiles/operator-services/gdc-lab.lock")"
mkdir -p "$stage/targets/join/"{host,cadvisor,gonka-node}
{
  printf 'global:\n  scrape_interval: 1s\nscrape_configs:\n'
  for job in host cadvisor gonka-node; do
    printf '  - job_name: %s\n    file_sd_configs:\n      - files: ["/etc/prometheus/targets/join/%s/*.json"]\n        refresh_interval: 1s\n' "$job" "$job"
  done
} >"$stage/prometheus.yml"
chmod 0644 "$stage/prometheus.yml"
chmod 0755 "$stage/targets" "$stage/targets/join" "$stage/targets/join/"{host,cadvisor,gonka-node}
cat >"$stage/exporters.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread
from time import sleep

class Metrics(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4')
        self.end_headers()
        self.wfile.write(b'gdc_monitoring_fixture 1\n')
    def log_message(self, *args):
        pass

for port in (9101, 8088, 26660):
    Thread(target=HTTPServer(('0.0.0.0', port), Metrics).serve_forever, daemon=True).start()
while True:
    sleep(60)
PY
docker run -d --name "$collector" --entrypoint python3 \
  -v "$stage/exporters.py:/exporters.py:ro" \
  -v "$stage/targets:/srv/dai/ops/prometheus/targets" \
  gdc-runbook-bats:local /exporters.py >/dev/null
docker run -d --name "$prometheus" --network "container:$collector" \
  -v "$stage/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$stage/targets:/etc/prometheus/targets:ro" \
  "$image" --config.file=/etc/prometheus/prometheus.yml --web.listen-address=:9099 >/dev/null
export GDC_MONITORING_FIXTURE_CONTAINER="$collector"
ssh() {
  [[ "$*" == '-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 '* ]] || return 90
  shift 8
  [[ "$1" == collector-fixture && $# == 2 ]] || return 91
  docker exec "$GDC_MONITORING_FIXTURE_CONTAINER" bash -c 'sudo() { [[ "$1" == -n ]] && shift; "$@"; }; eval "$1"' bash "$2"
}
scp() {
  shift 8
  [[ "$1" == -q && $# == 5 && "$5" == collector-fixture:/tmp/gdc-monitoring-targets-* ]] || return 92
  local destination="${5#collector-fixture:}" file
  for file in "$2" "$3" "$4"; do
    docker cp "$file" "$GDC_MONITORING_FIXTURE_CONTAINER:$destination" >/dev/null
  done
}
export -f ssh scp
for attempt in {1..20}; do
  if bash "$ROOT/scripts/register-join-monitoring-targets.sh" --registry-host collector-fixture --check >/dev/null 2>&1; then break; fi
  (( attempt == 20 )) || sleep 1
done
bash "$ROOT/scripts/register-join-monitoring-targets.sh" --registry-host collector-fixture --check
# Discovery is independent of the participant's deployment layout
for layout in deploy node; do
  docker exec "$collector" mkdir -p "/srv/dai/$layout"
  bash "$ROOT/scripts/register-join-monitoring-targets.sh" --registry-host collector-fixture \
    --node "fixture-$layout" --public-host 127.0.0.1
  bash "$ROOT/scripts/register-join-monitoring-targets.sh" --registry-host collector-fixture \
    --node "fixture-$layout" --public-host 127.0.0.1
  for job in host cadvisor gonka-node; do
    jq -e --arg host "fixture-$layout" 'length == 1 and .[0].labels.host == $host' \
      "$stage/targets/join/$job/fixture-$layout.json" >/dev/null
  done
done
printf 'PASS real Prometheus discovers JOIN targets and accepts idempotent retries independently of Host layout\n'
