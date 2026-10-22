#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${GDC_CLEAN_TARGET_DIND:-}" == true && "$EUID" == 0 && ! -e /srv/dai ]] || {
  echo 'Run only inside the isolated privileged clean-target DIND fixture' >&2
  exit 2
}

dockerd-entrypoint.sh dockerd >/tmp/clean-target-dockerd.log 2>&1 &
daemon=$!
for _ in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
docker info >/dev/null || { cat /tmp/clean-target-dockerd.log >&2; exit 1; }
image='busybox@sha256:222ad6d973c0d198014546a65cd02c5fdedcc172123c5b4c2bf0af636550bd94'
docker pull "$image" >/dev/null
mkdir -p /srv/dai /var/lib/node_exporter/textfile_collector

containers=()
cleanup() {
  ((${#containers[@]} == 0)) || docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
  kill "$daemon" 2>/dev/null || true
}
trap cleanup EXIT

clean_check() {
  local role="$1" alias="$2" edge_flag="${3:-}"
  local args=(--host-alias "$alias" --role "$role")
  [[ -z "$edge_flag" ]] || args+=(--public-edge-owner)
  bash "$ROOT/00-host-prep/check-join-target-clean.sh" "${args[@]}"
}
expect_ready() {
  local role="$1" alias="$2" edge_flag="${3:-}"
  local out=/tmp/join-clean-test-output
  clean_check "$role" "$alias" "$edge_flag" >"$out" 2>&1 || {
    cat "$out" >&2
    rm -f "$out"
    return 1
  }
  grep -Fq 'READY JOIN target is clean' "$out" || { cat "$out" >&2; rm -f "$out"; return 1; }
  rm -f "$out"
}
expect_refused() {
  local role="$1" alias="$2" edge_flag="${3:-}"
  local out=/tmp/join-clean-test-output
  if clean_check "$role" "$alias" "$edge_flag" >"$out" 2>&1; then
    echo 'clean-target accepted an unsafe fixture' >&2
    rm -f "$out"
    return 1
  fi
  grep -Fq 'JOIN_TARGET_NOT_CLEAN' "$out"
  rm -f "$out"
}
start_container() {
  local name="$1" project="$2" service="$3"; shift 3
  docker run -d --name "$name" \
    --label "com.docker.compose.project=$project" \
    --label "com.docker.compose.service=$service" "$@" "$image" sleep 300 >/dev/null
  containers+=("$name")
}
stop_containers() {
  ((${#containers[@]} == 0)) || docker rm -f "${containers[@]}" >/dev/null
  containers=()
}

expect_ready validator gdc-node-test
mkdir -p /srv/dai/inference
expect_refused validator gdc-node-test
rmdir /srv/dai/inference

start_container validator-project gdc-node-test node
expect_refused validator gdc-node-test
stop_containers

mkdir -p /srv/dai/data
start_container unknown-overlap unknown-project worker -v /srv/dai/data:/state
expect_refused validator gdc-node-test
stop_containers
rmdir /srv/dai/data

start_container independent faucet-project faucet -v /tmp:/tmp:ro
expect_ready validator gdc-node-test
stop_containers
start_container independent-inference independent inference -v /tmp:/tmp:ro
expect_ready validator gdc-node-test
stop_containers

start_container monitor-good gdc-monitoring-agent cadvisor \
  -v /:/rootfs:ro -v /sys:/sys:ro -v /dev/disk:/dev/disk:ro \
  -v /var/run:/var/run:ro -v /var/lib/docker:/var/lib/docker:ro
expect_ready ml-only-donor gdc-node-donor
stop_containers
start_container monitor-bad gdc-monitoring-agent cadvisor -v /:/rootfs:rw
expect_refused ml-only-donor gdc-node-donor
stop_containers

mkdir -p /srv/dai/edge/public-grafana/provisioning /srv/dai/edge/public-grafana/dashboards \
  /srv/dai/caddy/config /srv/dai/caddy/data /srv/dai/edge/site /srv/dai/edge/status
touch /srv/dai/edge/compose.yaml /srv/dai/edge/Caddyfile
start_container edge-good gdc-edge caddy \
  -v /srv/dai/caddy/config:/config -v /srv/dai/caddy/data:/data \
  -v /srv/dai/edge:/edge:ro -v /srv/dai/edge/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /srv/dai/edge/site:/srv/dai/edge/site:ro
expect_ready validator gdc-node-edge --public-edge-owner
expect_refused validator gdc-node-edge
stop_containers
start_container edge-unknown independent worker -v /srv/dai/edge:/edge:ro
expect_refused validator gdc-node-edge --public-edge-owner
stop_containers
start_container edge-bad gdc-edge caddy -v /srv/dai/edge:/edge:rw
expect_refused validator gdc-node-edge --public-edge-owner

echo 'PASS isolated Docker clean-target canonical/legacy role layouts'
