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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"; load_env "$INVENTORY"
source "$ROOT/scripts/profile.sh"
load_profiles
GATEWAY_VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
[[ "$GATEWAY_VERSION" =~ ^v[34]$ ]] || { echo 'GDC_GATEWAY_VERSION must be v3 or v4' >&2; exit 2; }
LOCAL_GATEWAY_IMAGE="${LOCAL_GATEWAY_IMAGE%-v4}-$GATEWAY_VERSION"
mkdir -p "$OUTPUT"
write_env "$OUTPUT/.env" "SITE_HOST=$SITE_HOST" "API_HOST=$API_HOST" "GRAFANA_HOST=$GRAFANA_HOST" "ACME_EMAIL=$ACME_EMAIL" "TELEGRAM_BOT_URL=$TELEGRAM_BOT_URL" \
  "NODE0_PUBLIC_HOST=$NODE0_PUBLIC_HOST" "NODE1_PUBLIC_HOST=$NODE1_PUBLIC_HOST" "NODE2_PUBLIC_HOST=$NODE2_PUBLIC_HOST" \
  "NODE3_PUBLIC_HOST=$NODE3_PUBLIC_HOST" "NODE4_PUBLIC_HOST=$NODE4_PUBLIC_HOST" \
  "GRAFANA_ADMIN_PASSWORD=$(<"$SECRETS/grafana.admin")" \
  "GRAFANA_PUBLIC_DASHBOARD_UID=$GRAFANA_PUBLIC_DASHBOARD_UID" "GRAFANA_PUBLIC_DASHBOARD_SHARE_UID=$GRAFANA_PUBLIC_DASHBOARD_SHARE_UID" "GRAFANA_PUBLIC_DASHBOARD_TOKEN=$GRAFANA_PUBLIC_DASHBOARD_TOKEN" \
  "PROMETHEUS_IMAGE=$PROMETHEUS_IMAGE" "ALERTMANAGER_IMAGE=$ALERTMANAGER_IMAGE" "BLACKBOX_IMAGE=$BLACKBOX_IMAGE" \
  "GRAFANA_IMAGE=$GRAFANA_IMAGE" "LOCAL_GATEWAY_IMAGE=$LOCAL_GATEWAY_IMAGE" "CADDY_IMAGE=$CADDY_IMAGE"
nodes='[]'
validators='[]'
node_indexes=()
geo_labels() {
  case "$1" in
    0) printf "city: 'Kansas City', region: 'Missouri', country: 'US', latitude: '39.0997', longitude: '-94.5786'" ;;
    1) printf "city: 'Helsinki', region: 'Uusimaa', country: 'FI', latitude: '60.1695', longitude: '24.9354'" ;;
    2) printf "city: 'Amsterdam', region: 'North Holland', country: 'NL', latitude: '52.3785', longitude: '4.9000'" ;;
    3) printf "city: 'London', region: 'England', country: 'GB', latitude: '51.5085', longitude: '-0.1257'" ;;
    4) printf "city: 'Portland', region: 'Oregon', country: 'US', latitude: '45.5234', longitude: '-122.6762'" ;;
  esac
}
geo_json() {
  case "$1" in
    0) printf '%s' '{"city":"Kansas City","country":"US","latitude":39.0997,"longitude":-94.5786}' ;;
    1) printf '%s' '{"city":"Helsinki","country":"FI","latitude":60.1695,"longitude":24.9354}' ;;
    2) printf '%s' '{"city":"Amsterdam","country":"NL","latitude":52.3785,"longitude":4.9000}' ;;
    3) printf '%s' '{"city":"London","country":"GB","latitude":51.5074,"longitude":-0.1278}' ;;
    4) printf '%s' '{"city":"Portland","country":"US","latitude":45.5234,"longitude":-122.6765}' ;;
  esac
}
for i in 0 1 2 3 4; do
  host="NODE${i}_PUBLIC_HOST"
  geo="$(geo_json "$i")"
  if [[ -e "$ROOT/state/joined/gdc-node$i" ]]; then
    node_indexes+=("$i")
    address="$(jq -r .address "$ACCOUNTS/gdc-node$i-cold.json")"
    ip="$(getent ahostsv4 "${!host}" | awk 'NR == 1 {print $1}')"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "cannot resolve public IPv4 for gdc-node$i" >&2; exit 1; }
    nodes="$(jq --arg name "gdc-node$i" --arg address "$address" --arg host "${!host}" --arg status "/status/node$i" --argjson geo "$geo" '. + [{name:$name,address:$address,publicHost:$host,statusBase:$status,mode:"active",geo:$geo}]' <<<"$nodes")"
    # Gonka exposes participant ownership rather than a license count; zero is
    # an explicit non-applicable value, never an invented entitlement count.
    validators="$(jq --arg owner "$address" --arg ip "$ip" --argjson geo "$geo" '. + [{ownerAddress:$owner,ip:$ip,licenseCount:0,geo:{lat:$geo.latitude,lon:$geo.longitude,city:$geo.city,country:$geo.country,isp:"unverified"}}]' <<<"$validators")'
  elif host_is_skipped "gdc-node$i"; then
    nodes="$(jq --arg name "gdc-node$i" --arg host "${!host}" --argjson geo "$geo" '. + [{name:$name,address:"–",publicHost:$host,statusBase:null,mode:"skip",reason:"Temporarily excluded by operator decision",geo:$geo}]' <<<"$nodes")"
  fi
done
jq -n --arg chain "$CHAIN_ID" --arg model "$MODEL_ID" --arg gateway "https://$API_HOST/v1" --arg direct "http://$NODE0_PUBLIC_HOST:8082/v1" --arg telegram "$TELEGRAM_BOT_URL" --arg grafana "https://$GRAFANA_HOST/d/gdc-overview/gonka-devnet-community-overview?orgId=1&from=now-6h&to=now" --argjson nodes "$nodes" --argjson validators "$validators" \
  '{chainId:$chain,model:$model,apiBase:$gateway,gatewayApiBase:$gateway,directMlApiBase:$direct,telegramBot:$telegram,grafana:$grafana,nodes:$nodes,validators:$validators}' | sed '1s/^/window.GDC_CONFIG = /;$s/$/;/' >"$OUTPUT/config.js"
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
  for i in "${node_indexes[@]}"; do host="NODE${i}_PUBLIC_HOST"; target="${!host}"; printf "      - targets: ['%s:9101']\n        labels: {host: 'gdc-node%s', %s}\n" "$target" "$i" "$(geo_labels "$i")"; done
  [[ " ${node_indexes[*]} " == *' 4 '* ]] && printf "      - targets: ['%s:9101']\n        labels: {host: 'gdc-node4-ml', %s}\n" "$NODE4_ML_MONITOR_HOST" "$(geo_labels 4)"
  cat <<'YAML'
  - job_name: cadvisor
    static_configs:
YAML
  for i in "${node_indexes[@]}"; do host="NODE${i}_PUBLIC_HOST"; target="${!host}"; printf "      - targets: ['%s:8088']\n        labels: {host: 'gdc-node%s'}\n" "$target" "$i"; done
  [[ " ${node_indexes[*]} " == *' 4 '* ]] && printf "      - targets: ['%s:8088']\n        labels: {host: 'gdc-node4-ml'}\n" "$NODE4_ML_MONITOR_HOST"
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
  for i in "${node_indexes[@]}"; do host="NODE${i}_PUBLIC_HOST"; target="${!host}"; printf "      - targets: ['%s:26660']\n        labels: {host: 'gdc-node%s'}\n" "$target" "$i"; done
} >"$OUTPUT/prometheus.yml"
echo "$OUTPUT"
