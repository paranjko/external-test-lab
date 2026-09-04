#!/usr/bin/env bash
# Select the observed runtime tuple from independent, identity-bound reports.
# Input is a JSON array.  This selector is deliberately independent of seed
# order and never treats an approval list as an active runtime.
set -Eeuo pipefail

usage() { echo "Usage: $0 --observations FILE --output FILE [--minimum-quorum N] [--minimum-independent-discovery-roots N]" >&2; }
die() { printf 'software_%s: %s\n' "$1" "$2" >&2; exit 1; }

observations=''; output=''; quorum_min=3; root_min=2
while (($#)); do
  case "$1" in
    --observations) observations="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --minimum-quorum) quorum_min="${2:-}"; shift 2 ;;
    --minimum-independent-discovery-roots) root_min="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$observations" && -n "$output" && "$quorum_min" =~ ^[0-9]+$ && "$quorum_min" -ge 2 && "$root_min" =~ ^[0-9]+$ && "$root_min" -ge 2 ]] || { usage; exit 2; }
command -v jq >/dev/null || die incomplete 'jq is required'

is_public_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  awk -F. 'NF == 4 && $1 >= 1 && $1 <= 223 && $2 <= 255 && $3 <= 255 && $4 <= 255 && !($1 == 10 || $1 == 127 || ($1 == 100 && $2 >= 64 && $2 <= 127) || ($1 == 169 && $2 == 254) || ($1 == 192 && ($2 == 0 || $2 == 168)) || ($1 == 172 && $2 >= 16 && $2 <= 31) || ($1 == 198 && ($2 == 18 || $2 == 19 || $2 == 51)) || ($1 == 203 && $2 == 0)) {ok=1} END {exit !ok}' <<<"$ip"
}

tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
jq -e '
  type == "array" and all(.[];
    (.node_id | type == "string" and test("^[a-f0-9]{40}$")) and
    (.remote_ip | type == "string" and length > 0) and
    (.status == "usable" or .status == "unavailable") and
    ((.core // {}) | (.application_name == "inference-chain") and (.version | type == "string" and length > 0) and (.commit | type == "string" and test("^[a-f0-9]{40}$"))) and
    ((.dapi // {}) | (.application_name == "decentralized-api") and (.version | type == "string" and length > 0) and (.commit | type == "string" and test("^[a-f0-9]{40}$"))) and
    (.discovery_root_ids | type == "array" and length >= 1 and all(.[]; type == "string" and test("^[a-f0-9]{40}$")))
  )
' "$observations" >/dev/null || die incomplete 'runtime observations are malformed'
while IFS= read -r remote_ip; do
  is_public_ipv4 "$remote_ip" || die incomplete 'usable runtime observation has no public IPv4 address'
done < <(jq -r '.[] | select(.status == "usable") | .remote_ip' "$observations")

# A node identity, address, and reported tuple are identity material.  Any
# collision makes the affected observations unusable; silently choosing one
# would make a minority or a Byzantine endpoint count twice.
conflicts="$(jq -c '
  [ .[] | select(.status == "usable") ] as $u |
  ([ $u | group_by(.node_id)[] | select(
      (map(.remote_ip) | unique | length > 1) or
      (map([.core.application_name,.core.version,.core.commit,.dapi.application_name,.dapi.version,.dapi.commit]) | unique | length > 1)
    ) | .[].node_id ] |
   unique) as $node_conflicts |
  ([ $u | group_by(.remote_ip)[] | select(length > 1 and (map(.node_id) | unique | length > 1)) | .[].remote_ip ] |
   unique) as $ip_conflicts |
  {node_ids:$node_conflicts,remote_ips:$ip_conflicts}
' "$observations")"
conflicting_nodes="$(jq -r '.node_ids | length' <<<"$conflicts")"
conflicting_ips="$(jq -r '.remote_ips | length' <<<"$conflicts")"
conflicting_node_ids="$(jq -c '.node_ids' <<<"$conflicts")"
conflicting_remote_ips="$(jq -c '.remote_ips' <<<"$conflicts")"

valid="$(jq -c --argjson conflicts "$conflicts" '
  [ .[] | select(.status == "usable")
    | select((.node_id as $id | ($conflicts.node_ids | index($id)) == null))
    | select((.remote_ip as $ip | ($conflicts.remote_ips | index($ip)) == null))
  ]
  | sort_by([.remote_ip,.node_id,.core.application_name,.core.version,.core.commit,.dapi.application_name,.dapi.version,.dapi.commit,.source,.api_url])
  | group_by(.remote_ip)
  | map(.[0] + {discovery_root_ids:(map(.discovery_root_ids[]) | unique | sort)})
' "$observations")"
valid_count="$(jq 'length' <<<"$valid")"
# The caller selects a reviewed local network quorum. The standalone default
# remains three; no supported policy may reduce it below two, so one endpoint
# can never select the executable profile.
if (( valid_count < quorum_min )); then
  if (( conflicting_nodes > 0 || conflicting_ips > 0 )); then result='identity_conflict'; else result='insufficient_quorum'; fi
else
  result='ready'
fi

groups="$(jq -c '
  group_by([.core.application_name,.core.version,.core.commit,.dapi.application_name,.dapi.version,.dapi.commit])
  | map({tuple:{core:.[0].core,dapi:.[0].dapi},count:length,node_ids:(map(.node_id)|sort),remote_ips:(map(.remote_ip)|sort),discovery_root_ids:(map(.discovery_root_ids[])|unique|sort),discovery_root_count:(map(.discovery_root_ids[])|unique|length)})
  | sort_by([-.count,.tuple.core.version,.tuple.core.commit,.tuple.dapi.version,.tuple.dapi.commit])
' <<<"$valid")"

# Selection is deliberately hierarchical.  A Core version is only comparable
# inside the exact DAPI cohort that first won a strict majority.  This avoids
# letting a minority DAPI release split or outvote the Core majority of the
# selected DAPI cohort.
dapi_groups="$(jq -c '
  group_by([.dapi.application_name,.dapi.version,.dapi.commit])
  | map({tuple:.[0].dapi,count:length,node_ids:(map(.node_id)|sort),remote_ips:(map(.remote_ip)|sort),discovery_root_ids:(map(.discovery_root_ids[])|unique|sort),discovery_root_count:(map(.discovery_root_ids[])|unique|length)})
  | sort_by([-.count,.tuple.version,.tuple.commit])
' <<<"$valid")"
dapi_group_count="$(jq 'length' <<<"$dapi_groups")"
dapi_selected='null'; dapi_majority_count=0; selection_stage='none'
core_groups='[]'; core_group_count=0; core_selected='null'; core_majority_count=0
pair_support_count=0; pair_discovery_root_ids='[]'; pair_discovery_root_count=0
selected='null'; selected_count=0

if (( valid_count >= quorum_min && dapi_group_count > 0 )); then
  dapi_selected="$(jq -c '.[0]' <<<"$dapi_groups")"
  dapi_majority_count="$(jq -r '.count' <<<"$dapi_selected")"
  selected_count="$dapi_majority_count"
  if (( dapi_majority_count * 2 > valid_count )); then
    selection_stage='core'
    dapi_tuple="$(jq -c '.tuple' <<<"$dapi_selected")"
    core_groups="$(jq -c --argjson dapi "$dapi_tuple" '
      [ .[] | select(.dapi == $dapi) ]
      | group_by([.core.application_name,.core.version,.core.commit])
      | map({tuple:.[0].core,count:length,node_ids:(map(.node_id)|sort),remote_ips:(map(.remote_ip)|sort),discovery_root_ids:(map(.discovery_root_ids[])|unique|sort),discovery_root_count:(map(.discovery_root_ids[])|unique|length)})
      | sort_by([-.count,.tuple.version,.tuple.commit])
    ' <<<"$valid")"
    core_group_count="$(jq 'length' <<<"$core_groups")"
    if (( core_group_count > 0 )); then
      core_selected="$(jq -c '.[0]' <<<"$core_groups")"
      core_majority_count="$(jq -r '.count' <<<"$core_selected")"
      selected_count="$core_majority_count"
      pair_support_count="$core_majority_count"
      pair_discovery_root_ids="$(jq -c '.discovery_root_ids' <<<"$core_selected")"
      pair_discovery_root_count="$(jq -r '.discovery_root_count' <<<"$core_selected")"
      if (( core_majority_count * 2 > dapi_majority_count )); then
        selection_stage='pair'
        if (( pair_support_count >= quorum_min && pair_discovery_root_count >= root_min )); then
          selected="$(jq -cn --argjson core "$(jq -c '.tuple' <<<"$core_selected")" --argjson dapi "$dapi_tuple" \
            --argjson count "$pair_support_count" --argjson nodes "$(jq -c '.node_ids' <<<"$core_selected")" \
            --argjson ips "$(jq -c '.remote_ips' <<<"$core_selected")" --argjson roots "$pair_discovery_root_ids" \
            --argjson root_count "$pair_discovery_root_count" \
            '{tuple:{core:$core,dapi:$dapi},count:$count,node_ids:$nodes,remote_ips:$ips,discovery_root_ids:$roots,discovery_root_count:$root_count}')"
          selected_count="$pair_support_count"
        fi
      fi
    fi
  fi
fi

if (( valid_count < quorum_min )); then
  if (( conflicting_nodes > 0 || conflicting_ips > 0 )); then result='identity_conflict'; else result='insufficient_quorum'; fi
elif [[ "$dapi_selected" != null && "$dapi_majority_count" -gt 0 && "$((dapi_majority_count * 2))" -le "$valid_count" ]]; then
  if (( conflicting_nodes > 0 || conflicting_ips > 0 )); then result='identity_conflict'; else result='no_strict_majority'; fi
elif [[ "$core_selected" != null && "$core_majority_count" -gt 0 && "$((core_majority_count * 2))" -le "$dapi_majority_count" ]]; then
  if (( conflicting_nodes > 0 || conflicting_ips > 0 )); then result='identity_conflict'; else result='no_strict_majority'; fi
elif (( pair_support_count < quorum_min )); then
  result='insufficient_quorum'
elif (( pair_discovery_root_count < root_min )); then
  result='insufficient_discovery_roots'
else
  result='ready'
fi

document="$(jq -cn --arg result "$result" --arg stage "$selection_stage" --argjson valid_count "$valid_count" --argjson quorum_min "$quorum_min" --argjson root_min "$root_min" \
  --argjson conflicting_nodes "$conflicting_node_ids" --argjson conflicting_ips "$conflicting_remote_ips" \
  --argjson groups "$groups" --argjson dapi_groups "$dapi_groups" --argjson dapi_group_count "$dapi_group_count" \
  --argjson dapi_selected "$dapi_selected" --argjson dapi_majority_count "$dapi_majority_count" \
  --argjson core_groups "$core_groups" --argjson core_group_count "$core_group_count" \
  --argjson core_selected "$core_selected" --argjson core_majority_count "$core_majority_count" \
  --argjson pair_support_count "$pair_support_count" --argjson pair_roots "$pair_discovery_root_ids" --argjson pair_root_count "$pair_discovery_root_count" --argjson selected "$selected" --argjson selected_count "$selected_count" \
  '{state:$result,selection_stage:$stage,valid_observation_count:$valid_count,minimum_quorum:$quorum_min,minimum_independent_discovery_roots:$root_min,strict_majority_count:$selected_count,dapi_group_count:$dapi_group_count,dapi_majority_count:$dapi_majority_count,dapi_groups:$dapi_groups,core_group_count:$core_group_count,core_majority_count:$core_majority_count,core_groups:$core_groups,pair_support_count:$pair_support_count,selected_discovery_root_ids:$pair_roots,selected_discovery_root_count:$pair_root_count,conflicting_node_ids:$conflicting_nodes,conflicting_remote_ips:$conflicting_ips,groups:$groups,dapi_selected:$dapi_selected,core_selected:$core_selected,selected:$selected,excluded_observations:[]}' | jq -cS .)"
mkdir -p "$(dirname "$output")"
printf '%s\n' "$document" >"$output"
if [[ "$result" != ready ]]; then
  die "$result" "runtime tuple selection failed: valid=$valid_count quorum=$quorum_min majority=$selected_count conflicts(node_id=$conflicting_nodes,ip=$conflicting_ips)"
fi
printf 'PASS selected strict-majority runtime tuple observations=%s majority=%s quorum=%s\n' "$valid_count" "$selected_count" "$quorum_min"
