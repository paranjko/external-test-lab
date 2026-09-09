#!/usr/bin/env bash
# Discover one executable Host runtime from Bootstrap roots and their public
# peer inventory. This is a software-profile observation, not the later
# state-sync/quorum decision.
set -Eeuo pipefail

usage() { echo "Usage: $0 --bootstrap-file FILE --bootstrap-url URL --chain-id ID --run-id ID --output FILE" >&2; }
die() { printf 'network_observation_%s: %s\n' "$1" "$2" >&2; exit 1; }

BOOTSTRAP=''; BOOTSTRAP_URL=''; CHAIN_ID=''; RUN_ID=''; OUTPUT=''
SELECTION_POLICY_ID='net-info-software-majority/v1'
while (($#)); do
  case "$1" in
    --bootstrap-file) BOOTSTRAP="${2:-}"; shift 2 ;;
    --bootstrap-url) BOOTSTRAP_URL="${2:-}"; shift 2 ;;
    --chain-id) CHAIN_ID="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$BOOTSTRAP" && "$BOOTSTRAP_URL" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/%:-]*)?$ && "$CHAIN_ID" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && -n "$OUTPUT" ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUORUM_POLICY_FILE="$ROOT/profiles/join-software-authority-policy.json"
"$ROOT/scripts/network-bootstrap.sh" verify "$BOOTSTRAP" >/dev/null
command -v curl >/dev/null || die dependency_missing 'curl is required'
command -v jq >/dev/null || die dependency_missing 'jq is required'
[[ "$(jq -r .chain_id "$BOOTSTRAP")" == "$CHAIN_ID" ]] || die chain_id_mismatch 'Bootstrap chain_id does not match --chain-id'
[[ -r "$QUORUM_POLICY_FILE" ]] || die dependency_missing 'local JOIN software authority policy is missing'
jq -e '
  type == "object" and (keys | sort) == ["default","networks","policy_id","schema_version"] and
  .schema_version == 1 and .policy_id == "gdc-join-software-quorum/v1" and
  (.default | type == "object" and (keys | sort) == ["minimum_independent_discovery_roots","minimum_valid_observations"] and
    (.minimum_valid_observations | type == "number" and floor == . and . >= 2) and
    (.minimum_independent_discovery_roots | type == "number" and floor == . and . >= 2)) and
  (.networks | type == "object") and all(.networks | to_entries[];
    (.key | test("^[a-z0-9][a-z0-9-]{0,127}$")) and
    (.value | type == "object" and (keys | sort) == ["minimum_independent_discovery_roots","minimum_valid_observations"] and
      (.minimum_valid_observations | type == "number" and floor == . and . >= 2) and
      (.minimum_independent_discovery_roots | type == "number" and floor == . and . >= 2)))
' "$QUORUM_POLICY_FILE" >/dev/null || die policy_invalid 'local JOIN software authority policy is malformed'
quorum_scope=default
if jq -e --arg chain "$CHAIN_ID" '.networks | has($chain)' "$QUORUM_POLICY_FILE" >/dev/null; then
  quorum_scope=network
fi
quorum_min="$(jq -r --arg chain "$CHAIN_ID" '.networks[$chain].minimum_valid_observations // .default.minimum_valid_observations' "$QUORUM_POLICY_FILE")"
root_min="$(jq -r --arg chain "$CHAIN_ID" '.networks[$chain].minimum_independent_discovery_roots // .default.minimum_independent_discovery_roots' "$QUORUM_POLICY_FILE")"
quorum_policy_id="$(jq -r .policy_id "$QUORUM_POLICY_FILE")"
quorum_policy_sha256="$(sha256sum "$QUORUM_POLICY_FILE" | awk '{print $1}')"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
observed_at="$(date -u +%FT%TZ)"
expires_at="$(date -u -d '+600 seconds' +%FT%TZ)"
genesis_sha256="$(jq -r .genesis.sha256 "$BOOTSTRAP")"
bootstrap_sha256="$(sha256sum "$BOOTSTRAP" | awk '{print $1}')"

