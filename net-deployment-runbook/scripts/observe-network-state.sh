#!/bin/sh
# Discover executable Host runtime from Bootstrap roots and public peers.
# This local observation layer is POSIX sh; runtime authority is selected by
# select-runtime-majority.sh, never by local release catalogues.
set -eu

usage() { printf 'Usage: %s --bootstrap-file FILE --bootstrap-url URL --chain-id ID --run-id ID --output FILE\n' "$0" >&2; }
die() { printf 'network_observation_%s: %s\n' "$1" "$2" >&2; exit 1; }

BOOTSTRAP=''
BOOTSTRAP_URL=''
CHAIN_ID=''
RUN_ID=''
OUTPUT=''
SELECTION_POLICY_ID='net-info-software-majority/v1'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bootstrap-file|--bootstrap-url|--chain-id|--run-id|--output)
      option=$1
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      case "$option" in
        --bootstrap-file) BOOTSTRAP=$1 ;;
        --bootstrap-url) BOOTSTRAP_URL=$1 ;;
        --chain-id) CHAIN_ID=$1 ;;
        --run-id) RUN_ID=$1 ;;
        --output) OUTPUT=$1 ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done
[ -r "$BOOTSTRAP" ] && [ -n "$OUTPUT" ] \
  && printf '%s\n' "$BOOTSTRAP_URL" | grep -Eq '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/%:-]*)?$' \
  && printf '%s\n' "$CHAIN_ID" | grep -Eq '^[a-z0-9][a-z0-9-]{0,127}$' \
  && printf '%s\n' "$RUN_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' \
  || { usage; exit 2; }

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"
QUORUM_POLICY_FILE=$ROOT/profiles/join-software-authority-policy.json
gdc_require_jq || exit $?
command -v curl >/dev/null 2>&1 || die dependency_missing 'curl is required'
"$ROOT/scripts/network-bootstrap.sh" verify "$BOOTSTRAP" >/dev/null
[ "$(jq -r .chain_id "$BOOTSTRAP")" = "$CHAIN_ID" ] || die chain_id_mismatch 'Bootstrap chain_id does not match --chain-id'
[ -r "$QUORUM_POLICY_FILE" ] || die dependency_missing 'local JOIN software authority policy is missing'
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
if jq -e --arg chain "$CHAIN_ID" '.networks | has($chain)' "$QUORUM_POLICY_FILE" >/dev/null; then quorum_scope=network; fi
quorum_min=$(jq -r --arg chain "$CHAIN_ID" '.networks[$chain].minimum_valid_observations // .default.minimum_valid_observations' "$QUORUM_POLICY_FILE")
root_min=$(jq -r --arg chain "$CHAIN_ID" '.networks[$chain].minimum_independent_discovery_roots // .default.minimum_independent_discovery_roots' "$QUORUM_POLICY_FILE")
quorum_policy_id=$(jq -r .policy_id "$QUORUM_POLICY_FILE")
quorum_policy_sha256=$(gdc_sha256 "$QUORUM_POLICY_FILE")

tmp=$(gdc_mktemp_dir)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
observed_at=$(date -u +%FT%TZ)
collection_timeout_seconds=${GDC_NETWORK_OBSERVATION_COLLECTION_TIMEOUT_SECONDS:-600}
case "$collection_timeout_seconds" in
  ''|*[!0-9]*|0) die invalid_timeout 'GDC_NETWORK_OBSERVATION_COLLECTION_TIMEOUT_SECONDS must be a positive integer' ;;
esac
collection_deadline_epoch=$(( $(date -u +%s) + collection_timeout_seconds ))
genesis_sha256=$(jq -r .genesis.sha256 "$BOOTSTRAP")
bootstrap_sha256=$(gdc_sha256 "$BOOTSTRAP")
: >"$tmp/seed-summaries.jsonl"
: >"$tmp/seed-contexts.jsonl"
: >"$tmp/seed-vote-exclusions.jsonl"
: >"$tmp/runtime-observations.jsonl"
: >"$tmp/discovered-peers.jsonl"

