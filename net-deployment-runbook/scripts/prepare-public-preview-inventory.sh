#!/usr/bin/env bash
set -Eeuo pipefail

# Produce the secret-free topology input for a Community DevNet preview from
# its public Bootstrap and the public peer lists advertised by those seeds.
# This is deliberately not an operator inventory: it contains no SSH aliases,
# credentials, ML-host mappings or local GDC_HOME paths.

output=''
bootstrap_url='https://gonka-dev.net/gonka-devnet-community/bootstrap.json'
bootstrap_file=''
net_info_dir=''
participants_file=''
release='v2026.08.06'
gateway_node='node4'
geo_enabled=true

usage() {
  cat >&2 <<'EOF'
Usage: prepare-public-preview-inventory.sh --output FILE [options]

Options:
  --bootstrap-url URL  canonical Community bootstrap URL
  --bootstrap-file FILE  previously downloaded Bootstrap JSON
  --net-info-dir DIR   fixture directory containing <host>.json responses
  --participants-file FILE  fixture participant API response
  --release PROFILE    existing runbook release profile (default v2026.08.06)
  --gateway-node NODE  public gateway participant (default node4)
  --no-geo            omit GeoIP enrichment (test/offline only)
EOF
}

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }

is_public_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((a <= 223 && b <= 255 && c <= 255 && d <= 255)) || return 1
  ((a != 0 && a != 10 && a != 127)) || return 1
  ! ((a == 169 && b == 254)) || return 1
  ! ((a == 172 && b >= 16 && b <= 31)) || return 1
  ! ((a == 192 && b == 168)) || return 1
}

resolve_geo() {
  local host="$1" ip response
  local -a ips=()
  mapfile -t ips < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  if ((${#ips[@]} != 1)) || ! is_public_ipv4 "${ips[0]:-}"; then
    jq -cn --arg error 'missing_or_ambiguous_public_ipv4' '{geo:null,geo_error:$error}'
    return 0
  fi
  ip="${ips[0]}"
  if ! response="$(curl --fail --silent --show-error --location --max-redirs 0 --connect-timeout 5 --max-time 20 --proto '=https' --proto-redir '=https' "https://ipwho.is/$ip" 2>/dev/null)"; then
    jq -cn --arg ip "$ip" --arg error 'geo_lookup_failed' '{ip:$ip,geo:null,geo_error:$error}'
    return 0
  fi
  jq -cer --arg ip "$ip" '
    select(.success == true) |
    {
      ip:$ip,
      geo:{
        latitude:(.latitude | tonumber), longitude:(.longitude | tonumber),
        rawLatitude:(.latitude | tonumber), rawLongitude:(.longitude | tonumber),
        displayLatitude:(.latitude | tonumber), displayLongitude:(.longitude | tonumber),
        city:(.city | strings), country:(.country | strings),
        isp:(.connection.isp // "unknown" | strings),
        source:"ip-geolocation", displaySource:"ip-geolocation", adjustmentKm:0,
        resolvedIp:$ip, accuracy:"city",
        locationLabel:((.city | strings) + ", " + (.country | strings))
      }
    }
  ' <<<"$response" 2>/dev/null || jq -cn --arg ip "$ip" --arg error 'invalid_geo_response' '{ip:$ip,geo:null,geo_error:$error}'
}

while (($#)); do
  case "$1" in
    --output) output="${2:-}"; shift 2 ;;
    --bootstrap-url) bootstrap_url="${2:-}"; bootstrap_file=''; shift 2 ;;
    --bootstrap-file) bootstrap_file="${2:-}"; shift 2 ;;
    --net-info-dir) net_info_dir="${2:-}"; shift 2 ;;
    --participants-file) participants_file="${2:-}"; shift 2 ;;
    --release) release="${2:-}"; shift 2 ;;
    --gateway-node) gateway_node="${2:-}"; shift 2 ;;
    --no-geo) geo_enabled=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$output" = /* && "$output" != / && "$output" != *..* && ! -e "$output" ]] || die 'output must be a new absolute safe path'
[[ "$release" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-rc\.[0-9]+)?$ ]] || die 'release profile is invalid'
[[ "$gateway_node" =~ ^node[0-9]+$ ]] || die 'gateway node must be node<decimal>'
[[ -z "$bootstrap_file" || ( -f "$bootstrap_file" && ! -L "$bootstrap_file" ) ]] || die 'bootstrap file is unsafe'
[[ -z "$net_info_dir" || ( -d "$net_info_dir" && ! -L "$net_info_dir" ) ]] || die 'net-info fixture directory is unsafe'
[[ -z "$participants_file" || ( -f "$participants_file" && ! -L "$participants_file" ) ]] || die 'participant fixture is unsafe'

