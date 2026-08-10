#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a
. ./.env
set +a

base=http://127.0.0.1:3000
dashboard="$GRAFANA_PUBLIC_DASHBOARD_UID"
share="$GRAFANA_PUBLIC_DASHBOARD_SHARE_UID"
payload="$(jq -cn --arg uid "$share" --arg token "$GRAFANA_PUBLIC_DASHBOARD_TOKEN" '{uid:$uid,accessToken:$token,timeSelectionEnabled:true,isEnabled:true,annotationsEnabled:false,share:"public"}')"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

ready=false
for _ in $(seq 1 30); do
  if curl -fsS "$base/api/health" | jq -e '.database == "ok"' >/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'Grafana did not become ready' >&2; exit 1; }

publish() {
  curl -sS -o "$tmp" -w '%{http_code}' -u "admin:$GRAFANA_ADMIN_PASSWORD" \
    -H 'Content-Type: application/json' -X POST "$base/api/dashboards/uid/$dashboard/public-dashboards/" --data "$payload"
}

status="$(publish)"
# GF_SECURITY_ADMIN_PASSWORD only seeds a new Grafana database. The durable
# operator volume survives monitoring redeployments, so reconcile an older
# password through the local container CLI before treating a 401 as a failed
# public-dashboard deployment. The secret never leaves the configured public edge or stdout.
if [[ "$status" == 401 ]]; then
  docker compose exec -T grafana grafana cli admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null
  status="$(publish)"
fi
if [[ "$status" == 400 ]] && jq -e '.messageId == "publicdashboards.dashboardIsPublic"' "$tmp" >/dev/null; then
  curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$base/api/dashboards/uid/$dashboard/public-dashboards/" >"$tmp"
  existing="$(jq -er '.uid' "$tmp")"
  curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' -X PATCH "$base/api/dashboards/uid/$dashboard/public-dashboards/$existing" --data '{"timeSelectionEnabled":true,"isEnabled":true,"annotationsEnabled":false,"share":"public"}' >"$tmp"
elif [[ "$status" != 200 ]]; then
  jq -c '{message,messageId,statusCode}' "$tmp" >&2 || true
  exit 1
fi
jq -e --arg dashboard "$dashboard" '.dashboardUid == $dashboard and .isEnabled == true and .share == "public"' "$tmp" >/dev/null
printf 'READY public dashboard enabled for %s\n' "$dashboard"