fetch_json_with_remote_ipv4() {
  fetch_now_epoch=$(date -u +%s)
  fetch_remaining_seconds=$((collection_deadline_epoch - fetch_now_epoch))
  [ "$fetch_remaining_seconds" -gt 0 ] || die observation_deadline 'network observation collection exceeded its bounded deadline before a seed request'
  fetch_combined=$2.with-remote
  curl -fsS --connect-timeout 5 --max-time "$fetch_remaining_seconds" --write-out '\n__GDC_REMOTE_IP__=%{remote_ip}\n' "$1" >"$fetch_combined" 2>/dev/null || {
    fetch_rc=$?
    [ "$(date -u +%s)" -lt "$collection_deadline_epoch" ] || die observation_deadline 'network observation collection exceeded its bounded deadline during a seed request'
    return "$fetch_rc"
  }
  [ "$(date -u +%s)" -lt "$collection_deadline_epoch" ] || die observation_deadline 'network observation collection exceeded its bounded deadline during a seed request'
  fetch_remote=$(sed -n 's/^__GDC_REMOTE_IP__=//p' "$fetch_combined" | tail -n 1)
  sed '/^__GDC_REMOTE_IP__=/d' "$fetch_combined" >"$2"
  rm -f "$fetch_combined"
  [ -n "$fetch_remote" ] || return 1
  printf '%s\n' "$fetch_remote"
}

derived_api() {
  derived_rpc=${1%/}
  case "$derived_rpc" in */chain-rpc) printf '%s' "${derived_rpc%/chain-rpc}" ;; *) return 1 ;; esac
}

summary() {
  jq -cn --argjson seed_index "$1" --arg expected "$2" --arg rpc "$3" --arg api "$4" \
    --arg status "$5" --arg reason "$6" --argjson catching_up "$7" --arg abci "$8" --arg comet "$9" \
    '{seed_index:$seed_index,expected_node_id:$expected,rpc_url:$rpc,api_url:$api,status:$status,reason:$reason,catching_up:$catching_up,abci_version:$abci,cometbft_version:$comet}'
}

