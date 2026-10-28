#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp_root="${TMPDIR:-$ROOT/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gateway-metrics-render.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

inventory="$tmp/inventory.env"
cp "$ROOT/.env.example" "$inventory"
cat >>"$inventory" <<'EOF'
GDC_NODE_ALIASES='gdc-node4 gdc-node0'
GDC_NODE_PUBLIC_HOSTS='gdc-node4=gdc-node4.example.test gdc-node0=gdc-node0.example.test'
GDC_NODE_P2P_PORTS='gdc-node4=5000 gdc-node0=5000'
GDC_NODE_ML_HOSTS=
GDC_GENESIS_NODE=gdc-node4
GDC_GATEWAY_NODE=gdc-node4
GDC_PUBLIC_EDGE_NODE=gdc-node4
GDC_TELEGRAM_BOT_HOST=gdc-node4
SITE_HOST=status.example.test
API_HOST=api.example.test
GRAFANA_HOST=grafana.example.test
MONITORING_CIDR=127.0.0.1/32
PUBLIC_EDGE_CIDR=127.0.0.1/32
GDC_MONITORING_DOCKER_CIDR=172.21.0.0/16
CHAIN_ID=gonka-fixture
MODEL_ID=Qwen/Qwen3-0.6B
GDC_GATEWAY_METRICS_TARGETS='[{"id":"A","node":"gdc-node4","port":18087},{"id":"B","node":"gdc-node0","port":18088}]'
EOF

"$ROOT/04-ops/render-ops.sh" --inventory "$inventory" --output-dir "$tmp/rendered" >/dev/null
grep -Fq 'metrics_path: /ops-gateway-metrics' "$tmp/rendered/prometheus.yml"
grep -Fq "targets: ['gdc-node4.example.test:443']" "$tmp/rendered/prometheus.yml"
grep -Fq "labels: {gateway: 'A', host: 'gdc-node4'}" "$tmp/rendered/prometheus.yml"
grep -Fq "targets: ['gdc-node0.example.test:443']" "$tmp/rendered/prometheus.yml"
grep -Fq "labels: {gateway: 'B', host: 'gdc-node0'}" "$tmp/rendered/prometheus.yml"
grep -Fq 'job_name: gateway-admission-route' "$tmp/rendered/prometheus.yml"
grep -Fq 'metrics_path: /ops-gateway-admission-metrics' "$tmp/rendered/prometheus.yml"
grep -Fq "labels: {route: 'S', host: 'gdc-node4'}" "$tmp/rendered/prometheus.yml"
grep -Fq 'job_name: gateway-route' "$tmp/rendered/prometheus.yml"
grep -Fq 'metrics_path: /ops-gateway-route-metrics' "$tmp/rendered/prometheus.yml"
grep -Fq "labels: {route: 'A', host: 'gdc-node4'}" "$tmp/rendered/prometheus.yml"
grep -Fq "labels: {route: 'B', host: 'gdc-node0'}" "$tmp/rendered/prometheus.yml"

