#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --network SSH_ALIAS --ml-host SSH_ALIAS --data-root DIR --run-dir DIR [--expected-endpoint ENDPOINT --expected-node-id NODE_ID]" >&2
}

network=''
ml_host=''
data_root=''
run_dir=''
expected_endpoint=''
expected_node_id=''
while (($#)); do
  case "$1" in
    --network) network="${2:-}"; shift 2 ;;
    --ml-host) ml_host="${2:-}"; shift 2 ;;
    --data-root) data_root="${2:-}"; shift 2 ;;
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --expected-endpoint) expected_endpoint="${2:-}"; shift 2 ;;
    --expected-node-id) expected_node_id="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$network" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$ml_host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$network" != "$ml_host" ]] \
  || { usage; exit 2; }
[[ "$data_root" == /* && -d "$data_root" && ! -L "$data_root" && "$run_dir" == /* ]] \
  || { echo 'ML detach requires safe operator state and run directories' >&2; exit 2; }
if [[ -n "$expected_endpoint$expected_node_id" ]]; then
  [[ "$expected_endpoint" =~ ^[A-Za-z0-9.-]+$ && "$expected_node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] \
    || { echo 'ML detach expected donor binding is invalid' >&2; exit 2; }
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
association_refusal() {
  printf 'OPERATOR ACTION REQUIRED cannot validate the retained ML association for %s on %s; leave it unchanged and repair the association before retrying\n' "$ml_host" "$network" >&2
  exit 195
}
mkdir -p "$run_dir"
chmod 0700 "$run_dir"
[[ -d "$run_dir" && ! -L "$run_dir" ]] || { echo 'ML detach run directory is unsafe' >&2; exit 1; }

"$ROOT/scripts/check-running-network-node.sh" "$network" \
  || { echo "$network is not a running Network Node with a deployed DAPI endpoint" >&2; exit 1; }

current_config="$run_dir/node-config.before.json"
link_record="$run_dir/gdc-ml-link.before.json"
ssh -T "$network" 'sudo cat /srv/dai/deploy/node-config.json' >"$current_config"
link_managed=true
if ! ssh -T "$network" 'sudo cat /srv/dai/deploy/gdc-ml-link.json' >"$link_record"; then
  parent_state="$data_root/$network/state/ml-attached/$network.json"
  if [[ -f "$parent_state" && ! -L "$parent_state" ]]; then
    install -m 0600 "$parent_state" "$link_record"
    printf 'READY recovered ML endpoint association for %s from operator state\n' "$network"
  elif [[ -n "$expected_endpoint" ]]; then
    # The donor's durable lending receipt is the sole authority during the
    # narrow interval after lend and before parent association persistence.
    # Do not synthesize or remove a parent link: only remove this exact
    # endpoint from configuration/DAPI if it was actually reached.
    link_managed=false
    printf 'READY use retained donor binding for unfinished ML lending on %s\n' "$network"
  else
    echo "$network has no GDC-managed ML endpoint record" >&2
    exit 1
  fi
fi

if [[ "$link_managed" == true ]]; then
  endpoint="$(jq -er --arg node "$network" --arg alias "$ml_host" '
    select(.schema_version == 2 and .validator_alias == $node)
    | [.ml_hosts[] | select(.ssh_alias == $alias)]
    | if length == 1 then .[0].endpoint else error("ML endpoint is not uniquely attached") end
  ' "$link_record")" || association_refusal
  node_id="$(jq -er --arg node "$network" --arg alias "$ml_host" '
    select(.schema_version == 2 and .validator_alias == $node)
    | [.ml_hosts[] | select(.ssh_alias == $alias)]
    | if length == 1 then .[0].node_id else error("ML endpoint is not uniquely attached") end
  ' "$link_record")" || association_refusal
  if [[ -n "$expected_endpoint" && ( "$endpoint" != "$expected_endpoint" || "$node_id" != "$expected_node_id" ) ]]; then
    association_refusal
  fi
else
  endpoint="$expected_endpoint"
  node_id="$expected_node_id"
fi

ml_parent_record="$data_root/$ml_host/state/ml-parent.json"
if [[ -e "$ml_parent_record" || -L "$ml_parent_record" ]]; then
  [[ -f "$ml_parent_record" && ! -L "$ml_parent_record" ]] \
    || association_refusal
  jq -e --arg network_alias "$network" --arg ml_alias "$ml_host" --arg endpoint "$endpoint" --arg node_id "$node_id" '
    .schema_version == 1 and .kind == "gdc-ml-parent"
    and .network_alias == $network_alias and .ml_alias == $ml_alias
    and .endpoint == $endpoint and .node_id == $node_id
  ' "$ml_parent_record" >/dev/null \
    || association_refusal
fi

api_nodes_before="$run_dir/dapi-nodes.before.json"
ssh -T "$network" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes' >"$api_nodes_before"
api_has_node=false
if jq -e --arg id "$node_id" --arg host "$endpoint" '
  type == "array" and any(.[]; .node.id == $id and .node.host == $host)
' "$api_nodes_before" >/dev/null; then
  api_has_node=true
fi

valid_node_config() {
  jq -e '
    type == "array" and length > 0
    and all(.[]; (.id | type) == "string" and length > 0
        and (.host | type) == "string" and length > 0
        and (.inference_port | type) == "number"
        and (.poc_port | type) == "number")
    and (length as $count | [.[].id] | unique | length == $count)
    and (length as $count | [.[] | [ .host, .inference_port ]] | unique | length == $count)
  ' "$1" >/dev/null
}

valid_node_config "$current_config" \
  || { echo "$network has an invalid ML endpoint configuration" >&2; exit 1; }

next_config="$run_dir/node-config.next.json"
removed_id="$run_dir/removed-node-id"
if jq -e --arg id "$node_id" --arg host "$endpoint" 'any(.[]; .id == $id and .host == $host)' "$current_config" >/dev/null; then
  "$ROOT/scripts/remove-network-ml-endpoint.sh" \
    --input "$current_config" --ml-host "$endpoint" --ml-alias "$ml_host" \
    --output "$next_config" --id-output "$removed_id"
  [[ "$(<"$removed_id")" == "$node_id" ]] || { echo "$ml_host link record does not match $network node configuration" >&2; exit 1; }
else
  jq -e --arg id "$node_id" 'all(.[]; .id != $id)' "$current_config" >/dev/null \
    || { echo "$ml_host link record does not match $network node configuration" >&2; exit 1; }
  cp "$current_config" "$next_config"
  printf '%s\n' "$node_id" >"$removed_id"
fi
[[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] \
  || { echo "$ml_host has an unsafe ML endpoint node ID" >&2; exit 1; }

next_link="$run_dir/gdc-ml-link.next.json"
if [[ "$link_managed" == true ]]; then
  jq -ce --arg alias "$ml_host" '
    .ml_hosts |= map(select(.ssh_alias != $alias))
    | select(.ml_hosts | length > 0)
  ' "$link_record" >"$next_link" || true
else
  : >"$next_link"
fi

remote_dir="/tmp/gdc-ml-remove-${GDC_RUN_ID:-manual}-$network-$ml_host"
remote_config="$remote_dir/node-config.json"
remote_sync="$remote_dir/sync-node-config.sh"
remote_wait="$remote_dir/wait-dapi-worker-removal.sh"
remote_link="$remote_dir/gdc-ml-link.json"
ssh -T "$network" "rm -rf '$remote_dir' && mkdir -p '$remote_dir'"
scp -q "$next_config" "$network:$remote_config"
scp -q "$ROOT/02-node/sync-node-config.sh" "$network:$remote_sync"
scp -q "$ROOT/scripts/wait-dapi-worker-removal.sh" "$network:$remote_wait"
if [[ -s "$next_link" ]]; then scp -q "$next_link" "$network:$remote_link"; fi
remote_rc=0
if ssh -T "$network" "set -Eeuo pipefail
  sudo install -m 0644 '$remote_config' '/srv/dai/deploy/node-config.json.tmp'
  sudo mv '/srv/dai/deploy/node-config.json.tmp' '/srv/dai/deploy/node-config.json'
  if ${api_has_node}; then
    sudo bash '$remote_wait' --node-id '$node_id'
  fi
  sudo bash '$remote_sync'
  if ${link_managed}; then
    if test -s '$remote_link'; then
      sudo install -m 0640 '$remote_link' '/srv/dai/deploy/gdc-ml-link.json'
    else
      sudo rm -f '/srv/dai/deploy/gdc-ml-link.json'
    fi
  fi
  rm -rf '$remote_dir'"; then
  :
else
  remote_rc=$?
fi
if (( remote_rc != 0 )); then
  # A transport loss can occur after DELETE dispatch, just like its bounded
  # client timeout. Do not put the old endpoint back: that can race DAPI's
  # completed worker removal. The retained donor record makes a later start
  # retry readback/removal without guessing the parent.
  if (( remote_rc == 195 || remote_rc == 255 )); then
    echo "OPERATOR ACTION REQUIRED $network did not confirm removal of $ml_host; leave the donor stopped and rerun gdc host start $ml_host after parent DAPI readback succeeds" >&2
    exit 195
  fi
  echo "$network did not complete ML endpoint removal; leave $ml_host stopped and inspect the retained parent and donor records" >&2
  exit 1
fi

parent_state="$data_root/$network/state/ml-attached/$network.json"
if [[ "$link_managed" != true ]]; then
  : # No parent association existed; only the donor receipt authorized release.
elif [[ -s "$next_link" ]]; then
  install -d -m 0700 "$(dirname "$parent_state")"
  install -m 0600 "$next_link" "$parent_state"
  rm -f "$data_root/$network/state/ml-attached/$network"
else
  rm -f "$data_root/$network/state/ml-attached/$network" "$parent_state"
fi
rm -f -- "$ml_parent_record"
printf 'READY removed ML endpoint node_id=%s host=%s from %s\n' "$node_id" "$ml_host" "$network"