seed_count=$(jq '.seeds | length' "$BOOTSTRAP")
index=0
while [ "$index" -lt "$seed_count" ]; do
  node_id=$(jq -r ".seeds[$index].node_id" "$BOOTSTRAP")
  rpc=$(jq -r ".seeds[$index].rpc" "$BOOTSTRAP")
  explicit_api=$(jq -r ".seeds[$index].api // empty" "$BOOTSTRAP")
  api=${explicit_api:-$(derived_api "$rpc" || true)}
  status_file=$tmp/status-$index.json
  abci_file=$tmp/abci-$index.json
  net_info_file=$tmp/net-info-$index.json
  versions_file=$tmp/versions-$index.json
  if ! seed_remote_ip=$(fetch_json_with_remote_ipv4 "${rpc%/}/status" "$status_file"); then
    summary "$index" "$node_id" "$rpc" "$api" unavailable status_endpoint false '' '' >>"$tmp/seed-summaries.jsonl"; index=$((index + 1)); continue
  fi
  if ! gdc_is_public_ipv4 "$seed_remote_ip"; then
    summary "$index" "$node_id" "$rpc" "$api" invalid status_remote_address false '' '' >>"$tmp/seed-summaries.jsonl"; index=$((index + 1)); continue
  fi
  if ! jq -e --arg id "$node_id" --arg chain "$CHAIN_ID" '.result.node_info.id == $id and .result.node_info.network == $chain and (.result.node_info.version | type == "string" and length > 0) and (.result.sync_info.catching_up | type == "boolean")' "$status_file" >/dev/null; then
    summary "$index" "$node_id" "$rpc" "$api" invalid status_identity false '' '' >>"$tmp/seed-summaries.jsonl"; index=$((index + 1)); continue
  fi
  catching_up=$(jq -r .result.sync_info.catching_up "$status_file")
  comet=$(jq -r '.result.node_info.version | ltrimstr("v")' "$status_file")
  if [ "$catching_up" != false ]; then
    summary "$index" "$node_id" "$rpc" "$api" unavailable catching_up true '' "$comet" >>"$tmp/seed-summaries.jsonl"; index=$((index + 1)); continue
  fi
  jq -cn --arg node_id "$node_id" --arg remote_ip "$seed_remote_ip" --arg comet "$comet" '{node_id:$node_id,remote_ip:$remote_ip,cometbft_version:$comet}' >>"$tmp/seed-contexts.jsonl"

  root_status=usable; root_reason=none
  if ! net_info_remote_ip=$(fetch_json_with_remote_ipv4 "${rpc%/}/net_info" "$net_info_file"); then
    root_status=unavailable; root_reason=net_info_endpoint
  elif ! gdc_is_public_ipv4 "$net_info_remote_ip" || [ "$net_info_remote_ip" != "$seed_remote_ip" ]; then
    root_status=invalid; root_reason=net_info_address_mismatch
  elif ! jq -e '.result.peers | type == "array"' "$net_info_file" >/dev/null 2>&1; then
    root_status=invalid; root_reason=net_info_response
  else
    jq -r '.result.peers[]? | [.node_info.id, (.remote_ip // "")] | @tsv' "$net_info_file" >"$tmp/net-peers-$index.tsv"
    while IFS="$(printf '\t')" read -r peer_id peer_ip; do
      printf '%s\n' "$peer_id" | grep -Eq '^[a-f0-9]{40}$' && [ -n "$peer_ip" ] || continue
      jq -cn --arg source_node "$node_id" --arg node_id "$peer_id" --arg remote_ip "$peer_ip" '{source_node_id:$source_node,node_id:$node_id,remote_ip:$remote_ip}' >>"$tmp/discovered-peers.jsonl"
    done <"$tmp/net-peers-$index.tsv"
  fi

  abci=''; seed_vote_status=usable; seed_vote_reason=none
  if [ -z "$api" ]; then
    seed_vote_status=invalid; seed_vote_reason=api_derivation
  elif ! abci_remote_ip=$(fetch_json_with_remote_ipv4 "${rpc%/}/abci_info" "$abci_file"); then
    seed_vote_status=unavailable; seed_vote_reason=abci_endpoint
  elif ! gdc_is_public_ipv4 "$abci_remote_ip"; then
    seed_vote_status=invalid; seed_vote_reason=abci_remote_address
  elif [ "$abci_remote_ip" != "$seed_remote_ip" ]; then
    seed_vote_status=invalid; seed_vote_reason=abci_address_mismatch
  elif ! jq -e '.result.response.version | type == "string" and length > 0' "$abci_file" >/dev/null 2>&1; then
    seed_vote_status=invalid; seed_vote_reason=abci_response
  else
    abci=$(jq -r '.result.response.version | ltrimstr("v")' "$abci_file")
    if ! versions_remote_ip=$(fetch_json_with_remote_ipv4 "${api%/}/v1/versions" "$versions_file"); then
      seed_vote_status=unavailable; seed_vote_reason=versions_endpoint
    elif ! gdc_is_public_ipv4 "$versions_remote_ip"; then
      seed_vote_status=invalid; seed_vote_reason=versions_remote_address
    elif [ "$versions_remote_ip" != "$seed_remote_ip" ]; then
      seed_vote_status=invalid; seed_vote_reason=runtime_address_mismatch
    elif ! jq -e '(.node_version.application_name == "inference-chain") and (.node_version.version | type == "string" and length > 0) and (.node_version.commit | type == "string" and test("^[0-9a-f]{40}$")) and (.api_version.application_name == "decentralized-api") and (.api_version.version | type == "string" and length > 0) and (.api_version.commit | type == "string" and test("^[0-9a-f]{40}$"))' "$versions_file" >/dev/null 2>&1; then
      seed_vote_status=invalid; seed_vote_reason=versions_response
    else
      core_version=$(jq -r '.node_version.version | ltrimstr("v")' "$versions_file")
      if [ "$core_version" != "$abci" ]; then
        seed_vote_status=invalid; seed_vote_reason=core_abci_conflict
      else
        api_source=derived; [ -n "$explicit_api" ] && api_source=declared
        jq -cn --argjson seed_index "$index" --arg node_id "$node_id" --arg remote_ip "$versions_remote_ip" --arg api_url "$api" --arg api_source "$api_source" --arg response_sha "$(gdc_sha256 "$versions_file")" --arg core_version "$core_version" --arg core_commit "$(jq -r .node_version.commit "$versions_file")" --arg dapi_version "$(jq -r '.api_version.version | ltrimstr("v")' "$versions_file")" --arg dapi_commit "$(jq -r .api_version.commit "$versions_file")" --arg root "$node_id" '{seed_index:$seed_index,expected_node_id:$node_id,node_id:$node_id,remote_ip:$remote_ip,status:"usable",reason:"none",source:"bootstrap_seed",discovery_root_ids:[$root],api_url:$api_url,api_source:$api_source,observed_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ")),versions_response_sha256:$response_sha,core:{application_name:"inference-chain",version:$core_version,commit:$core_commit},dapi:{application_name:"decentralized-api",version:$dapi_version,commit:$dapi_commit}}' >>"$tmp/runtime-observations.jsonl"
      fi
    fi
  fi
  if [ "$seed_vote_status" != usable ]; then
    jq -cn --arg node_id "$node_id" --arg remote_ip "$seed_remote_ip" --arg status "$seed_vote_status" --arg reason "$seed_vote_reason" '{node_id:$node_id,remote_ip:$remote_ip,status:$status,reason:$reason}' >>"$tmp/seed-vote-exclusions.jsonl"
  fi
  summary "$index" "$node_id" "$rpc" "$api" "$root_status" "$root_reason" "$catching_up" "$abci" "$comet" >>"$tmp/seed-summaries.jsonl"
  index=$((index + 1))