"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$inventory" --node-name gdc-node4 --output "$tmp/a.env" >/dev/null
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$inventory" --node-name gdc-node0 --output "$tmp/b.env" >/dev/null
grep -Fxq 'GDC_GATEWAY_METRICS_UPSTREAM=http://127.0.0.1:18087' "$tmp/a.env"
grep -Fxq 'GDC_GATEWAY_METRICS_UPSTREAM=http://127.0.0.1:18088' "$tmp/b.env"
grep -Fxq 'GDC_GATEWAY_B_UPSTREAM=http://127.0.0.1:9' "$tmp/a.env"
grep -Fxq 'GDC_GATEWAY_B_UPSTREAM=http://127.0.0.1:18088' "$tmp/b.env"
grep -Fxq 'GDC_GATEWAY_ROUTE_ID=A' "$tmp/a.env"
grep -Fxq 'GDC_GATEWAY_ROUTE_ID=B' "$tmp/b.env"
grep -Fxq 'GDC_GATEWAY_ROUTE_UPSTREAM=http://127.0.0.1:18087' "$tmp/a.env"
grep -Fxq 'GDC_GATEWAY_ROUTE_UPSTREAM=http://127.0.0.1:18088' "$tmp/b.env"
grep -Fq 'reverse_proxy 127.0.0.1:18100 {' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:18083' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq '@gateway_b_from_public_edge {' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'path /gateway-b/*' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'remote_ip {$PUBLIC_EDGE_CIDR} 127.0.0.0/8 ::1' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'uri strip_prefix /gateway-b' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:18100' "$ROOT/04-ops/edge-node/Caddyfile"

dashboard="$ROOT/04-ops/grafana/dashboards/gdc-inference.json"
jq -e '
  ([.panels[] | select(.id == 51) | .targets[0].expr] == ["min(up{job=\"gateway\"})"])
  and ([.panels[] | select(.id == 52) | .targets[0].expr] == ["sum by (gateway) (rate(devshard_gateway_requests_total[15m])) * 60"])
  and ([.panels[] | select(.id == 55) | .targets[0].expr] == ["max by (gateway) (devshard_gateway_capacity_scale) * 100 and on (gateway) (max by (gateway) (gdc_chain_gateway_working) == 1)"])
  and ([.panels[] | select(.id == 57) | .targets[0].expr] == ["sum by (reason) (increase(devshard_gateway_requests_total{outcome!=\"success\"}[15m]))"])
  and ([.panels[] | select(.id == 61) | .targets[0].expr] == ["sum by (gateway,outcome) (rate(devshard_gateway_requests_total[15m]))"])
  and ([.panels[] | select(.id == 91) | .targets[0].expr] == ["(time() - min(timestamp(up{job=\"gateway\"}) and up{job=\"gateway\"} == 1)) and on() (min(up{job=\"gateway\"}) == 1)"])
' "$dashboard" >/dev/null

sed 's/GDC_GATEWAY_METRICS_TARGETS=.*/GDC_GATEWAY_METRICS_TARGETS='\''[{"id":"A","node":"gdc-node4","port":18087},{"id":"A","node":"gdc-node0","port":18088}]'\''/' "$inventory" >"$tmp/duplicate.env"
if "$ROOT/04-ops/render-ops.sh" --inventory "$tmp/duplicate.env" --output-dir "$tmp/duplicate" >"$tmp/duplicate.out" 2>&1; then
  echo 'duplicate gateway identities unexpectedly rendered' >&2
  exit 1
fi
grep -Fq 'GDC_GATEWAY_METRICS_TARGETS must be a non-empty unique id/node/port JSON array' "$tmp/duplicate.out"

# A public edge can retain host monitoring without a gateway or validator.
cat >>"$inventory" <<'EOF'
GDC_GATEWAY_METRICS_TARGETS='[{"id":"B","node":"gdc-node0","port":18146}]'
GDC_MONITORING_ONLY_NODES=gdc-node4
GDC_GATEWAY_OBSERVATION_TARGETS='[{"id":"B_V41","node":"gdc-node0","port":18141},{"id":"B_V6","node":"gdc-node0","port":18146}]'
EOF
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$inventory" --node-name gdc-node4 --output "$tmp/no-gateway.env" >/dev/null
grep -Fxq 'GDC_GATEWAY_METRICS_UPSTREAM=http://127.0.0.1:9' "$tmp/no-gateway.env"
"$ROOT/04-ops/render-ops.sh" --inventory "$inventory" --output-dir "$tmp/observed" >/dev/null
[[ -f "$tmp/observed/prometheus/targets/static/host/gdc-node4.json" ]]
[[ ! -e "$tmp/observed/prometheus/targets/static/gonka-node/gdc-node4.json" ]]
[[ ! -e "$tmp/observed/prometheus/targets/static/devshard-host/gdc-node4.json" ]]
jq -e '.[0].targets == ["gdc-node0.example.test:443"] and .[0].labels.host == "gdc-node0"' "$tmp/observed/prometheus/targets/static/devshard-host/gdc-node0.json" >/dev/null
grep -Fq 'metrics_path: /devshard/metrics' "$tmp/observed/prometheus.yml"
grep -Fq "__metrics_path__: '/ops-gateways/B_V6/metrics'" "$tmp/observed/prometheus.yml"
grep -Fq 'B_V41: https://gdc-node0.example.test/ops-gateways/B_V41/status' "$tmp/observed/chain-poller/config.yml"
grep -Fq 'chain_sources: [gdc-node0]' "$tmp/observed/chain-poller/config.yml"
grep -Fq 'reverse_proxy 127.0.0.1:18146' "$tmp/observed/gateway-observation/gdc-node0.caddy"
printf 'PASS legacy and multi-version gateway monitoring renders\n'