if [[ -n "$bootstrap_file" ]]; then
  bootstrap="$(cat "$bootstrap_file")"
  bootstrap_origin="file:$(basename "$bootstrap_file")"
else
  [[ "$bootstrap_url" == 'https://gonka-dev.net/gonka-devnet-community/bootstrap.json' ]] || die 'only the canonical Community bootstrap URL is allowed'
  bootstrap="$(curl --fail --silent --show-error --location --max-redirs 0 --connect-timeout 5 --max-time 20 --proto '=https' --proto-redir '=https' "$bootstrap_url")" || die 'could not download canonical Community bootstrap'
  bootstrap_origin="$bootstrap_url"
fi

jq -e '
  .chain_id == "gonka-devnet-community" and
  (.seeds | type == "array" and length > 0) and
  all(.seeds[];
    (.rpc | type == "string" and test("^https://node[0-9]+\\.gonka-dev\\.net/chain-rpc/?$")) and
    (.p2p | type == "string" and test("^tcp://node[0-9]+\\.gonka-dev\\.net:5000$"))
  ) and
  (.brokers | type == "array" and length > 0) and
  ([.brokers[].api_urls[]? | select(type == "string" and test("^https://api\\.gonka-dev\\.net/?$"))] | length > 0)
' <<<"$bootstrap" >/dev/null || die 'bootstrap is not a safe Community topology document'