done

seeds_json=$(jq -cs 'sort_by(.seed_index)' "$tmp/seed-summaries.jsonl")
peer_excluded='[]'
: >"$tmp/peer-candidates.tsv"
if [ -s "$tmp/discovered-peers.jsonl" ]; then
  jq -cs 'sort_by([.node_id,.remote_ip,.source_node_id]) | group_by([.node_id,.remote_ip]) | map({node_id:.[0].node_id,remote_ip:.[0].remote_ip,discovery_root_ids:(map(.source_node_id) | unique | sort)})' "$tmp/discovered-peers.jsonl" >"$tmp/peer-inventory.json"
  jq -c '[group_by(.node_id)[] | select(map(.remote_ip) | unique | length > 1) | .[].node_id] as $bad_nodes | [group_by(.remote_ip)[] | select(length > 1 and (map(.node_id) | unique | length > 1)) | .[].remote_ip] as $bad_ips | {node_ids:($bad_nodes | unique),remote_ips:($bad_ips | unique)}' "$tmp/peer-inventory.json" >"$tmp/peer-conflicts.json"
  jq -c --slurpfile conflicts "$tmp/peer-conflicts.json" '($conflicts[0].node_ids) as $bad_nodes | ($conflicts[0].remote_ips) as $bad_ips | map(. as $peer | select((any($bad_nodes[]; . == $peer.node_id) | not) and (any($bad_ips[]; . == $peer.remote_ip) | not)))' "$tmp/peer-inventory.json" >"$tmp/peer-safe-inventory.json"
  peer_excluded=$(jq -c --slurpfile conflicts "$tmp/peer-conflicts.json" '($conflicts[0].node_ids) as $bad_nodes | ($conflicts[0].remote_ips) as $bad_ips | map(. as $peer | select(any($bad_nodes[]; . == $peer.node_id) or any($bad_ips[]; . == $peer.remote_ip)) | {node_id:$peer.node_id,remote_ip:"redacted",status:"excluded",reason:"identity_conflict"})' "$tmp/peer-inventory.json")
  jq -r '.[] | [.node_id,.remote_ip] | @tsv' "$tmp/peer-safe-inventory.json" >"$tmp/peer-safe.tsv"
  while IFS="$(printf '\t')" read -r peer_id peer_ip; do
    if gdc_is_public_ipv4 "$peer_ip"; then
      printf '%s\t%s\n' "$peer_id" "$peer_ip" >>"$tmp/peer-candidates.tsv"
    else
      peer_excluded=$(printf '%s\n' "$peer_excluded" | jq -c --arg node_id "$peer_id" '. + [{node_id:$node_id,remote_ip:"redacted",status:"excluded",reason:"non_public_peer"}]')
    fi
  done <"$tmp/peer-safe.tsv"
