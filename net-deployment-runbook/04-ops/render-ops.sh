#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --inventory FILE --accounts-dir DIR --secrets-dir DIR --output-dir DIR" >&2; }
INVENTORY=''; ACCOUNTS=''; SECRETS=''; OUTPUT=''
while (($#)); do case "$1" in
  --inventory) INVENTORY="$2"; shift 2 ;;
  --accounts-dir) ACCOUNTS="$2"; shift 2 ;;
  --secrets-dir) SECRETS="$2"; shift 2 ;;
  --output-dir) OUTPUT="$2"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ -n "$INVENTORY" && -n "$ACCOUNTS" && -n "$SECRETS" && -n "$OUTPUT" ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
source "$ROOT/scripts/profile.sh"
load_profiles
GATEWAY_VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
[[ "$GATEWAY_VERSION" =~ ^v[34]$ ]] || { echo 'GDC_GATEWAY_VERSION must be v3 or v4' >&2; exit 2; }
LOCAL_GATEWAY_IMAGE="${LOCAL_GATEWAY_IMAGE%-v4}-$GATEWAY_VERSION"
mkdir -p "$OUTPUT"

gateway_public_host="$(node_public_host "$GATEWAY_NODE")"
write_env "$OUTPUT/.env" \
  "SITE_HOST=$SITE_HOST" "API_HOST=$API_HOST" "GRAFANA_HOST=$GRAFANA_HOST" "ACME_EMAIL=$ACME_EMAIL" \
  "TELEGRAM_BOT_URL=$TELEGRAM_BOT_URL" "GATEWAY_PUBLIC_HOST=$gateway_public_host" \
  "GRAFANA_ADMIN_PASSWORD=$(<"$SECRETS/grafana.admin")" \
  "GRAFANA_PUBLIC_DASHBOARD_UID=$GRAFANA_PUBLIC_DASHBOARD_UID" "GRAFANA_PUBLIC_DASHBOARD_SHARE_UID=$GRAFANA_PUBLIC_DASHBOARD_SHARE_UID" "GRAFANA_PUBLIC_DASHBOARD_TOKEN=$GRAFANA_PUBLIC_DASHBOARD_TOKEN" \
  "PROMETHEUS_IMAGE=$PROMETHEUS_IMAGE" "ALERTMANAGER_IMAGE=$ALERTMANAGER_IMAGE" "BLACKBOX_IMAGE=$BLACKBOX_IMAGE" \
  "GRAFANA_IMAGE=$GRAFANA_IMAGE" "LOCAL_GATEWAY_IMAGE=$LOCAL_GATEWAY_IMAGE" "CADDY_IMAGE=$CADDY_IMAGE"

nodes='[]'; validators='[]'; node_catalog='[]'
joined_nodes=()
for node in "${GDC_NODES[@]}"; do
  host="$(node_public_host "$node")"
  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  node_catalog="$(jq --arg name "$node" --arg host "$host" --arg status "/status/$node" --arg ip "$ip" \
    '. + [{name:$name,publicHost:$host,statusBase:$status,ip:$ip,geo:null}]' <<<"$node_catalog")"
  [[ -e "$ROOT/state/joined/$node" ]] || continue
  address="$(jq -r .address "$ACCOUNTS/$node-cold.json")"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "cannot resolve public IPv4 for $node" >&2; exit 1; }
  joined_nodes+=("$node")
  nodes="$(jq --arg name "$node" --arg address "$address" --arg host "$host" --arg status "/status/$node" --arg ip "$ip" \
    '. + [{name:$name,address:$address,publicHost:$host,statusBase:$status,ip:$ip,mode:"active",geo:null}]' <<<"$nodes")"
done

jq -n --arg chain "$CHAIN_ID" --arg model "$MODEL_ID" --arg gateway "https://$API_HOST/v1" \
  --arg direct "http://$gateway_public_host:8082/v1" --arg telegram "$TELEGRAM_BOT_URL" \
  --arg grafanaNetwork "https://$GRAFANA_HOST/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc&kiosk" \
  --arg grafanaInference "https://$GRAFANA_HOST/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-7d&to=now&timezone=utc&kiosk" \
  --arg gatewayNode "$GATEWAY_NODE" --argjson nodes "$nodes" --argjson validators "$validators" --argjson nodeCatalog "$node_catalog" \
  '{chainId:$chain,model:$model,apiBase:$gateway,gatewayApiBase:$gateway,directMlApiBase:$direct,telegramBot:$telegram,grafanaNetwork:$grafanaNetwork,grafanaInference:$grafanaInference,gatewayNode:$gatewayNode,nodes:$nodes,nodeCatalog:$nodeCatalog,validators:$validators}' \
  | sed '1s/^/window.GDC_CONFIG = /;$s/$/;/' >"$OUTPUT/config.js"

{
  cat <<'CADDY'
{
  email {$ACME_EMAIL}
  admin 127.0.0.1:2019
}
{$GATEWAY_PUBLIC_HOST} {
  encode zstd gzip
  handle_path /gateway/* {
    reverse_proxy 127.0.0.1:18080
  }
  handle {
    reverse_proxy 127.0.0.1:8000
  }
}
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
      printf '  handle_path /status/%s/* {\n    reverse_proxy 127.0.0.1:8000\n  }\n' "$node"
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
  for node in "${joined_nodes[@]}"; do
    printf "      - targets: ['%s:9101']\n        labels: {host: '%s'}\n" "$(node_public_host "$node")" "$node"
    ml_host="$(node_ml_host "$node" || true)"
    [[ -n "$ml_host" && -e "$ROOT/state/ml-attached/$node" ]] || continue
    ml_endpoint="$(ssh -G "$ml_host" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
    [[ -n "$ml_endpoint" ]] || { echo "cannot resolve attached ML host $ml_host" >&2; exit 1; }
    printf "      - targets: ['%s:9101']\n        labels: {host: '%s'}\n" "$ml_endpoint" "$ml_host"
  done
  cat <<'YAML'
  - job_name: cadvisor
    static_configs:
YAML
  for node in "${joined_nodes[@]}"; do
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
  for node in "${joined_nodes[@]}"; do
    printf "      - targets: ['%s:26660']\n        labels: {host: '%s'}\n" "$(node_public_host "$node")" "$node"
  done
  cat <<YAML
  - job_name: gateway
    metrics_path: /metrics
    static_configs:
      - targets: ['host.docker.internal:18080']
        labels: {host: '$GATEWAY_NODE'}
YAML
} >"$OUTPUT/prometheus.yml"

echo "$OUTPUT"
