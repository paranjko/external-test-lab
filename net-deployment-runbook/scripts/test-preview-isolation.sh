#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
provisioner="$root/ops/chore/user-preview.sh"
controller="$root/ops/preview/previewctl.sh"
compose_file="$root/ops/preview/compose.yaml"
caddyfile="$root/ops/preview/Caddyfile"
egress_caddyfile="$root/ops/preview/egress.Caddyfile"

for file in "$provisioner" "$controller"; do
  bash -n "$file"
done

grep -Fq 'PREVIEW_USER="${PREVIEW_USER:-preview}"' "$provisioner"
grep -Fq 'preview user must not belong to the privileged docker group' "$provisioner"
grep -Fq 'dockerd-rootless-setuptool.sh install' "$provisioner"
grep -Fq 'systemctl --user enable --now docker' "$provisioner"
grep -Fq 'admin unix//run/gdc-preview/admin.sock' "$caddyfile"
grep -Fq 'admin off' "$egress_caddyfile"
grep -Fq 'path /gonka-api /gonka-api/*' "$egress_caddyfile"
grep -Fq 'path_regexp preview_node ^/preview/[1-9][0-9]*/node/(node[0-9]+)(/.*)$' "$egress_caddyfile"
grep -Fq 'reverse_proxy gdc-preview-node-guard:8090' "$egress_caddyfile"
! grep -Fq 'reverse_proxy {http.vars.node_host}:443' "$egress_caddyfile"
grep -Fq 'query query=gdc_nvidia_memory_total_bytes' "$egress_caddyfile"
grep -Fq "expression \`query({'query':'gdc_nvidia_memory_total_bytes unless (time() - timestamp(gdc_nvidia_memory_total_bytes) > 120)'})\`" "$egress_caddyfile"
grep -Fq 'query query=gdc_component_info' "$egress_caddyfile"
grep -Fq '127.0.0.1:${PREVIEW_CADDY_PORT:-18090}:8080' "$compose_file"

if grep -r -En -- '--privileged|network_mode:[[:space:]]*host|/var/run/docker.sock|docker\.sock:' \
  "$compose_file" "$controller" "$caddyfile" "$egress_caddyfile"; then
  echo 'preview runtime must not expose privileged Docker or host networking' >&2
  exit 1
fi

for option in --read-only --cap-drop --security-opt --pids-limit --memory --cpus; do
  grep -Fq -- "$option" "$controller"
done
grep -Fq -- '--log-driver local' "$controller"
for resource in 'pids_limit: 128' 'mem_limit: 256m' 'cpus: 0.5' 'driver: local'; do
  grep -Fq -- "$resource" "$compose_file"
done
grep -Fq 'PREVIEW_OBSERVATION_BASE=http://gdc-preview-egress:8080/gonka-api' "$controller"
grep -Fq 'gdc-preview-node-observation-guard:local' "$controller"
grep -Fq 'gdc-preview-node-guard' "$controller"
grep -Fq 'immutable local image ID' "$controller"
grep -Fq 'State.Health.Status' "$controller"
grep -Fq 'routes.lock' "$controller"
grep -Fq 'pr-$pr.lock' "$controller"
grep -Fq 'flock -n -x 9' "$controller"

image="${PREVIEW_CADDY_IMAGE:-caddy:2.11.4-alpine}"
docker run --rm -v "$caddyfile:/etc/caddy/Caddyfile:ro" "$image" \
  caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
docker run --rm -e PREVIEW_OBSERVATION_HOST=api.gonka-dev.net -e PREVIEW_PROMETHEUS_ORIGIN=http://127.0.0.1:9099 \
  -v "$egress_caddyfile:/etc/caddy/Caddyfile:ro" "$image" \
  caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

egress_port=$((20000 + ($$ % 1000)))
egress_container="gdc-preview-egress-policy-$$"
cleanup_egress() {
  docker rm -f "$egress_container" >/dev/null 2>&1 || true
}
trap cleanup_egress EXIT
docker run -d --name "$egress_container" -p "127.0.0.1:$egress_port:8080" \
  -e PREVIEW_OBSERVATION_HOST=api.gonka-dev.net \
  -e PREVIEW_PROMETHEUS_ORIGIN=http://127.0.0.1:9 \
  -v "$egress_caddyfile:/etc/caddy/Caddyfile:ro" "$image" \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
for _ in $(seq 1 20); do
  curl --silent --show-error --max-time 1 "http://127.0.0.1:$egress_port/gonka-api/" >/dev/null 2>&1 && break
  sleep 1
done
approved_status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$egress_port/prometheus/api/v1/query?query=gdc_component_info")"
[[ "$approved_status" == 502 ]] || { echo "approved Prometheus query returned HTTP $approved_status" >&2; exit 1; }
approved_status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$egress_port/prometheus/api/v1/query?query=gdc_nvidia_memory_total_bytes%20unless%20(time()%20-%20timestamp(gdc_nvidia_memory_total_bytes)%20%3E%20120)")"
[[ "$approved_status" == 502 ]] || { echo "approved fresh GPU query returned HTTP $approved_status" >&2; exit 1; }
for query in \
  'last_over_time(gdc_nvidia_memory_total_bytes%5B24h%5D)' \
  'max_over_time(timestamp(gdc_component_info)%5B24h%3A15s%5D)'; do
  approved_status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$egress_port/prometheus/api/v1/query?query=$query")"
  [[ "$approved_status" == 502 ]] || { echo "approved retained Prometheus query returned HTTP $approved_status: $query" >&2; exit 1; }
done
rejected_status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$egress_port/prometheus/api/v1/query?query=up")"
[[ "$rejected_status" == 404 ]] || { echo "unapproved Prometheus query returned HTTP $rejected_status" >&2; exit 1; }
rejected_node_status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$egress_port/preview/172/node/not-a-node/health")"
[[ "$rejected_node_status" == 404 ]] || { echo "unapproved node route returned HTTP $rejected_node_status" >&2; exit 1; }

printf 'PASS preview isolation static contracts and Caddy configuration\n'