fi

if [ -s "$tmp/peer-candidates.tsv" ]; then
  sort -u "$tmp/peer-candidates.tsv" >"$tmp/peer-candidates.sorted"
  peer_index=0
  : >"$tmp/peer-jobs.tsv"
  while IFS="$(printf '\t')" read -r peer_id peer_ip; do
    peer_index=$((peer_index + 1))
    printf '%s\t%s\t%s\n' "$peer_id" "$peer_ip" "$tmp/peer-$peer_index.json" >>"$tmp/peer-jobs.tsv"
  done <"$tmp/peer-candidates.sorted"
  # Sequential probes preserve each child exit code and exact paths; no
  # whitespace-delimited xargs/awk command serialization is used.
  while IFS="$(printf '\t')" read -r peer_id peer_ip result_file; do
    now_epoch=$(date -u +%s)
    remaining_seconds=$((collection_deadline_epoch - now_epoch))
    [ "$remaining_seconds" -gt 0 ] || die observation_deadline 'peer inventory exceeded the bounded observation collection deadline'
    if gdc_run_with_timeout "$remaining_seconds" "$ROOT/scripts/probe-public-peer.sh" --node-id "$peer_id" --ip "$peer_ip" --chain-id "$CHAIN_ID" --output "$result_file"; then :; else
      peer_probe_rc=$?
      [ "$(date -u +%s)" -lt "$collection_deadline_epoch" ] || die observation_deadline 'peer inventory exceeded the bounded observation collection deadline'
      [ -s "$result_file" ] || die local_probe_launch "peer probe could not produce a receipt for node ${peer_id} (exit ${peer_probe_rc})"
      [ "$(jq -r '.reason // empty' "$result_file")" != dependency_missing ] || die dependency_missing "peer probe lacks a required local capability for node ${peer_id}"
    fi
  done <"$tmp/peer-jobs.tsv"
  while IFS="$(printf '\t')" read -r peer_id peer_ip result_file; do
    if [ -s "$result_file" ]; then
      peer_record=$(cat "$result_file")
      if [ "$(printf '%s\n' "$peer_record" | jq -r .status)" = usable ]; then
        peer_roots=$(jq -c --arg node "$peer_id" --arg ip "$peer_ip" '[.[] | select(.node_id == $node and .remote_ip == $ip) | .discovery_root_ids] | add | unique | sort' "$tmp/peer-safe-inventory.json")
        printf '%s\n' "$peer_record" | jq -c --argjson roots "$peer_roots" '. + {discovery_root_ids:$roots}' >>"$tmp/runtime-observations.jsonl"
      else
        peer_excluded=$(printf '%s\n' "$peer_excluded" | jq -c --argjson record "$peer_record" '. + [$record | {node_id,remote_ip,status,reason}]')
      fi
    else
      peer_excluded=$(printf '%s\n' "$peer_excluded" | jq -c --arg node_id "$peer_id" '. + [{node_id:$node_id,remote_ip:"redacted",status:"excluded",reason:"probe_missing"}]')
    fi
  done <"$tmp/peer-jobs.tsv"
fi

[ "$(date -u +%s)" -lt "$collection_deadline_epoch" ] || die observation_deadline 'network observation collection exceeded its bounded deadline'

peer_conflicting_node_ids='[]'
peer_conflicting_remote_ips='[]'
if [ -s "$tmp/peer-conflicts.json" ]; then
  peer_conflicting_node_ids=$(jq -c '.node_ids' "$tmp/peer-conflicts.json")
  [ "$(jq '.remote_ips | length' "$tmp/peer-conflicts.json")" -eq 0 ] || peer_conflicting_remote_ips='["redacted"]'
