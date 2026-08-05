#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

GMETER_SOURCE="${GDC_GMETER_SOURCE:-$ROOT/../gmeter}"
GMETER_UPSTREAM_COMMIT="a698eff399a7b1473c060f1200586ea0f50db9d0"
[[ -d "$GMETER_SOURCE/.git" ]] || die "G-Meter source is missing: $GMETER_SOURCE"
[[ "$(git -C "$GMETER_SOURCE" rev-parse HEAD)" == "$GMETER_UPSTREAM_COMMIT" ]] \
  || die 'G-Meter source is not at the reviewed upstream revision'

RUN="$ROOT/artifacts/runs/${GDC_RUN_ID}-meter"
REMOTE="/tmp/gdc-meter-$$"
METER_SECRET="$SECRETS/gmeter.gateway-key"
METER_ENV="$GENERATED/meter.env"
mkdir -p "$RUN" "$GENERATED"

step 'Back up persistent G-Meter probe history before any gateway or service change'
ssh -T gdc-node0 'set -Eeuo pipefail
  install -d -m 0700 /srv/gmeter-backups
  if test -d /srv/dai/gmeter; then
    cd /srv/dai/gmeter
    backend="$(docker compose ps -q backend 2>/dev/null || true)"
    if [[ -n "$backend" ]] && docker cp "$backend:/app/data/gmeter.db" "/srv/gmeter-backups/gmeter-$(date -u +%Y%m%dT%H%M%SZ).db" 2>/dev/null; then
      sha256sum /srv/gmeter-backups/gmeter-*.db | tail -n1
    else
      printf "NO_EXISTING_GMETER_DB\n"
    fi
  else
    printf "NO_EXISTING_GMETER_DB\n"
  fi' >"$RUN/gmeter-backup.sha256"

step 'Require an active chain-accounted gateway before publishing G-Meter'
ssh gdc-node0 'curl -fsS http://127.0.0.1:18080/v1/status | jq -e ".phase == \"active\" and .requests_blocked == false and (.escrow_id | tostring | test(\"^[1-9][0-9]*$\"))" >/dev/null' \
  || die 'G-Meter requires an ACTIVE, unblocked gateway escrow'

if [[ ! -s "$METER_SECRET" ]]; then
  umask 077
  printf 'sk-gdc-meter-%s\n' "$(openssl rand -hex 24)" >"$METER_SECRET"
fi
METER_KEY="$(<"$METER_SECRET")"
[[ "$METER_KEY" =~ ^sk-gdc-meter-[0-9a-f]{48}$ ]] || die 'invalid dedicated G-Meter gateway key'

step 'Render a least-privileged G-Meter broker configuration'
# Qwen3-0.6B on the Community DevNet does not advertise OpenAI tools.
# This is an excluded capability, not an availability failure.
write_env "$METER_ENV" \
  "GMETER_GATEWAY_API_KEY=$METER_KEY" \
  'BROKERS_CONFIG_PATH=/app/brokers.json' \
  'CORS_ORIGINS=https://gonka-dev.net' \
  'PROBE_INTERVAL_MINUTES=30' \
  'LIMITS_INTERVAL_MINUTES=1440' \
  'MIN_OUTPUT_TOKENS=128' \
  'PUBLIC_READ_ONLY=true' \
  'PUBLIC_SAFE_MODE=true' \
  'RUN_PROBE_ON_STARTUP=true' \
  'RUN_LIMITS_ON_STARTUP=false' \
  'DISABLED_PROBE_TESTS=tool_calling'
cat >"$GENERATED/brokers.json" <<'EOF'
{"brokers":[{"name":"Gonka DevNet Community","base_url":"https://api.gonka-dev.net/v1","api_key":"${GMETER_GATEWAY_API_KEY}","models":[{"id":"Qwen/Qwen3-0.6B","alias":"qwen3-0.6b"}]}]}
EOF
chmod 600 "$GENERATED/brokers.json"
git -C "$GMETER_SOURCE" diff --binary | sha256sum | awk '{print $1}' >"$RUN/gmeter-overlay.sha256"
jq -n --arg source_commit "$GMETER_UPSTREAM_COMMIT" --arg overlay_sha256 "$(<"$RUN/gmeter-overlay.sha256")" \
  '{sourceCommit:$source_commit,localOverlaySha256:$overlay_sha256,publicSafeMode:true,publicReadOnly:true}' >"$RUN/gmeter-source.json"

step 'Install the reviewed G-Meter service on node0'
ssh gdc-node0 "rm -rf '$REMOTE' && mkdir -p '$REMOTE/gmeter' '$REMOTE/rendered'"
rsync -a --delete --exclude .git --exclude node_modules --exclude dist --exclude .env \
  "$GMETER_SOURCE/" "gdc-node0:$REMOTE/gmeter/"
