#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBSERVE="$ROOT/scripts/observe-network-state.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT

ids=(0123456789abcdef0123456789abcdef01234567 89abcdef0123456789abcdef0123456789abcdef fedcba9876543210fedcba9876543210fedcba98 abcdef0123456789abcdef0123456789abcdef01 1234567890abcdef1234567890abcdef12345678)
printf '%s\n' "${ids[@]}" >"$tmp/ids"
jq -n --argjson ids "$(printf '%s\n' "${ids[@]}" | jq -R . | jq -cs .)" '
  {"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json",chain_id:"gonka-devnet-community",genesis:{sha256:"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},
   seeds:[$ids | to_entries[] | {node_id:.value,rpc:("https://node" + (.key|tostring) + ".example.test/chain-rpc"),p2p:("tcp://node" + (.key|tostring) + ".example.test:5000")} | if .node_id == $ids[0] then . + {api:"https://node0.example.test"} else . end],
   brokers:[]}
' >"$tmp/bootstrap.json"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
write_remote=false
for arg in "$@"; do
  [[ "$arg" == --write-out ]] && write_remote=true
done
node=
case "$url" in
  https://node[0-4].example.test/chain-rpc/*)
    host="${url#https://node}"; node="${host%%.*}"
    id="$(sed -n "$((node + 1))p" "$IDS_FILE")"
    case "${MODE:-good}:$node:$url" in
      all_roots_down:*:*status) exit 7 ;;
    esac
    case "$url" in
      */status)
        catching=false
        [[ "${MODE:-good}:$node" == catching_root:0 ]] && catching=true
        printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community","version":"0.38.19"},"sync_info":{"catching_up":%s}}}\n' "$id" "$catching"
        ;;
      */net_info)
        printf '{"result":{"peers":['
        for peer in 0 1 2 3 4; do
          ((peer == 0)) || printf ','
          printf '{"node_info":{"id":"%s"},"remote_ip":"8.8.4.%d"}' "$(sed -n "$((peer + 1))p" "$IDS_FILE")" "$((peer + 1))"
        done
        printf ']}}\n'
        ;;
      *) exit 2 ;;
    esac
    remote_ip="8.8.4.$((node + 1))"
    ;;
  http://8.8.4.[1-5]:8000/chain-rpc/*)
    exit 22
    ;;
  http://8.8.4.[1-5]:8000/v1/epochs/current/participants)
    octet="${url#http://8.8.4.}"; octet="${octet%%:*}"; node=$((octet - 1))
    case "${MODE:-good}:$node" in
      three_peer_down:[0-2]|four_peer_down:[0-3]) exit 7 ;;
    esac
    printf '{"block":{"header":{"chain_id":"gonka-devnet-community","height":"123"}}}\n'
    remote_ip="8.8.4.$octet"
    ;;
  http://8.8.4.[1-5]:8000/v1/versions)
    octet="${url#http://8.8.4.}"; octet="${octet%%:*}"; node=$((octet - 1))
    case "${MODE:-good}:$node" in
      three_peer_down:[0-2]|four_peer_down:[0-3]) exit 7 ;;
    esac
    dapi=0.2.15-post3
    commit=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0
    if [[ "${MODE:-good}:$node" == different_tuples:1 ]]; then
      dapi=0.2.16
      commit=18506d42c510e0cafe6acd748bcd8d83036cba40
    fi
    printf '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"%s","commit":"%s"}}\n' "$dapi" "$commit"
    remote_ip="8.8.4.$octet"
    ;;
  *) exit 2 ;;
esac
if [[ "$write_remote" == true ]]; then
  printf '\n__GDC_REMOTE_IP__=%s\n' "$remote_ip"
fi
EOF
chmod 0755 "$tmp/bin/curl"

run_case() {
  local mode="$1"
  MODE="$mode" IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" "$OBSERVE" \
    --bootstrap-file "$tmp/bootstrap.json" \
    --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
    --chain-id gonka-devnet-community --run-id fixture-run --output "$tmp/$mode.json"
}

run_case good
jq -e '
  .runtime_api_origins[0].seed_index == -1 and
  .runtime_api_origins[0].api_source == "derived" and
  .policy.minimum_valid_observations == 2 and
  .policy.quorum_policy.minimum_independent_discovery_roots == 2 and
  .policy.authority.valid_observation_count == 5 and
  .policy.authority.strict_majority_count == 5 and
  .policy.authority.selected_discovery_root_count == 5 and
  .policy.authority.selected.discovery_root_count == 5 and
  ([.seeds[] | select(.status == "usable")] | length) == 5
' "$tmp/good.json" >/dev/null

run_case three_peer_down
jq -e '.policy.authority.valid_observation_count == 2 and .policy.authority.strict_majority_count == 2 and .policy.authority.selected_discovery_root_count == 5 and .result.state == "ready"' "$tmp/three_peer_down.json" >/dev/null

if run_case four_peer_down >"$tmp/four-peer-down.out" 2>"$tmp/four-peer-down.err"; then
  echo 'one Community endpoint unexpectedly satisfied the local quorum' >&2
  exit 1
fi
jq -e '.state == "insufficient_quorum" and .valid_observation_count == 1 and .minimum_quorum == 2' "$tmp/four_peer_down.json.software-authority.json" >/dev/null

run_case different_tuples
jq -e '.runtime.dapi.version == "0.2.15-post3" and .policy.authority.strict_majority_count == 4' "$tmp/different_tuples.json" >/dev/null

run_case catching_root
jq -e '.seeds[0].status == "unavailable" and .seeds[0].reason == "catching_up" and .policy.authority.valid_observation_count == 5' "$tmp/catching_root.json" >/dev/null

if run_case all_roots_down >"$tmp/all-roots-down.out" 2>"$tmp/all-roots-down.err"; then
  echo 'unavailable discovery roots unexpectedly formed a runtime observation' >&2
  exit 1
fi
jq -e '.state == "insufficient_quorum" and .valid_observation_count == 0 and .minimum_quorum == 2' "$tmp/all_roots_down.json.software-authority.json" >/dev/null

if IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" "$OBSERVE" --bootstrap-file "$tmp/bootstrap.json" \
  --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
  --chain-id gonka-other --run-id fixture-run --output "$tmp/mismatch.json" >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"; then
  echo 'Bootstrap chain ID mismatch unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'network_observation_chain_id_mismatch:' "$tmp/mismatch.err"

printf 'PASS network observation: Community quorum, peer majority, catching-root rejection, unavailable peers, and fail-closed discovery\n'
