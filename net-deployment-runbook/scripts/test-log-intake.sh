#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp_root="${TMPDIR:-$ROOT/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/log-intake.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

render="$ROOT/04-ops/render-log-intake.sh"
token_file="$tmp/token"
printf 'FixtureToken0123456789abcdefABCDEF\n' >"$token_file"
refused() { if "$@" >/dev/null 2>&1; then return 1; fi; }
refused bash "$render" "$token_file"
refused bash "$render" "$token_file" 192.0.2.300/32
refused bash "$render" "$token_file" 192.0.2.4
printf 'short\n' >"$tmp/short"
refused bash "$render" "$tmp/short" 192.0.2.4/32
refused bash "$render" "$tmp/missing" 192.0.2.4/32
fragment="$(bash "$render" "$token_file" 192.0.2.4/32 198.51.100.7/32)"
grep -Fq 'path /ops-logs/push' <<<"$fragment"
grep -Fq 'remote_ip 192.0.2.4/32 198.51.100.7/32' <<<"$fragment"
grep -Fq 'header Authorization "Bearer FixtureToken0123456789abcdefABCDEF"' <<<"$fragment"
grep -Fq 'rewrite * /loki/api/v1/push' <<<"$fragment"
grep -Fq 'reverse_proxy 127.0.0.1:3100' <<<"$fragment"
printf 'PASS log intake renderer accepts only a token file and IPv4 CIDRs\n'

# Inventory addresses come from DNS; a stub answers for the fixture names.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/getent" <<'STUB'
#!/bin/sh
case "$2" in
  gdc-node4.example.test) echo "192.0.2.4       STREAM $2" ;;
  gdc-node0.example.test) echo "198.51.100.7    STREAM $2" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/getent"
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
PATH="$tmp/bin:$PATH" "$ROOT/04-ops/render-ops.sh" --inventory "$inventory" --output-dir "$tmp/without" >/dev/null
[[ ! -e "$tmp/without/log-intake.caddy" ]]
PATH="$tmp/bin:$PATH" GDC_LOG_PUSH_TOKEN_FILE="$token_file" \
  "$ROOT/04-ops/render-ops.sh" --inventory "$inventory" --output-dir "$tmp/with" >/dev/null
grep -Fq 'remote_ip 192.0.2.4/32 198.51.100.7/32' "$tmp/with/log-intake.caddy"
[[ "$(stat -c '%a' "$tmp/with/log-intake.caddy" 2>/dev/null || stat -f '%Lp' "$tmp/with/log-intake.caddy")" == 600 ]]
printf 'PASS OPS render writes the intake route for every inventory Host only when a push token is given\n'

secrets="$tmp/secrets"
bash "$ROOT/scripts/make-secrets.sh" "$secrets" gdc-node4 >/dev/null
first="$(<"$secrets/loki.push-token")"
[[ "$first" =~ ^[A-Za-z0-9]{32,}$ ]]
bash "$ROOT/scripts/make-secrets.sh" "$secrets" gdc-node4 >/dev/null
[[ "$(<"$secrets/loki.push-token")" == "$first" ]]
printf 'PASS the push token is created once with the OPS secrets and kept afterwards\n'

grep -Fq -- '-f compose.loki.yaml up -d' "$ROOT/scripts/phase-ops.sh"
grep -Eq "force-recreate .*\\bloki\\b" "$ROOT/scripts/phase-ops.sh"
grep -Fq "'log intake'" "$ROOT/scripts/phase-ops.sh"
grep -Fq '127.0.0.1:3100:3100' "$ROOT/04-ops/compose.loki.yaml"
grep -Eq 'image: \$\{LOKI_IMAGE:-grafana/loki:[0-9.]+@sha256:[0-9a-f]{64}\}' "$ROOT/04-ops/compose.loki.yaml"
printf 'PASS monitoring starts the loopback-only log store and installs the intake route\n'