fi
seed_excluded=$(printf '%s\n' "$seeds_json" | jq -c '[.[] | select(.status != "usable") | {node_id:.expected_node_id,remote_ip:"redacted",status:(if .status == "invalid" then "invalid" else "unavailable" end),reason:.reason}]')
seed_votes_excluded='[]'
[ ! -s "$tmp/seed-vote-exclusions.jsonl" ] || seed_votes_excluded=$(jq -cs 'sort_by([.node_id,.remote_ip,.reason])' "$tmp/seed-vote-exclusions.jsonl")
excluded_observations=$(jq -cn --argjson seeds "$seed_excluded" --argjson seed_votes "$seed_votes_excluded" --argjson peers "$peer_excluded" '$seeds + $seed_votes + $peers | unique_by([.node_id,.remote_ip,.status,.reason]) | sort_by([.node_id,.remote_ip,.reason])')
jq -cs . "$tmp/runtime-observations.jsonl" >"$tmp/runtime-observations.json"
authority_file=$tmp/runtime-authority.json
if ! "$ROOT/scripts/select-runtime-majority.sh" --observations "$tmp/runtime-observations.json" --output "$authority_file" --minimum-quorum "$quorum_min" --minimum-independent-discovery-roots "$root_min" >/dev/null; then
  authority=$(jq -c --argjson excluded "$excluded_observations" --argjson nodes "$peer_conflicting_node_ids" --argjson ips "$peer_conflicting_remote_ips" '.excluded_observations = $excluded | .conflicting_node_ids = ((.conflicting_node_ids + $nodes) | unique | sort) | .conflicting_remote_ips = ((.conflicting_remote_ips + $ips) | unique | sort)' "$authority_file")
  failure=$(printf '%s\n' "$authority" | jq -r .state)
  printf '%s\n' "$authority" >"$authority_file"
  authority_receipt=$OUTPUT.software-authority.json
  mkdir -p "$(dirname "$authority_receipt")"
  install -m 0600 "$authority_file" "$authority_receipt"
  die "$failure" "independent runtime observations did not establish a quorum-backed component majority; receipt=$authority_receipt"
