#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

ACTION="${1:-}"
NODE_INPUT="${2:-}"
[[ "$ACTION" =~ ^(stop|start|verify|reset)$ ]] || die 'expected: node stop|start|verify|reset SSH_ALIAS'
[[ "$NODE_INPUT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid SSH alias: $NODE_INPUT"
NODE="$NODE_INPUT"
if [[ "$ACTION" != reset ]]; then
  load_project
  topology_contains_node "$NODE" || die "expected an SSH alias from GDC_NODE_ALIASES, got: $NODE"
fi
ssh_ready "$NODE" || die "$NODE is unreachable"

verify_node() {
  local url peer peer_url own_height peer_height catching lag
  step "Check deployed services on $NODE"
  ssh -T "$NODE" "cd /srv/dai/deploy/$NODE && docker compose --env-file .env ps node api proxy explorer --format '{{.Service}} {{.State}} {{.Status}}'" \
    | awk '
      $1 == "node" || $1 == "api" || $1 == "proxy" || $1 == "explorer" { seen[$1]=1; if ($2 != "running") bad=1 }
      END { exit bad || !(seen["node"] && seen["api"] && seen["proxy"] && seen["explorer"]) }
    ' || die "$NODE has an unavailable Network Node service"

  url="$(node_url "$NODE")"
  peer="$GENESIS_NODE"
  if [[ "$NODE" == "$GENESIS_NODE" ]]; then
    for candidate in "${GDC_NODES[@]}"; do
      [[ "$candidate" != "$NODE" && -e "$(node_joined_marker "$candidate")" ]] || continue
      peer="$candidate"
      break
    done
  fi
  peer_url="$(node_url "$peer")"
  own_status="$(curl -fsS "$url/chain-rpc/status")"
  peer_status="$(curl -fsS "$peer_url/chain-rpc/status")"
  own_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$own_status")"
  peer_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$peer_status")"
  catching="$(jq -r '.result.sync_info.catching_up' <<<"$own_status")"
  lag=$(( peer_height > own_height ? peer_height - own_height : own_height - peer_height ))
  [[ "$catching" == false && "$lag" -le "${GDC_NODE_SYNC_LAG:-5}" ]] \
    || die "$NODE is not synchronized (height=$own_height peer=$peer_height lag=$lag catching_up=$catching)"
  printf 'PASS %s synchronized at height=%s (peer=%s height=%s lag=%s)\n' "$NODE" "$own_height" "$peer" "$peer_height" "$lag"
}

wait_for_node_sync() {
  local url peer peer_url own_status peer_status own_height peer_height catching lag deadline
  url="$(node_url "$NODE")"
  peer="$GENESIS_NODE"
  if [[ "$NODE" == "$GENESIS_NODE" ]]; then
    for candidate in "${GDC_NODES[@]}"; do
      [[ "$candidate" != "$NODE" && -e "$(node_joined_marker "$candidate")" ]] || continue
      peer="$candidate"
      break
    done
  fi
  peer_url="$(node_url "$peer")"
  deadline=$((SECONDS + ${GDC_NODE_START_WAIT_SECONDS:-300}))
  while (( SECONDS < deadline )); do
    own_status="$(curl -fsS "$url/chain-rpc/status" 2>/dev/null || true)"
    peer_status="$(curl -fsS "$peer_url/chain-rpc/status" 2>/dev/null || true)"
    own_height="$(jq -r '.result.sync_info.latest_block_height // empty' <<<"$own_status" 2>/dev/null || true)"
    peer_height="$(jq -r '.result.sync_info.latest_block_height // empty' <<<"$peer_status" 2>/dev/null || true)"
    # `// empty` would discard JSON false, which is the desired caught-up
    # value. Convert the boolean explicitly before testing it.
    catching="$(jq -r '.result.sync_info.catching_up | tostring' <<<"$own_status" 2>/dev/null || true)"
    if [[ "$own_height" =~ ^[0-9]+$ && "$peer_height" =~ ^[0-9]+$ && "$catching" == false ]]; then
      lag=$(( peer_height > own_height ? peer_height - own_height : own_height - peer_height ))
      if (( lag <= ${GDC_NODE_SYNC_LAG:-5} )); then
        printf 'READY %s caught up at height=%s (peer=%s height=%s lag=%s)\n' "$NODE" "$own_height" "$peer" "$peer_height" "$lag"
        return 0
      fi
    fi
    printf 'WAIT  %s synchronization\n' "$NODE"
    sleep 3
  done
  die "$NODE did not catch up within ${GDC_NODE_START_WAIT_SECONDS:-300}s"
}

reset_node() {
  local linked_ml_host source endpoint candidate_host candidate_ip endpoint_ip link_record link_alias
  linked_ml_host=''
  source=''
  endpoint="$(ssh -T "$NODE" "jq -r '.[]?.host // empty' /srv/dai/deploy/$NODE/node-config.json 2>/dev/null" 2>/dev/null | head -n 1 || true)"

  # `phase-ml-attach.sh` records this relationship in the operator state. It
  # is available even when a reset intentionally has no .env or role input.
  if [[ -s "$STATE/ml-attached/$NODE" ]]; then
    linked_ml_host="$(<"$STATE/ml-attached/$NODE")"
    source='operator state'
  fi

  # The deployment record is written by `host join` / `host ml-attach`. It is
  # an explicit operator decision, unlike a guessed naming convention.
  if [[ -z "$linked_ml_host" && -n "$endpoint" && "$endpoint" != inference ]]; then
    link_record="$(ssh -T "$NODE" "sudo cat /srv/dai/deploy/$NODE/gdc-ml-link.json 2>/dev/null" 2>/dev/null || true)"
    link_alias="$(jq -er --arg node "$NODE" --arg endpoint "$endpoint" '
      select(.schema_version == 1 and .validator_alias == $node and .ml_endpoint == $endpoint)
      | .ml_ssh_alias
    ' <<<"$link_record" 2>/dev/null || true)"
    [[ "$link_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "cannot safely reset external GPU for $NODE: missing a valid /srv/dai/deploy/$NODE/gdc-ml-link.json; use the GDC_HOME created by host join or reset the GPU host explicitly"
    linked_ml_host="$link_alias"
    source='Network Node deployment record'
  fi

  if [[ -n "$linked_ml_host" && -n "$endpoint" && "$endpoint" != inference ]]; then
    candidate_host="$(ssh -G "$linked_ml_host" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
    candidate_ip="$(getent ahostsv4 "$candidate_host" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    endpoint_ip="$(getent ahostsv4 "$endpoint" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    { [[ "$endpoint" == "$candidate_host" ]] || [[ -n "$endpoint_ip" && "$endpoint_ip" == "$candidate_ip" ]]; } \
      || die "linked GPU host $linked_ml_host does not match $NODE ML endpoint $endpoint; no reset was performed"
  fi

  if [[ -n "$linked_ml_host" ]]; then
    [[ "$linked_ml_host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$linked_ml_host" != "$NODE" ]] \
      || die "refusing invalid linked GPU alias for $NODE: $linked_ml_host"
    ssh_ready "$linked_ml_host" \
      || die "linked GPU host $linked_ml_host for $NODE is unreachable; no reset was performed"
    printf 'READY detected linked GPU host %s for %s (%s)\n' "$linked_ml_host" "$NODE" "$source"
  fi

  reset_remote_host() {
    local host="$1" clear_edge="$2"
    ssh -T "$host" "NODE='$host' CLEAR_EDGE='$clear_edge' bash -s" <<'REMOTE'
set -Eeuo pipefail

systemctl disable --now "gdc-poc-winddown-watch@$NODE.service" >/dev/null 2>&1 || true

compose_down_dir() {
  local dir="$1" output rc
  [[ -d "$dir" ]] || return 0

  if [[ ! -f "$dir/compose.yaml" ]]; then
    return 0
  fi

  output="$(mktemp)"
  if [[ -f "$dir/.env" ]]; then
    if docker compose --env-file "$dir/.env" -f "$dir/compose.yaml" down -v --remove-orphans >"$output" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  else
    if docker compose -f "$dir/compose.yaml" down -v --remove-orphans >"$output" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  fi
  # Docker Compose prints this warning when an already-empty managed project
  # is reset. It is an expected idempotent state, not an operator warning.
  sed -E '/level=warning msg="Warning: No resource found to remove for project /d' "$output"
  # A previous interrupted render may have left a syntactically invalid .env.
  # The label-based cleanup immediately below does not read that file and is
  # the authoritative fallback for this managed deployment. Do not let the
  # broken input prevent recovery/reset from removing it.
  if (( rc != 0 )) && grep -Fq 'failed to read ' "$output" && grep -Fq '/.env:' "$output"; then
    printf 'READY removed managed Compose resources without reading invalid env directory=%s\n' "$dir"
    rc=0
  fi
  rm -f "$output"
  if (( rc != 0 )); then
    printf 'ERROR failed to remove managed Compose deployment directory=%s exit=%s\n' "$dir" "$rc" >&2
    return "$rc"
  fi
}

remove_compose_project() {
  local project="$1"
  local -a containers volumes networks

  mapfile -t containers < <(docker ps -aq --filter "label=com.docker.compose.project=$project")
  (( ${#containers[@]} == 0 )) || docker rm -f "${containers[@]}" >/dev/null

  mapfile -t volumes < <(docker volume ls -q --filter "label=com.docker.compose.project=$project")
  (( ${#volumes[@]} == 0 )) || docker volume rm -f "${volumes[@]}" >/dev/null

  mapfile -t networks < <(docker network ls -q --filter "label=com.docker.compose.project=$project")
  (( ${#networks[@]} == 0 )) || docker network rm "${networks[@]}" >/dev/null
}

compose_down_dir "/srv/dai/monitoring-agent"
# Public Caddy is OPS-owned and must survive an individual Host reset,
# including reset of the Host that also provides the public edge.
if [[ "$CLEAR_EDGE" == true ]]; then
  compose_down_dir "/srv/dai/edge"
fi
compose_down_dir "/srv/dai/deploy/$NODE"
remove_compose_project "$NODE"

rm -rf -- \
  "/srv/dai/deploy/$NODE" \
  "/srv/dai/$NODE" \
  "/tmp/gdc-deploy-"*-"$NODE" \
  "/tmp/gdc-reset-"*-"$NODE"
REMOTE
  }

  step "Reset $NODE deployment state and remove deployed containers"
  # The public edge is an OPS-owned service. Resetting its validator must not
  # also remove the Caddy instance that owns the public site, API and Grafana.
  reset_remote_host "$NODE" false
  if [[ -e "$STATE/joined/$NODE" ]]; then
    rm -f "$STATE/joined/$NODE"
  fi
  if [[ -n "$linked_ml_host" ]]; then
    step "Reset linked GPU host $linked_ml_host for $NODE"
    reset_remote_host "$linked_ml_host" false
    rm -f "$STATE/ml-attached/$NODE"
    printf 'PASS %s linked GPU reset\n' "$linked_ml_host"
  fi
  printf 'PASS %s reset\n' "$NODE"
}

case "$ACTION" in
  stop)
    step "Stop Network Node services on $NODE without deleting state"
    ssh -T "$NODE" "cd /srv/dai/deploy/$NODE && docker compose --env-file .env stop"
    printf 'PASS %s stopped; persistent data was retained\n' "$NODE"
    ;;
  start)
    step "Start Network Node services on $NODE from deployed release inputs"
    ssh -T "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh"
    wait_for_node_sync
    verify_node
    ;;
  verify) verify_node ;;
  reset) reset_node ;;
esac