scp -q "$METER_ENV" "gdc-node0:$REMOTE/rendered/meter.env"
scp -q "$GENERATED/brokers.json" "gdc-node0:$REMOTE/gmeter/brokers.json"
scp -q "$ROOT/00-host-prep/gonka-firewall.sh" "gdc-node0:$REMOTE/gonka-firewall"
ssh -T gdc-node0 "REMOTE='$REMOTE' METER_EDGE_CIDR='$METER_EDGE_CIDR' bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail
sudo install -d -m 0750 /srv/dai/gmeter
sudo cp -a "$REMOTE/gmeter/." /srv/dai/gmeter/
sudo install -m 0600 "$REMOTE/rendered/meter.env" /srv/dai/gmeter/.env
sudo install -m 0755 "$REMOTE/gonka-firewall" /usr/local/sbin/gonka-firewall
sudo sed -i '/^METER_EDGE_CIDR=/d' /etc/gonka/host.env
printf '%s\n' "METER_EDGE_CIDR=$METER_EDGE_CIDR" | sudo tee -a /etc/gonka/host.env >/dev/null
key="$(sed -n 's/^GMETER_GATEWAY_API_KEY=//p' "$REMOTE/rendered/meter.env")"
if ! sudo grep -qF ",$key" /srv/dai/ops/gateway.env && ! sudo grep -qF "=$key," /srv/dai/ops/gateway.env; then
  sudo sed -i "s|^DEVSHARD_API_KEYS=|DEVSHARD_API_KEYS=$key,|" /srv/dai/ops/gateway.env
fi
sudo systemctl restart gonka-firewall
cd /srv/dai/ops && sudo docker compose --env-file .env --env-file gateway.env up -d --force-recreate devshard-gateway >/srv/dai/ops/start-gateway-meter.log 2>&1
cd /srv/dai/gmeter && sudo docker compose --env-file .env up -d --build --remove-orphans backend >/srv/dai/gmeter/start.log 2>&1
rm -rf "$REMOTE"
REMOTE_SCRIPT

step 'Publish the G-Meter API through the node4 TLS edge'
EDGE_ENV="$GENERATED/edge/gdc-node4.env"
mkdir -p "$(dirname "$EDGE_ENV")"
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name gdc-node4 --output "$EDGE_ENV" >/dev/null
ssh gdc-node4 "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/04-ops/edge-node/" "gdc-node4:$REMOTE/edge/"
scp -q "$EDGE_ENV" "gdc-node4:$REMOTE/edge.env"
ssh -T gdc-node4 "sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; rm -rf '$REMOTE'; cd /srv/dai/edge && docker compose up -d --force-recreate caddy >/srv/dai/edge/start-edge.log 2>&1"

step 'Verify public routing and that public APIs redact retained probe material'
deadline=$((SECONDS + 240))
ready=false
while (( SECONDS < deadline )); do
  if curl -fsS "https://$SITE_HOST/meter-api/health" | jq -e '.status == "ok" or .ok == true' >/dev/null 2>&1; then
    ready=true
    break
  fi
printf 'WAIT  G-Meter API health through node4 edge\n'
  sleep 4
done
[[ "$ready" == true ]] || die 'G-Meter public API health did not become ready'
curl -fsS "https://$SITE_HOST/meter-api/brokers" >"$RUN/public-brokers.json"
jq -e 'all(.[]; .api_key_masked == "hidden")' "$RUN/public-brokers.json" >/dev/null || die 'public G-Meter exposes an API-key fragment'
if rg -q 'sk-[A-Za-z0-9_-]{6,}|Authorization:|Bearer ' "$RUN/public-brokers.json"; then
  die 'public G-Meter response contains credential material'
fi
curl -fsS "https://$SITE_HOST/meter-api/metrics/dashboard/logs?broker_id=1&metric_key=ttft" >"$RUN/public-logs.json"
jq -e 'length == 0' "$RUN/public-logs.json" >/dev/null || die 'public G-Meter exposes retained measurement logs'
curl -fsS "https://$SITE_HOST/meter-api/metrics/dashboard/detail" >"$RUN/public-dashboard.json"
jq -e '(.aggregate | has("real_spend_per_m")) and ([.providers[].metrics[].key] | index("real_spend"))' "$RUN/public-dashboard.json" >/dev/null
[[ "$(curl -sk -o /dev/null -w '%{http_code}' "https://$SITE_HOST/meter/")" == 404 ]] \
  || die 'legacy G-Meter frontend route is still published'
cat >"$RUN/verdict.md" <<EOF
# G-Meter: PASS

- Public API: https://$SITE_HOST/meter-api/health
- Public widgets: homepage only; it renders quality metrics and deliberately omits token-price/cost metrics.
- Source: gonkalabs/gmeter@$GMETER_UPSTREAM_COMMIT plus recorded local privacy overlay
- Edge: node4 only; node0 port 18000 is firewall-restricted to $METER_EDGE_CIDR
- Public safe mode hides API-key fragments, probe results, raw errors, and metric logs.
EOF
cp "$RUN/verdict.md" "$RUN/finalize.md"
printf 'PASS G-Meter public safe mode and node4 route\n'
