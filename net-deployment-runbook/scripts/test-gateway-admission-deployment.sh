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
grep -Fxq 'GDC_GATEWAY_ADMISSION_STATUS_URL=https://validator-a.example.net/ops-gateway-admission-state' "$tmp/stable.env"
! grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=' "$tmp/stable.env"

GDC_COMPOSITION=core-v2026.08.06+devshard-v2026.08.27-rc.0 \
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$tmp/inventory.env" --node-name validator-e --output "$tmp/candidate.env"
candidate_contract="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$tmp/candidate.env")"
jq -e 'keys == ["v3", "v5"] and (has("v4") | not)' <<<"$candidate_contract" >/dev/null
grep -Fxq 'GDC_GATEWAY_ADMISSION_STATUS_URL=https://validator-a.example.net/ops-gateway-admission-state' "$tmp/candidate.env"

grep -Fq 'env_file: [./gateway-admission.env]' "$ROOT/04-ops/edge-node/compose.yaml"
grep -Fq 'install-gateway-admission.sh' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'deploy_gateway_admission' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway admission environment differs after deployment' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway admission environment has an invalid protocol contract' "$ROOT/04-ops/edge-node/install-gateway-admission.sh"
grep -Fq 'gateway admission environment has an invalid status credential' "$ROOT/04-ops/edge-node/install-gateway-admission.sh"
grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=%s' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway.admission-observer-key' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway-admission-observer.env' "$ROOT/04-ops/install-ops.sh"
grep -Fq 'gateway-admission-observer.py' "$ROOT/04-ops/install-ops.sh"
grep -Fq 'handle /ops-gateway-admission-state' "$ROOT/04-ops/Caddyfile"
grep -Fq 'rewrite * /v1/status' "$ROOT/04-ops/Caddyfile"
grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN' "$ROOT/scripts/phase-ops.sh"
grep -Fq '.capacity.models | type ==' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'suspend-gateway-admission.sh' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'trap cleanup_failed_admission EXIT' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'docker compose stop gateway-admission' "$ROOT/scripts/phase-ops.sh"

deploy_block="$(awk '
  /^deploy_gateway_admission\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/scripts/phase-ops.sh")"
digest_line="$(grep -nF '[[ "$remote_sha" == "$expected_sha" ]]' <<<"$deploy_block" | cut -d: -f1)"
start_line="$(grep -nF 'docker compose up -d --force-recreate gateway-admission' <<<"$deploy_block" | cut -d: -f1)"
(( digest_line < start_line ))

observer_line="$(grep -nF "step 'Verify the sanitized read-only admission observer'" "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
deploy_line="$(grep -nF "step 'Deploy the matching public admission contract'" "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
suspend_line="$(grep -nF "step 'Suspend public admission before replacing the gateway runtime'" "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
install_line="$(grep -nF 'WAIT  start %s operations component' "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
(( suspend_line < install_line && observer_line < deploy_line ))
[[ "$(grep -Fc "step 'Deploy the matching public admission contract'" "$ROOT/scripts/phase-ops.sh")" == 1 ]]
! awk '/deploy_gateway_admission\(\)/,/^}/' "$ROOT/scripts/phase-ops.sh" | grep -Fq 'gateway.admin-key'

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