fetch_json_with_remote_ipv4() {
  local url="$1" output="$2" combined remote
  combined="${output}.with-remote"
  curl -fsS --connect-timeout 5 --max-time 15 --write-out '\n__GDC_REMOTE_IP__=%{remote_ip}\n' "$url" >"$combined" 2>/dev/null || return 1
  remote="$(sed -n 's/^__GDC_REMOTE_IP__=//p' "$combined" | tail -n 1)"
  sed '/^__GDC_REMOTE_IP__=/d' "$combined" >"$output"
  rm -f -- "$combined"
  [[ -n "$remote" ]] || return 1
  printf '%s\n' "$remote"
}
derived_api() {
  local rpc="${1%/}"
  [[ "$rpc" == */chain-rpc ]] || return 1
  printf '%s' "${rpc%/chain-rpc}"
}
summary() {
  local index="$1" node_id="$2" rpc="$3" api="$4" status="$5" reason="$6" catching_up="$7" abci="$8" comet="$9"
  jq -cn --argjson seed_index "$index" --arg expected "$node_id" --arg rpc "$rpc" --arg api "$api" \
    --arg status "$status" --arg reason "$reason" --argjson catching_up "$catching_up" --arg abci "$abci" --arg comet "$comet" \
    '{seed_index:$seed_index,expected_node_id:$expected,rpc_url:$rpc,api_url:$api,status:$status,reason:$reason,catching_up:$catching_up,abci_version:$abci,cometbft_version:$comet}'
}
is_public_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  awk -F. 'NF == 4 && $1 >= 1 && $1 <= 223 && $2 <= 255 && $3 <= 255 && $4 <= 255 && !($1 == 10 || $1 == 127 || ($1 == 100 && $2 >= 64 && $2 <= 127) || ($1 == 169 && $2 == 254) || ($1 == 192 && ($2 == 0 || $2 == 168)) || ($1 == 172 && $2 >= 16 && $2 <= 31) || ($1 == 198 && ($2 == 18 || $2 == 19 || $2 == 51)) || ($1 == 203 && $2 == 0)) {ok=1} END {exit !ok}' <<<"$ip"
}