api_host="$(jq -r '[.brokers[].api_urls[] | select(test("^https://api\\.gonka-dev\\.net/?$"))][0] | sub("^https://"; "") | sub("/$"; "")' <<<"$bootstrap")"
declare -A hosts=()
seed_errors='[]'
participant_source=''
participant_response=''
while IFS=$'\t' read -r node host rpc; do
  [[ "$node" =~ ^node[0-9]+$ && "$host" == "$node.gonka-dev.net" ]] || die 'bootstrap seed identity is inconsistent'
  hosts["$node"]="$host"
  if [[ -n "$net_info_dir" ]]; then
    response_file="$net_info_dir/$host.json"
    [[ -f "$response_file" && ! -L "$response_file" ]] || die "missing net_info fixture for $host"
    response="$(cat "$response_file")"
  else
    if ! response="$(curl --fail --silent --show-error --location --max-redirs 0 --connect-timeout 5 --max-time 20 --proto '=https' --proto-redir '=https' "$rpc/net_info" 2>&1)"; then
      seed_errors="$(jq -c --arg node "$node" --arg host "$host" --arg error "$response" '. + [{node:$node,host:$host,error:$error}]' <<<"$seed_errors")"
      continue
    fi
  fi
  jq -e '
    .result.peers | type == "array" and
    all(.[]?;
      (.node_info.listen_addr | type == "string" and test("^tcp://node[0-9]+\\.gonka-dev\\.net:5000$"))
    )
  ' <<<"$response" >/dev/null || {
    if [[ -n "$net_info_dir" ]]; then
      die "net_info fixture from $host contains an unsafe peer identity"
    fi
    seed_errors="$(jq -c --arg node "$node" --arg host "$host" '. + [{node:$node,host:$host,error:"invalid_or_unsafe_net_info"}]' <<<"$seed_errors")"
    continue
  }
  while IFS=$'\t' read -r peer_node peer_host; do
    [[ "$peer_node" =~ ^node[0-9]+$ && "$peer_host" == "$peer_node.gonka-dev.net" ]] || die "unsafe peer identity advertised by $host"
    hosts["$peer_node"]="$peer_host"
  done < <(jq -r '
    .result.peers[]? | .node_info.listen_addr? // empty |
    capture("^tcp://(?<host>node(?<number>[0-9]+)\\.gonka-dev\\.net):5000$") |
    ["node" + .number, .host] | @tsv
  ' <<<"$response")
done < <(jq -r '.seeds[] | .rpc as $rpc | ($rpc | capture("^https://(?<host>node(?<number>[0-9]+)\\.gonka-dev\\.net)/chain-rpc/?$")) | ["node" + .number, .host, $rpc] | @tsv' <<<"$bootstrap")

if [[ -n "$participants_file" ]]; then
  participant_response="$(cat "$participants_file")"
  participant_source="file:$(basename "$participants_file")"
else
  while IFS=$'\t' read -r _ _ seed_rpc; do
    participant_url="${seed_rpc%/chain-rpc}/chain-api/productscience/inference/inference/participant?pagination.limit=100&pagination.count_total=true"
    if participant_response="$(curl --fail --silent --show-error --location --max-redirs 0 --connect-timeout 5 --max-time 20 --proto '=https' --proto-redir '=https' "$participant_url" 2>/dev/null)"; then
      participant_source="$participant_url"
      break
    fi
  done < <(jq -r '.seeds[] | .rpc as $rpc | ($rpc | capture("^https://(?<host>node(?<number>[0-9]+)\\.gonka-dev\\.net)/chain-rpc/?$")) | ["node" + .number, .host, $rpc] | @tsv' <<<"$bootstrap")
fi
[[ -n "$participant_source" && -n "$participant_response" ]] || die 'could not read the public participant inventory from any canonical seed'
jq -e '
  .participant | type == "array" and length > 0 and
  all(.[]?;
    (.inference_url | type == "string" and test("^https://node[0-9]+\\.gonka-dev\\.net/?$")) and
    (.address | type == "string" and length > 0) and
    (.status | type == "string")
  )
' <<<"$participant_response" >/dev/null || die 'participant API response contains an unsafe public endpoint'
while IFS=$'\t' read -r participant_node participant_host; do
  [[ "$participant_node" =~ ^node[0-9]+$ && "$participant_host" == "$participant_node.gonka-dev.net" ]] || die 'participant endpoint identity is inconsistent'
  hosts["$participant_node"]="$participant_host"
done < <(jq -r '.participant[] | (.inference_url | capture("^https://(?<host>node(?<number>[0-9]+)\\.gonka-dev\\.net)/?$") | ["node" + .number, .host] | @tsv)' <<<"$participant_response")

[[ -n "${hosts[$gateway_node]:-}" ]] || die "configured gateway node $gateway_node was not discovered"
mapfile -t nodes < <(printf '%s\n' "${!hosts[@]}" | sort -V)
(( ${#nodes[@]} > 0 )) || die 'no public nodes were discovered'

node_aliases="${nodes[*]}"
node_hosts=''
node_ports=''
for node in "${nodes[@]}"; do
  node_hosts+="${node}=${hosts[$node]} "
  node_ports+="${node}=5000 "
done
node_hosts="${node_hosts% }"
node_ports="${node_ports% }"
genesis_node="${nodes[0]}"
bootstrap_sha256="$(printf '%s' "$bootstrap" | sha256sum | awk '{print $1}')"
observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
node_catalog='[]'
for node in "${nodes[@]}"; do
  if [[ "$geo_enabled" == true ]]; then
    geo_record="$(resolve_geo "${hosts[$node]}")"
  else
    geo_record='{"geo":null,"geo_error":"geo_disabled"}'
  fi
  node_catalog="$(jq -c --arg name "$node" --arg host "${hosts[$node]}" --argjson geo_record "$geo_record" '. + [{name:$name,publicHost:$host} + $geo_record]' <<<"$node_catalog")"
done

install -d -m 0750 "$(dirname "$output")"
umask 077
cat >"$output" <<EOF
GDC_NODE_ALIASES=$(printf '%q' "$node_aliases")
GDC_NODE_PUBLIC_HOSTS=$(printf '%q' "$node_hosts")
GDC_NODE_P2P_PORTS=$(printf '%q' "$node_ports")
GDC_GENESIS_NODE=$(printf '%q' "$genesis_node")
GDC_PUBLIC_EDGE_NODE=$(printf '%q' "$gateway_node")
GDC_GATEWAY_NODE=$(printf '%q' "$gateway_node")
GDC_TELEGRAM_BOT_HOST=$(printf '%q' "$gateway_node")
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_RELEASE_PROFILE=$(printf '%q' "$release")
GDC_MODEL_PROFILE=qwen3-0.6b
CHAIN_ID=gonka-devnet-community
MODEL_ID=1
SITE_HOST=gonka-dev.net
API_HOST=$(printf '%q' "$api_host")
GRAFANA_HOST=grafana.gonka-dev.net
PUBLIC_EDGE_CIDR=0.0.0.0/0
EOF

jq -n \
  --arg origin "$bootstrap_origin" --arg sha256 "$bootstrap_sha256" --arg observed_at "$observed_at" \
  --arg release "$release" --arg gateway "$gateway_node" --arg api_host "$api_host" --arg participant_source "$participant_source" \
  --argjson nodes "$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -sc .)" \
  --argjson node_catalog "$node_catalog" \
  --argjson seed_errors "$seed_errors" \
  '{schema_version:1,bootstrap_origin:$origin,bootstrap_sha256:$sha256,observed_at:$observed_at,release_profile:$release,gateway_node:$gateway,api_host:$api_host,participant_source:$participant_source,nodes:$nodes,node_catalog:$node_catalog,seed_errors:$seed_errors}' \
  >"$output.receipt.json"
printf 'PASS prepared public preview inventory nodes=%s bootstrap_sha256=%s\n' "${#nodes[@]}" "$bootstrap_sha256"