fi
authority=$(jq -c --argjson excluded "$excluded_observations" --argjson nodes "$peer_conflicting_node_ids" --argjson ips "$peer_conflicting_remote_ips" '.excluded_observations = $excluded | .conflicting_node_ids = ((.conflicting_node_ids + $nodes) | unique | sort) | .conflicting_remote_ips = ((.conflicting_remote_ips + $ips) | unique | sort)' "$authority_file")
printf '%s\n' "$authority" >"$authority_file"
network_comet=$(jq -rsc 'sort_by([.node_id,.remote_ip,.cometbft_version]) | .[0].cometbft_version' "$tmp/seed-contexts.jsonl")
selected_remote_ip=$(jq -r '.selected.remote_ips[0]' "$authority_file")
selected_tuple=$(jq -c '.selected.tuple' "$authority_file")
selected=$(jq -sc --arg ip "$selected_remote_ip" --arg comet "$network_comet" --argjson tuple "$selected_tuple" 'map(select(.remote_ip == $ip and .core == $tuple.core and .dapi == $tuple.dapi)) | sort_by([.node_id,.source,.api_url,.seed_index]) | .[0] | .cometbft = {version:$comet} | {seed_index,expected_node_id,api_url,api_source,observed_at,core:{version:.core.version,commit:.core.commit},dapi:{version:.dapi.version,commit:.dapi.commit},cometbft,versions_response_sha256}' "$tmp/runtime-observations.jsonl")
runtime=$(jq -cn --argjson selected "$selected" '{core:$selected.core,dapi:$selected.dapi,cometbft:$selected.cometbft}')
bootstrap=$(jq -cn --arg url "$BOOTSTRAP_URL" --arg sha "$bootstrap_sha256" --arg chain "$CHAIN_ID" --arg genesis "$genesis_sha256" '{url:$url,document_sha256:$sha,chain_id:$chain,genesis_sha256:$genesis}')
peers_json='[]'
[ ! -s "$tmp/peer-safe-inventory.json" ] || peers_json=$(jq -c '[.[] | {discovery_root_ids,node_id,remote_ip}] | sort_by([.node_id,.remote_ip])' "$tmp/peer-safe-inventory.json")
[ "$peer_excluded" = '[]' ] || peer_excluded=$(printf '%s\n' "$peer_excluded" | jq -c 'sort_by([.node_id,.remote_ip,.reason])')
quorum_policy=$(jq -cn --arg id "$quorum_policy_id" --arg scope "$quorum_scope" --arg sha "$quorum_policy_sha256" --argjson minimum "$quorum_min" --argjson roots "$root_min" '{policy_id:$id,source:"runbook_local",scope:$scope,minimum_valid_observations:$minimum,minimum_independent_discovery_roots:$roots,definition_sha256:$sha}')
policy=$(jq -cn --arg id "$SELECTION_POLICY_ID" --argjson quorum_policy "$quorum_policy" --argjson authority "$authority" --argjson peers "$peers_json" --argjson excluded "$excluded_observations" '{policy_id:$id,mode:"strict_majority",minimum_valid_observations:$authority.minimum_quorum,maximum_age_seconds:600,quorum_policy:$quorum_policy,authority:$authority,discovered_peers:$peers,excluded_observations:$excluded}')
policy_sha256=$(printf '%s\n' "$policy" | jq -cS . | gdc_sha256_stdin)
policy=$(printf '%s\n' "$policy" | jq -c --arg sha "$policy_sha256" '. + {policy_sha256:$sha}')
state_basis=$(jq -cn --arg policy "$SELECTION_POLICY_ID" --arg quorum_policy "$quorum_policy_id" --arg quorum_scope "$quorum_scope" --argjson quorum_min "$quorum_min" --argjson root_min "$root_min" --arg bootstrap_url "$BOOTSTRAP_URL" --arg chain "$CHAIN_ID" --arg genesis "$genesis_sha256" --argjson core "$(printf '%s\n' "$runtime" | jq -c .core)" --argjson dapi "$(printf '%s\n' "$runtime" | jq -c .dapi)" '{selection_policy_id:$policy,quorum_policy:{policy_id:$quorum_policy,scope:$quorum_scope,minimum_valid_observations:$quorum_min,minimum_independent_discovery_roots:$root_min},network:{bootstrap_url:$bootstrap_url,chain_id:$chain,genesis_sha256:$genesis},runtime:{core:({application_name:"inference-chain"} + $core),dapi:({application_name:"decentralized-api"} + $dapi),cometbft:{binding:"transitive-to-exact-core-commit"}}}' | jq -cS .)
network_state_id=$(printf '%s\n' "$state_basis" | gdc_sha256_stdin)
expires_at=$(gdc_utc_after_seconds 600)
document=$(jq -cn --arg run_id "$RUN_ID" --arg observed_at "$observed_at" --arg expires_at "$expires_at" --arg state_id "$network_state_id" --argjson bootstrap "$bootstrap" --argjson policy "$policy" --argjson seeds "$seeds_json" --argjson selected "$selected" --argjson runtime "$runtime" '{schema_version:1,kind:"gdc-network-observation",run_id:$run_id,observed_at:$observed_at,expires_at:$expires_at,network_state_id:$state_id,bootstrap:$bootstrap,policy:$policy,seeds:$seeds,runtime_api_origins:[$selected],runtime:$runtime,result:{state:"ready",reason:"none"}}' | jq -cS .)
mkdir -p "$(dirname "$OUTPUT")"
output_tmp=$(mktemp "$(dirname "$OUTPUT")/.network-observation.XXXXXX")
printf '%s\n' "$document" >"$output_tmp"
chmod 0600 "$output_tmp"
mv -f "$output_tmp" "$OUTPUT"
source_index=$(printf '%s\n' "$selected" | jq -r .seed_index)
source_kind=peer
[ "$source_index" -lt 0 ] || source_kind=seed
printf 'PASS observed Join runtime source_kind=%s source_index=%s usable_seed_roots=%s unavailable_or_invalid_seed_roots=%s observation=%s\n' "$source_kind" "$source_index" "$(printf '%s\n' "$seeds_json" | jq '[.[] | select(.status == "usable")] | length')" "$(printf '%s\n' "$seeds_json" | jq '[.[] | select(.status != "usable")] | length')" "$OUTPUT"