seed_count="$(jq '.seeds | length' "$BOOTSTRAP")"
declare -a seed_summaries=()
declare -a seed_contexts=()
declare -a seed_vote_exclusions=()
declare -a runtime_observations=()
declare -a discovered_peers=()
for ((index=0; index<seed_count; index++)); do
  node_id="$(jq -r ".seeds[$index].node_id" "$BOOTSTRAP")"
  rpc="$(jq -r ".seeds[$index].rpc" "$BOOTSTRAP")"
  explicit_api="$(jq -r ".seeds[$index].api // empty" "$BOOTSTRAP")"
  api="${explicit_api:-$(derived_api "$rpc" || true)}"
  status_file="$tmp/status-$index.json"
  abci_file="$tmp/abci-$index.json"
  net_info_file="$tmp/net-info-$index.json"
  versions_file="$tmp/versions-$index.json"
  if ! seed_remote_ip="$(fetch_json_with_remote_ipv4 "${rpc%/}/status" "$status_file")"; then
    seed_summaries+=("$(summary "$index" "$node_id" "$rpc" "$api" unavailable status_endpoint false '' '')")
    continue
  fi
  if ! is_public_ipv4 "$seed_remote_ip"; then
    seed_summaries+=("$(summary "$index" "$node_id" "$rpc" "$api" invalid status_remote_address false '' '')")
    continue
  fi
  if ! jq -e --arg id "$node_id" --arg chain "$CHAIN_ID" '
    .result.node_info.id == $id and .result.node_info.network == $chain and
    (.result.node_info.version | type == "string" and length > 0) and
    (.result.sync_info.catching_up | type == "boolean")
  ' "$status_file" >/dev/null; then
    seed_summaries+=("$(summary "$index" "$node_id" "$rpc" "$api" invalid status_identity false '' '')")
    continue
  fi
  catching_up="$(jq -r .result.sync_info.catching_up "$status_file")"
  comet="$(jq -r '.result.node_info.version | ltrimstr("v")' "$status_file")"
  if [[ "$catching_up" != false ]]; then
    seed_summaries+=("$(summary "$index" "$node_id" "$rpc" "$api" unavailable catching_up true '' "$comet")")
    continue
  fi
  seed_contexts+=("$(jq -cn --arg node_id "$node_id" --arg remote_ip "$seed_remote_ip" --arg comet "$comet" \
    '{node_id:$node_id,remote_ip:$remote_ip,cometbft_version:$comet}')")

  # A synchronized Bootstrap seed is first a discovery root. Peer discovery
  # must not depend on that seed's DAPI availability.
  root_status=usable
  root_reason=none
  if ! net_info_remote_ip="$(fetch_json_with_remote_ipv4 "${rpc%/}/net_info" "$net_info_file")"; then
    root_status=unavailable
    root_reason=net_info_endpoint
  elif ! is_public_ipv4 "$net_info_remote_ip" || [[ "$net_info_remote_ip" != "$seed_remote_ip" ]]; then
    root_status=invalid
    root_reason=net_info_address_mismatch
  elif ! jq -e '.result.peers | type == "array"' "$net_info_file" >/dev/null 2>&1; then
    root_status=invalid
    root_reason=net_info_response
  else
    while IFS=$'\t' read -r peer_id peer_ip; do
      [[ "$peer_id" =~ ^[a-f0-9]{40}$ && -n "$peer_ip" ]] || continue
      discovered_peers+=("$(jq -cn --arg source_node "$node_id" --arg node_id "$peer_id" --arg remote_ip "$peer_ip" \
        '{source_node_id:$source_node,node_id:$node_id,remote_ip:$remote_ip}')")
    done < <(jq -r '.result.peers[]? | [.node_info.id, (.remote_ip // "")] | @tsv' "$net_info_file")
  fi

  # The seed itself contributes one ordinary software vote only when its ABCI
  # and /v1/versions responses are bound to the same public address as status.
  # The majority selector later deduplicates this vote against peer gossip.
  abci=''
  seed_vote_status=usable
  seed_vote_reason=none
  if [[ -z "$api" ]]; then
    seed_vote_status=invalid
    seed_vote_reason=api_derivation
  elif ! abci_remote_ip="$(fetch_json_with_remote_ipv4 "${rpc%/}/abci_info" "$abci_file")"; then
    seed_vote_status=unavailable
    seed_vote_reason=abci_endpoint
  elif ! is_public_ipv4 "$abci_remote_ip"; then
    seed_vote_status=invalid
    seed_vote_reason=abci_remote_address
  elif [[ "$abci_remote_ip" != "$seed_remote_ip" ]]; then
    seed_vote_status=invalid
    seed_vote_reason=abci_address_mismatch
  elif ! jq -e '.result.response.version | type == "string" and length > 0' "$abci_file" >/dev/null 2>&1; then
    seed_vote_status=invalid
    seed_vote_reason=abci_response
  else
    abci="$(jq -r '.result.response.version | ltrimstr("v")' "$abci_file")"
    if ! versions_remote_ip="$(fetch_json_with_remote_ipv4 "${api%/}/v1/versions" "$versions_file")"; then
      seed_vote_status=unavailable
      seed_vote_reason=versions_endpoint
    elif ! is_public_ipv4 "$versions_remote_ip"; then
      seed_vote_status=invalid
      seed_vote_reason=versions_remote_address
    elif [[ "$versions_remote_ip" != "$seed_remote_ip" ]]; then
      seed_vote_status=invalid
      seed_vote_reason=runtime_address_mismatch
    elif ! jq -e '
      (.node_version.application_name == "inference-chain") and
      (.node_version.version | type == "string" and length > 0) and
      (.node_version.commit | type == "string" and test("^[0-9a-f]{40}$")) and
      (.api_version.application_name == "decentralized-api") and
      (.api_version.version | type == "string" and length > 0) and
      (.api_version.commit | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$versions_file" >/dev/null 2>&1; then
      seed_vote_status=invalid
      seed_vote_reason=versions_response
    else
      core_version="$(jq -r '.node_version.version | ltrimstr("v")' "$versions_file")"
      if [[ "$core_version" != "$abci" ]]; then
        seed_vote_status=invalid
        seed_vote_reason=core_abci_conflict
      else
        api_source=derived
        [[ -n "$explicit_api" ]] && api_source=declared
        runtime_observations+=("$(jq -cn --argjson seed_index "$index" \
          --arg node_id "$node_id" --arg remote_ip "$versions_remote_ip" \
          --arg api_url "$api" --arg api_source "$api_source" \
          --arg response_sha "$(sha256sum "$versions_file" | awk '{print $1}')" \
          --arg core_version "$core_version" --arg core_commit "$(jq -r .node_version.commit "$versions_file")" \
          --arg dapi_version "$(jq -r '.api_version.version | ltrimstr("v")' "$versions_file")" \
          --arg dapi_commit "$(jq -r .api_version.commit "$versions_file")" \
          --arg root "$node_id" \
          '{seed_index:$seed_index,expected_node_id:$node_id,node_id:$node_id,remote_ip:$remote_ip,status:"usable",reason:"none",source:"bootstrap_seed",discovery_root_ids:[$root],api_url:$api_url,api_source:$api_source,observed_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ")),versions_response_sha256:$response_sha,core:{application_name:"inference-chain",version:$core_version,commit:$core_commit},dapi:{application_name:"decentralized-api",version:$dapi_version,commit:$dapi_commit}}')")
      fi
    fi
  fi
  if [[ "$seed_vote_status" != usable ]]; then
    seed_vote_exclusions+=("$(jq -cn --arg node_id "$node_id" --arg remote_ip "$seed_remote_ip" \
      --arg status "$seed_vote_status" --arg reason "$seed_vote_reason" \
      '{node_id:$node_id,remote_ip:$remote_ip,status:$status,reason:$reason}')")
  fi
  seed_summaries+=("$(summary "$index" "$node_id" "$rpc" "$api" "$root_status" "$root_reason" "$catching_up" "$abci" "$comet")")
