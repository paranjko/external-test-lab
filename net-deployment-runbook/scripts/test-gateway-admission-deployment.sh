#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$ROOT/.env.example" "$tmp/inventory.env"
{
  printf '%s\n' \
    'SITE_HOST=gonka-dev.net' \
    'API_HOST=api.gonka-dev.net' \
    'GRAFANA_HOST=grafana.gonka-dev.net' \
    'MONITORING_CIDR=192.0.2.10/32' \
    'PUBLIC_EDGE_CIDR=192.0.2.20/32'
} >>"$tmp/inventory.env"

GDC_RELEASE_PROFILE=v2026.08.06 \
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$tmp/inventory.env" --node-name validator-e --output "$tmp/stable.env"
stable_contract="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$tmp/stable.env")"
jq -e 'keys == ["v3"]' <<<"$stable_contract" >/dev/null
grep -Fxq 'GDC_GATEWAY_ADMISSION_SINGLE_RUNTIME_PROTOCOL=v3' "$tmp/stable.env"

GDC_COMPOSITION=core-v2026.08.06+devshard-v2026.08.27-rc.0 \
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$tmp/inventory.env" --node-name validator-e --output "$tmp/candidate.env"
candidate_contract="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$tmp/candidate.env")"
jq -e 'keys == ["v3", "v5"] and (has("v4") | not)' <<<"$candidate_contract" >/dev/null
grep -Fxq 'GDC_GATEWAY_ADMISSION_SINGLE_RUNTIME_PROTOCOL=v5' "$tmp/candidate.env"

grep -Fq 'env_file: [./gateway-admission.env]' "$ROOT/04-ops/edge-node/compose.yaml"
grep -Fq 'install-gateway-admission.sh' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'deploy_gateway_admission' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway admission environment differs after deployment' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway admission environment has an invalid protocol contract' "$ROOT/04-ops/edge-node/install-gateway-admission.sh"
grep -Fq 'gateway admission environment has an invalid single-runtime protocol' "$ROOT/04-ops/edge-node/install-gateway-admission.sh"

grafana_reconcile="$(awk '
  /^reconcile_public_grafana\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/scripts/phase-ops.sh")"
if grep -Fq 'gateway-admission' <<<"$grafana_reconcile"; then
  echo 'public Grafana reconciliation must not replace gateway admission' >&2
  exit 1
fi
grep -Fq 'if [[ ! -e "$DEST/gateway-admission.env" ]]; then' "$ROOT/04-ops/edge-node/install-edge.sh"
[[ "$(grep -Fc 'install -m 0600 /dev/null "$DEST/gateway-admission.env"' "$ROOT/04-ops/edge-node/install-edge.sh")" == 1 ]]
! grep -Fq 'gateway-admission-proxy.py' "$ROOT/04-ops/edge-node/install-edge.sh"

printf 'PASS gateway admission follows only the selected gateway profile\n'
