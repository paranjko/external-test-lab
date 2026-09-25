#!/usr/bin/env bash
set -Eeuo pipefail

# Compile the status-query subset of an exact renderer output into a small,
# non-programmable Caddy backend.  The PR source controls neither the runtime
# command nor egress destination; it can contribute only validated inventory
# query expressions.

input="${1:-}"
renderer_config="${2:-}"
preview_number="${3:-}"
output="${4:-}"
[[ -f "$input" && ! -L "$input" ]] || { echo 'renderer Caddyfile is unavailable or unsafe' >&2; exit 2; }
[[ -f "$renderer_config" && ! -L "$renderer_config" ]] || { echo 'renderer config is unavailable or unsafe' >&2; exit 2; }
[[ "$preview_number" =~ ^[1-9][0-9]*$ ]] || { echo 'preview number must be positive' >&2; exit 2; }
[[ -n "$output" ]] || { echo 'output Caddyfile is required' >&2; exit 2; }

query_for() {
  local endpoint="$1"
  awk -v endpoint="$endpoint" '
    $0 == "  handle /status/" endpoint " {" { inside=1; next }
    inside && $0 == "  }" { exit }
    inside && $0 ~ /^    rewrite \* \/api\/v1\/query\?query=/ {
      sub(/^    rewrite \* \/api\/v1\/query\?query=/, "")
      print
      exit
    }
  ' "$input"
}

gpu_query="$(query_for gpus)"
software_query="$(query_for software)"
[[ -n "$gpu_query" && -n "$software_query" ]] || { echo 'renderer output lacks required GPU/software queries' >&2; exit 1; }

# Keep the compiler intentionally narrow.  It accepts the stable query and
# the v172 bounded-retention variants, but rejects selectors, functions or
# destinations that would turn a status preview into a generic Prometheus API.
case "$gpu_query" in
  gdc_nvidia_memory_total_bytes|gdc_nvidia_memory_total_bytes%20unless%20\(time\(\)%20-%20timestamp\(gdc_nvidia_memory_total_bytes\)%20%3E%20120\)|last_over_time\(gdc_nvidia_memory_total_bytes%5B24h%5D\)) ;;
  *) echo 'renderer GPU query is not approved for preview observation' >&2; exit 1 ;;
esac
case "$software_query" in
  gdc_component_info|max_over_time\(timestamp\(gdc_component_info\)%5B24h%3A15s%5D\)) ;;
  *) echo 'renderer software query is not approved for preview observation' >&2; exit 1 ;;
esac

config_json="$(sed -n 's/^window\.GDC_CONFIG = //; s/;$//; p' "$renderer_config")"
[[ -n "$config_json" ]] || { echo 'renderer config does not contain window.GDC_CONFIG' >&2; exit 1; }
jq -e '
  (.gatewayNode | (type == "string") and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
  (.nodeCatalog | (type == "array") and (length > 0)) and
  all(.nodeCatalog[];
    (.name | (type == "string") and test("^node[0-9]+$")) and
    (.publicHost | (type == "string") and test("^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$"))
  ) and
  (([.nodeCatalog[].name] | length) == ([.nodeCatalog[].name] | unique | length)) and
  (.gatewayNode as $gateway | [.nodeCatalog[].name] | index($gateway) != null)
' <<<"$config_json" >/dev/null || { echo 'renderer config is not a safe preview route catalog' >&2; exit 1; }
gateway_node="$(jq -r .gatewayNode <<<"$config_json")"
node_routes="$(jq -r '.nodeCatalog[] | [.name, .publicHost] | @tsv' <<<"$config_json")"

mkdir -p "$(dirname "$output")"
cat >"$output" <<EOF
{
  admin off
  auto_https off
}

:8080 {
  respond /health "ready" 200
  @participants {
    method GET HEAD
    path /status/participants
  }
  handle @participants {
    rewrite * /preview/$preview_number/node/$gateway_node/chain-api/productscience/inference/inference/participant?pagination.limit=100&pagination.count_total=true
    reverse_proxy http://gdc-preview-egress:8080
  }
  handle /status/gpus {
    rewrite * /prometheus/api/v1/query?query=$gpu_query
    reverse_proxy http://gdc-preview-egress:8080
  }
  handle /status/software {
    rewrite * /prometheus/api/v1/query?query=$software_query
    reverse_proxy http://gdc-preview-egress:8080
  }
  @gateway_path path /status/gateway-health /status/gateway-health.prom /status/gateway/* /status/telegram-consumer
  respond @gateway_path "{\"error\":\"preview_gateway_status_unavailable\"}" 503
EOF

while IFS=$'\t' read -r node host; do
  [[ -n "$node" && -n "$host" ]] || continue
  cat >>"$output" <<EOF
  @node_${node} {
    method GET HEAD
    path_regexp node_${node} ^/status/$node(/.*)$
  }
  handle @node_${node} {
    rewrite * /preview/$preview_number/node/$node{re.node_${node}.1}
    reverse_proxy http://gdc-preview-egress:8080
  }
EOF
done <<<"$node_routes"

cat >>"$output" <<'EOF'
  respond "not found" 404
}
EOF

printf 'PASS rendered constrained status backend\n'