done

seeds_json="$(printf '%s\n' "${seed_summaries[@]}" | jq -cs 'sort_by(.seed_index)')"
peer_candidates="$tmp/peer-candidates.tsv"
peer_excluded="[]"
if ((${#discovered_peers[@]})); then
  printf '%s\n' "${discovered_peers[@]}" | jq -cs '
    sort_by([.node_id,.remote_ip,.source_node_id])
    | group_by([.node_id,.remote_ip])
    | map({node_id:.[0].node_id,remote_ip:.[0].remote_ip,discovery_root_ids:(map(.source_node_id) | unique | sort)})
  ' >"$tmp/peer-inventory.json"
  jq -c '
    [group_by(.node_id)[] | select(map(.remote_ip) | unique | length > 1) | .[].node_id] as $bad_nodes |
    [group_by(.remote_ip)[] | select(length > 1 and (map(.node_id) | unique | length > 1)) | .[].remote_ip] as $bad_ips |
    {node_ids:($bad_nodes | unique),remote_ips:($bad_ips | unique)}
  ' "$tmp/peer-inventory.json" >"$tmp/peer-conflicts.json"
  jq -c --slurpfile conflicts "$tmp/peer-conflicts.json" '
    ($conflicts[0].node_ids) as $bad_nodes | ($conflicts[0].remote_ips) as $bad_ips |
    map(. as $peer | select((any($bad_nodes[]; . == $peer.node_id) | not) and (any($bad_ips[]; . == $peer.remote_ip) | not)))
  ' "$tmp/peer-inventory.json" >"$tmp/peer-safe-inventory.json"
  peer_excluded="$(jq -c --slurpfile conflicts "$tmp/peer-conflicts.json" '
    ($conflicts[0].node_ids) as $bad_nodes | ($conflicts[0].remote_ips) as $bad_ips |
    map(. as $peer | select(any($bad_nodes[]; . == $peer.node_id) or any($bad_ips[]; . == $peer.remote_ip)) | {node_id:$peer.node_id,remote_ip:"redacted",status:"excluded",reason:"identity_conflict"})
  ' "$tmp/peer-inventory.json")"
  while IFS=$'\t' read -r peer_id peer_ip; do
    if is_public_ipv4 "$peer_ip"; then
      printf '%s\t%s\n' "$peer_id" "$peer_ip" >>"$peer_candidates"
    else
      peer_excluded="$(jq -c --arg node_id "$peer_id" '. + [{node_id:$node_id,remote_ip:"redacted",status:"excluded",reason:"non_public_peer"}]' <<<"$peer_excluded")"
    fi
  done < <(jq -r '.[] | [.node_id,.remote_ip] | @tsv' "$tmp/peer-safe-inventory.json")
fi
if [[ -s "$peer_candidates" ]]; then
  sort -u "$peer_candidates" >"$peer_candidates.sorted"
  mv -f "$peer_candidates.sorted" "$peer_candidates"
  peer_index=0
  while IFS=$'\t' read -r peer_id peer_ip; do
    peer_index=$((peer_index + 1))
    printf '%s\t%s\t%s\n' "$peer_id" "$peer_ip" "$tmp/peer-$peer_index.json"
  done <"$peer_candidates" >"$tmp/peer-jobs.tsv"
  # Positional parameters expand in the bounded child shell.
  # shellcheck disable=SC2016
  if ! xargs -r -P16 -n5 bash -c '
    exec "$1" --node-id "$2" --ip "$3" --chain-id "$4" --output "$5"
  ' _ < <(awk -F'\t' -v script="$ROOT/scripts/probe-public-peer.sh" -v chain="$CHAIN_ID" '{print script,$1,$2,chain,$3}' "$tmp/peer-jobs.tsv"); then
    :
  fi
  while IFS=$'\t' read -r peer_id peer_ip result_file; do
    if [[ -s "$result_file" ]]; then
      peer_record="$(cat "$result_file")"
      if [[ "$(jq -r .status <<<"$peer_record")" == usable ]]; then
        peer_roots="$(jq -c --arg node "$peer_id" --arg ip "$peer_ip" '[.[] | select(.node_id == $node and .remote_ip == $ip) | .discovery_root_ids] | add | unique | sort' "$tmp/peer-safe-inventory.json")"
        runtime_observations+=("$(jq -c --argjson roots "$peer_roots" '. + {discovery_root_ids:$roots}' <<<"$peer_record")")
      else
        peer_excluded="$(jq -c --argjson record "$peer_record" '. + [$record | {node_id,remote_ip,status,reason}]' <<<"$peer_excluded")"
      fi
    else
      peer_excluded="$(jq -c --arg node_id "$peer_id" '. + [{node_id:$node_id,remote_ip:"redacted",status:"excluded",reason:"probe_missing"}]' <<<"$peer_excluded")"
    fi
  done <"$tmp/peer-jobs.tsv"
fi
peer_conflicting_node_ids='[]'; peer_conflicting_remote_ips='[]'
if [[ -s "$tmp/peer-conflicts.json" ]]; then
  peer_conflicting_node_ids="$(jq -c '.node_ids' "$tmp/peer-conflicts.json")"
  if [[ "$(jq '.remote_ips | length' "$tmp/peer-conflicts.json")" -gt 0 ]]; then
    peer_conflicting_remote_ips='["redacted"]'
  fi
fi
seed_excluded="$(jq -c '[.[] | select(.status != "usable") | {node_id:.expected_node_id,remote_ip:"redacted",status:(if .status == "invalid" then "invalid" else "unavailable" end),reason:.reason}]' <<<"$seeds_json")"
seed_votes_excluded='[]'
if ((${#seed_vote_exclusions[@]})); then
  seed_votes_excluded="$(printf '%s\n' "${seed_vote_exclusions[@]}" | jq -cs 'sort_by([.node_id,.remote_ip,.reason])')"
fi
excluded_observations="$(jq -cn --argjson seeds "$seed_excluded" --argjson seed_votes "$seed_votes_excluded" --argjson peers "$peer_excluded" '$seeds + $seed_votes + $peers | unique_by([.node_id,.remote_ip,.status,.reason]) | sort_by([.node_id,.remote_ip,.reason])')"
printf '%s\n' "${runtime_observations[@]}" | jq -cs . >"$tmp/runtime-observations.json"
authority_file="$tmp/runtime-authority.json"
if ! "$ROOT/scripts/select-runtime-majority.sh" --observations "$tmp/runtime-observations.json" --output "$authority_file" --minimum-quorum "$quorum_min" --minimum-independent-discovery-roots "$root_min" >/dev/null; then
  authority="$(jq -c --argjson excluded "$excluded_observations" --argjson nodes "$peer_conflicting_node_ids" --argjson ips "$peer_conflicting_remote_ips" '
    .excluded_observations = $excluded |
    .conflicting_node_ids = ((.conflicting_node_ids + $nodes) | unique | sort) |
    .conflicting_remote_ips = ((.conflicting_remote_ips + $ips) | unique | sort)
  ' "$authority_file")"
  failure="$(jq -r .state <<<"$authority")"
  printf '%s\n' "$authority" >"$authority_file"
  authority_receipt="${OUTPUT}.software-authority.json"
  mkdir -p "$(dirname "$authority_receipt")"
  install -m 0600 "$authority_file" "$authority_receipt"
  die "$failure" "independent runtime observations did not establish a quorum-backed component majority; receipt=$authority_receipt"
fi
authority="$(jq -c --argjson excluded "$excluded_observations" --argjson nodes "$peer_conflicting_node_ids" --argjson ips "$peer_conflicting_remote_ips" '
  .excluded_observations = $excluded |
  .conflicting_node_ids = ((.conflicting_node_ids + $nodes) | unique | sort) |
  .conflicting_remote_ips = ((.conflicting_remote_ips + $ips) | unique | sort)
' "$authority_file")"
printf '%s\n' "$authority" >"$authority_file"
# Keep one deterministic software representative from the winning address set.
# CometBFT context remains a real value from a chain-validated Bootstrap root.
network_comet="$(printf '%s\n' "${seed_contexts[@]}" | jq -rsc 'sort_by([.node_id,.remote_ip,.cometbft_version]) | .[0].cometbft_version')"
selected_remote_ip="$(jq -r '.selected.remote_ips[0]' "$authority_file")"
selected_tuple="$(jq -c '.selected.tuple' "$authority_file")"
selected="$(printf '%s\n' "${runtime_observations[@]}" | jq -sc --arg ip "$selected_remote_ip" --arg comet "$network_comet" --argjson tuple "$selected_tuple" '
  map(select(.remote_ip == $ip and .core == $tuple.core and .dapi == $tuple.dapi)) |
  sort_by([.node_id,.source,.api_url,.seed_index]) | .[0] |
  .cometbft = {version:$comet} |
  {seed_index,expected_node_id,api_url,api_source,observed_at,
   core:{version:.core.version,commit:.core.commit},
   dapi:{version:.dapi.version,commit:.dapi.commit},cometbft,versions_response_sha256}
')"
runtime="$(jq -cn --argjson selected "$selected" '{core:$selected.core,dapi:$selected.dapi,cometbft:$selected.cometbft}')"
bootstrap="$(jq -cn --arg url "$BOOTSTRAP_URL" --arg sha "$bootstrap_sha256" --arg chain "$CHAIN_ID" --arg genesis "$genesis_sha256" '{url:$url,document_sha256:$sha,chain_id:$chain,genesis_sha256:$genesis}')"
peers_json='[]'
if [[ -s "$tmp/peer-safe-inventory.json" ]]; then
  peers_json="$(jq -c '[.[] | {discovery_root_ids,node_id,remote_ip}] | sort_by([.node_id,.remote_ip])' "$tmp/peer-safe-inventory.json")"
fi
if [[ "$peer_excluded" != '[]' ]]; then
  peer_excluded="$(jq -c 'sort_by([.node_id,.remote_ip,.reason])' <<<"$peer_excluded")"
fi
quorum_policy="$(jq -cn --arg id "$quorum_policy_id" --arg scope "$quorum_scope" --arg sha "$quorum_policy_sha256" --argjson minimum "$quorum_min" \
  --argjson roots "$root_min" '{policy_id:$id,source:"runbook_local",scope:$scope,minimum_valid_observations:$minimum,minimum_independent_discovery_roots:$roots,definition_sha256:$sha}')"
policy="$(jq -cn --arg id "$SELECTION_POLICY_ID" --argjson quorum_policy "$quorum_policy" --argjson authority "$authority" --argjson peers "$peers_json" --argjson excluded "$excluded_observations" '{policy_id:$id,mode:"strict_majority",minimum_valid_observations:$authority.minimum_quorum,maximum_age_seconds:600,quorum_policy:$quorum_policy,authority:$authority,discovered_peers:$peers,excluded_observations:$excluded}')"
policy_sha256="$(jq -cS . <<<"$policy" | sha256sum | awk '{print $1}')"
policy="$(jq -c --arg sha "$policy_sha256" '. + {policy_sha256:$sha}' <<<"$policy")"
# network_state_id identifies executable network semantics. Availability,
# discovery inventory, quorum counts, timestamps, and representative origin
# remain receipt evidence and therefore do not perturb this stable identity.
# CometBFT is bundled by the exact Core commit; its observed version is kept
# on the representative origin while its executable identity is transitive.
state_basis="$(jq -cn --arg policy "$SELECTION_POLICY_ID" --arg quorum_policy "$quorum_policy_id" --arg quorum_scope "$quorum_scope" --argjson quorum_min "$quorum_min" --argjson root_min "$root_min" --arg bootstrap_url "$BOOTSTRAP_URL" --arg chain "$CHAIN_ID" --arg genesis "$genesis_sha256" --argjson core "$(jq -c .core <<<"$runtime")" --argjson dapi "$(jq -c .dapi <<<"$runtime")" '{selection_policy_id:$policy,quorum_policy:{policy_id:$quorum_policy,scope:$quorum_scope,minimum_valid_observations:$quorum_min,minimum_independent_discovery_roots:$root_min},network:{bootstrap_url:$bootstrap_url,chain_id:$chain,genesis_sha256:$genesis},runtime:{core:({application_name:"inference-chain"} + $core),dapi:({application_name:"decentralized-api"} + $dapi),cometbft:{binding:"transitive-to-exact-core-commit"}}}' | jq -cS .)"
network_state_id="$(printf '%s\n' "$state_basis" | sha256sum | awk '{print $1}')"
document="$(jq -cn --arg run_id "$RUN_ID" --arg observed_at "$observed_at" --arg expires_at "$expires_at" --arg state_id "$network_state_id" \
  --argjson bootstrap "$bootstrap" --argjson policy "$policy" --argjson seeds "$seeds_json" --argjson selected "$selected" --argjson runtime "$runtime" \
  '{schema_version:1,kind:"gdc-network-observation",run_id:$run_id,observed_at:$observed_at,expires_at:$expires_at,network_state_id:$state_id,bootstrap:$bootstrap,policy:$policy,seeds:$seeds,runtime_api_origins:[$selected],runtime:$runtime,result:{state:"ready",reason:"none"}}' | jq -cS .)"
mkdir -p "$(dirname "$OUTPUT")"
output_tmp="$(mktemp "$(dirname "$OUTPUT")/.network-observation.XXXXXX")"
printf '%s\n' "$document" >"$output_tmp"
chmod 0600 "$output_tmp"
mv -f "$output_tmp" "$OUTPUT"
source_index="$(jq -r .seed_index <<<"$selected")"
source_kind=peer
(( source_index >= 0 )) && source_kind=seed
printf 'PASS observed Join runtime source_kind=%s source_index=%s usable_seed_roots=%s unavailable_or_invalid_seed_roots=%s observation=%s\n' \
  "$source_kind" "$source_index" \
  "$(jq '[.[] | select(.status == "usable")] | length' <<<"$seeds_json")" "$(jq '[.[] | select(.status != "usable")] | length' <<<"$seeds_json")" "$OUTPUT"
