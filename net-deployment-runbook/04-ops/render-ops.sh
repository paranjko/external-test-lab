#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --inventory FILE --output-dir DIR" >&2; }
INVENTORY=''; OUTPUT=''
while (($#)); do case "$1" in
  --inventory) INVENTORY="$2"; shift 2 ;;
  --output-dir) OUTPUT="$2"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ -n "$INVENTORY" && -n "$OUTPUT" ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
SECRETS="$STATE/secrets"
source "$ROOT/scripts/profile.sh"
load_profiles
GATEWAY_VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
[[ "$GATEWAY_VERSION" =~ ^v[34]$ ]] || { echo 'GDC_GATEWAY_VERSION must be v3 or v4' >&2; exit 2; }
# Deployment profiles name gateway artifacts with their protocol suffix.  Strip
# either supported suffix before selecting the requested protocol, otherwise a
# v3 profile such as `...:0.2.15-v3` becomes the distinct, unintended
# `...:0.2.15-v3-v3` tag.
LOCAL_GATEWAY_IMAGE="${LOCAL_GATEWAY_IMAGE%-v[34]}-$GATEWAY_VERSION"
telegram_bot_url="${GDC_TELEGRAM_BOT_URL:-}"
if [[ -n "$telegram_bot_url" && ! "$telegram_bot_url" =~ ^https://t\.me/[A-Za-z0-9_]{5,32}$ ]]; then
  echo 'GDC_TELEGRAM_BOT_URL must be https://t.me/<bot_username>; never put a BotFather token here' >&2
  exit 2
fi
# These values belong to the OPS publication lifecycle. They are deliberately
# absent from Genesis and JOIN inventories. Stable defaults let OPS repair the
# same public share after a monitoring redeployment.
grafana_public_dashboard_uid="${GDC_GRAFANA_PUBLIC_DASHBOARD_UID:-gdc-overview}"
grafana_public_dashboard_share_uid="${GDC_GRAFANA_PUBLIC_DASHBOARD_SHARE_UID:-5fd40e12-5334-4d32-aea2-dcfe85afb3f2}"
grafana_public_dashboard_token="${GDC_GRAFANA_PUBLIC_DASHBOARD_TOKEN:-321a0d961e7f4b4ea6da843777c032eb}"
mkdir -p "$OUTPUT"

gateway_public_host="$(node_public_host "$GATEWAY_NODE")"
write_env "$OUTPUT/.env" \
  "SITE_HOST=$SITE_HOST" "API_HOST=$API_HOST" "GRAFANA_HOST=$GRAFANA_HOST" "ACME_EMAIL=${ACME_EMAIL:-}" \
  "TELEGRAM_BOT_URL=$telegram_bot_url" "GATEWAY_PUBLIC_HOST=$gateway_public_host" "PUBLIC_EDGE_CIDR=$PUBLIC_EDGE_CIDR" \
  "GRAFANA_ADMIN_PASSWORD=${GDC_GRAFANA_ADMIN_PASSWORD:-}" \
  "GRAFANA_PUBLIC_DASHBOARD_UID=$grafana_public_dashboard_uid" "GRAFANA_PUBLIC_DASHBOARD_SHARE_UID=$grafana_public_dashboard_share_uid" "GRAFANA_PUBLIC_DASHBOARD_TOKEN=$grafana_public_dashboard_token" \
  "PROMETHEUS_IMAGE=$PROMETHEUS_IMAGE" "ALERTMANAGER_IMAGE=$ALERTMANAGER_IMAGE" "BLACKBOX_IMAGE=$BLACKBOX_IMAGE" \
  "GRAFANA_IMAGE=$GRAFANA_IMAGE" "LOCAL_GATEWAY_IMAGE=$LOCAL_GATEWAY_IMAGE" "CADDY_IMAGE=$CADDY_IMAGE" "INFERENCED_IMAGE=$INFERENCED_IMAGE"

nodes='[]'; validators='[]'; node_catalog='[]'
# The public map is a topology observation, not an operator assertion.  Resolve
# each currently advertised IPv4 address while rendering the static site
# contract so a freshly joined alias has coordinates without any dependency on
# a lab-specific hostname.  Failure remains representable as null: a temporary
# GeoIP outage must not prevent monitoring/site deployment, but the public
# homepage verifier will reject a deployment that claims a map while active
# nodes have no resolved positions.
declare -A geo_by_ip=() geo_by_node=()
resolve_geo() {
  local ip="$1" response geo
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { printf 'null\n'; return 0; }
  if [[ -v "geo_by_ip[$ip]" ]]; then
    printf '%s\n' "${geo_by_ip[$ip]}"
    return 0
  fi
  response="$(curl -fsS --connect-timeout 3 --max-time 10 "https://ipwho.is/$ip" 2>/dev/null || true)"
  geo="$(jq -cer '
    select(.success == true)
    | {
        latitude: (.latitude | tonumber),
        longitude: (.longitude | tonumber),
        city: (.city | strings),
        country: (.country | strings),
        isp: (.connection.isp // "unknown" | strings)
      }
  ' <<<"$response" 2>/dev/null || printf 'null')"
  geo_by_ip[$ip]="$geo"
  printf '%s\n' "$geo"
}
for node in "${GDC_NODES[@]}"; do
  host="$(node_public_host "$node")"
  gpu_profile="$(node_gpu_profile "$node")"
  gpu_host="$(node_ml_host "$node" || printf '%s' "$node")"
  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  geo="$(resolve_geo "$ip")"
  geo_by_node[$node]="$geo"
  node_catalog="$(jq --arg name "$node" --arg host "$host" --arg status "/status/$node" --arg ip "$ip" --arg gpuProfile "$gpu_profile" --arg gpuHost "$gpu_host" --argjson geo "$geo" \
    '. + [{name:$name,publicHost:$host,statusBase:$status,ip:$ip,geo:$geo,gpuProfile:(if $gpuProfile == "auto" then null else $gpuProfile end),gpuHost:$gpuHost}]' <<<"$node_catalog")"
done

jq -n --arg chain "$CHAIN_ID" --arg model "$MODEL_ID" --arg gateway "https://$API_HOST/v1" \
  --arg direct "http://$gateway_public_host:8082/v1" --arg telegram "$telegram_bot_url" \
  --arg grafanaNetwork "https://$GRAFANA_HOST/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc&kiosk" \
  --arg grafanaInference "https://$GRAFANA_HOST/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-7d&to=now&timezone=utc&kiosk" \
  --arg gatewayNode "$GATEWAY_NODE" --arg chainRpcHost "$(node_public_host "$GENESIS_NODE")" --argjson nodes "$nodes" --argjson validators "$validators" --argjson nodeCatalog "$node_catalog" \
  '{chainId:$chain,model:$model,apiBase:$gateway,gatewayApiBase:$gateway,directMlApiBase:$direct,telegramBot:$telegram,grafanaNetwork:$grafanaNetwork,grafanaInference:$grafanaInference,gatewayNode:$gatewayNode,chainRpcHost:$chainRpcHost,nodes:$nodes,nodeCatalog:$nodeCatalog,validators:$validators}' \
  | sed '1s/^/window.GDC_CONFIG = /;$s/$/;/' >"$OUTPUT/config.js"

{
  printf '{\n'
  [[ -z "${ACME_EMAIL:-}" ]] || printf '  email {$ACME_EMAIL}\n'
  printf '  admin 127.0.0.1:2019\n}\n'
  cat <<'CADDY'
# Public TLS belongs exclusively to the configured participant edge. This
# internal status service intentionally exposes only its explicit HTTP ports.
http://:8082 {
  encode zstd gzip
  reverse_proxy 127.0.0.1:8080
}
http://:8081 {
  encode zstd gzip
  handle /status/participants {
    rewrite * /productscience/inference/inference/participant
    reverse_proxy 127.0.0.1:1317
  }
CADDY
  for node in "${GDC_NODES[@]}"; do
    host="$(node_public_host "$node")"
    if [[ "$node" == "$GATEWAY_NODE" ]]; then
      # The local node proxy dispatches by its public Host header too.  Keep
      # this identical to remote participant routing; otherwise the status
      # site receives a 404 and misclassifies the whole network as OFFLINE.
      printf '  handle_path /status/%s/* {\n    reverse_proxy 127.0.0.1:8000 {\n      header_up Host %s\n    }\n  }\n' "$node" "$host"
    elif [[ "$node" == "$PUBLIC_EDGE_NODE" ]]; then
      # A public-edge Host normally proxies arbitrary user traffic to the
      # gateway. Prefix the monitoring-only route so the check reaches its
      # own loopback participant proxy rather than that gateway fallback.
      printf '  handle_path /status/%s/* {\n    rewrite * /ops-participant-status{uri}\n    reverse_proxy https://%s {\n      header_up Host %s\n    }\n  }\n' "$node" "$host" "$host"
    else
      printf '  handle_path /status/%s/* {\n    reverse_proxy https://%s {\n      header_up Host %s\n    }\n  }\n' "$node" "$host" "$host"
    fi
  done
  cat <<'CADDY'
  handle_path /status/gateway/* {
    reverse_proxy 127.0.0.1:18080
  }
  handle /status/gateway-health {
    root * /status
    rewrite * /gateway-health.json
    header Cache-Control "no-store"
    file_server
  }
  # Publish only the fixed GPU inventory query. Do not expose the general
  # Prometheus query API through the public status origin.
  handle /status/gpus {
    rewrite * /api/v1/query?query=gdc_nvidia_memory_total_bytes
    reverse_proxy 127.0.0.1:9099
  }
  # The site consumes software information only from the monitoring inventory,
  # never from a participant's public inference endpoint.
  handle /status/software {
    rewrite * /api/v1/query?query=gdc_component_info
    reverse_proxy 127.0.0.1:9099
  }
  root * /srv
  file_server
  header {
    Cache-Control "no-store"
    X-Content-Type-Options nosniff
    Referrer-Policy no-referrer
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
  }
}
CADDY
} >"$OUTPUT/Caddyfile"

bootstrap_dir="$OUTPUT/join-bootstrap"
rm -rf "$bootstrap_dir"
mkdir -p "$bootstrap_dir/genesis" "$bootstrap_dir/profile" "$bootstrap_dir/gateway"
if [[ -s "$GDC_HOME/genesis/genesis.json" && -s "$GDC_HOME/genesis/genesis.sha256" && -s "$GDC_HOME/genesis/genesis-seeds.txt" && -s "$STATE/phase-profiles/genesis.env" && -s "$SECRETS/gateway.join-client-key" ]]; then
  install -m 0644 "$GDC_HOME/genesis/genesis.json" "$bootstrap_dir/genesis/genesis.json"
  install -m 0644 "$GDC_HOME/genesis/genesis.sha256" "$bootstrap_dir/genesis/genesis.sha256"
  install -m 0644 "$GDC_HOME/genesis/genesis-seeds.txt" "$bootstrap_dir/genesis/genesis-seeds.txt"
  install -m 0644 "$STATE/phase-profiles/genesis.env" "$bootstrap_dir/profile/genesis.env"
  if ! grep -qx "join_bootstrap_format=$JOIN_BOOTSTRAP_FORMAT" "$bootstrap_dir/profile/genesis.env"; then
    grep -qx "release_profile=$GDC_RELEASE_PROFILE" "$bootstrap_dir/profile/genesis.env" \
      || { echo 'Genesis profile does not match the selected release' >&2; exit 1; }
    printf 'join_bootstrap_format=%s\n' "$JOIN_BOOTSTRAP_FORMAT" >>"$bootstrap_dir/profile/genesis.env"
  fi
  # This is the deliberately narrow, DevShard client credential used only by
  # the JOIN_PASS completion regression. It is neither an operator key nor a
  # gateway administration credential, and the operator stores it locally at
  # mode 0600 after verifying the public-bootstrap manifest.
  install -m 0644 "$SECRETS/gateway.join-client-key" "$bootstrap_dir/gateway/join-client-key"
  {
    printf 'GDC_NODE_ALIASES=%q\n' "$GDC_NODE_ALIASES"
    printf 'GDC_NODE_PUBLIC_HOSTS=%q\n' "$GDC_NODE_PUBLIC_HOSTS"
    printf 'GDC_NODE_GPU_PROFILES=%q\n' "$GDC_NODE_GPU_PROFILES"
    printf 'GDC_NODE_P2P_PORTS=%q\n' "$GDC_NODE_P2P_PORTS"
    printf 'GDC_NODE_ML_HOSTS=%q\n' "${GDC_NODE_ML_HOSTS:-}"
    printf 'GDC_GENESIS_NODE=%q\n' "$GENESIS_NODE"
    printf 'GDC_PUBLIC_EDGE_NODE=%q\n' "$PUBLIC_EDGE_NODE"
    printf 'GDC_GATEWAY_NODE=%q\n' "$GATEWAY_NODE"
  } >"$bootstrap_dir/topology.env"
  (
    cd "$bootstrap_dir"
    find . -type f ! -name manifest.sha256 -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum >manifest.sha256
    sha256sum -c manifest.sha256
  )
fi

{
  cat <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
rule_files: [/etc/prometheus/alerts.yml]
alerting:
  alertmanagers:
    - static_configs:
        - targets: [alertmanager:9093]
scrape_configs:
  - job_name: host
    static_configs:
YAML
  for node in "${GDC_NODES[@]}"; do
    geo="${geo_by_node[$node]:-null}"
    geo_labels="$(jq -cn --arg host "$node" --argjson geo "$geo" '{
      host: $host,
      city: ($geo.city // ""),
      country: ($geo.country // ""),
      latitude: (($geo.latitude // "") | tostring),
      longitude: (($geo.longitude // "") | tostring)
    }')"
    printf "      - targets: ['%s:9101']\n        labels: %s\n" "$(node_public_host "$node")" "$geo_labels"
  done
  for node in "${GDC_NODES[@]}"; do
    ml_host="$(node_ml_host "$node" || true)"
    [[ -n "$ml_host" ]] || continue
    ml_address="$(ssh -G "$ml_host" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
    [[ -n "$ml_address" ]] || die "cannot resolve monitoring address for GPU host $ml_host"
    printf "      - targets: ['%s:9101']\n        labels: {host: '%s', validator: '%s'}\n" "$ml_address" "$ml_host" "$node"
  done
  cat <<'YAML'
  - job_name: cadvisor
    static_configs:
YAML
  for node in "${GDC_NODES[@]}"; do
    printf "      - targets: ['%s:8088']\n        labels: {host: '%s'}\n" "$(node_public_host "$node")" "$node"
  done
  cat <<YAML
  - job_name: public-https
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets: ['https://$SITE_HOST/', 'https://$API_HOST/v1/status', 'https://$GRAFANA_HOST/login']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
YAML
  cat <<'YAML'
  - job_name: gonka-node
    static_configs:
YAML
  for node in "${GDC_NODES[@]}"; do
    printf "      - targets: ['%s:26660']\n        labels: {host: '%s'}\n" "$(node_public_host "$node")" "$node"
  done
  cat <<YAML
  - job_name: gateway
    scheme: https
    metrics_path: /metrics
    static_configs:
      - targets: ['$API_HOST:443']
        labels: {host: '$GATEWAY_NODE'}
  - job_name: telegram-consumer
    scheme: https
    metrics_path: /ops-telegram-metrics
    static_configs:
      - targets: ['$(node_public_host "$TELEGRAM_BOT_HOST"):443']
        labels: {host: '$TELEGRAM_BOT_HOST'}
YAML
} >"$OUTPUT/prometheus.yml"

echo "$OUTPUT"
