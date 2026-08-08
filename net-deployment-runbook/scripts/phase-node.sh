#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

ACTION="${1:-}"
NODE_INPUT="${2:-}"
topology_contains_node "$NODE_INPUT" || die "expected an SSH alias from GDC_NODE_ALIASES, got: $NODE_INPUT"
NODE="$NODE_INPUT"
[[ "$ACTION" =~ ^(stop|start|verify|reset)$ ]] || die 'expected: node stop|start|verify|reset SSH_ALIAS'
host_is_skipped "$NODE" && die "$NODE is excluded by GDC_SKIP_HOSTS"
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
      [[ "$candidate" != "$NODE" && -e "$STATE/joined/$candidate" ]] || continue
      host_is_skipped "$candidate" && continue
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
      [[ "$candidate" != "$NODE" && -e "$STATE/joined/$candidate" ]] || continue
      host_is_skipped "$candidate" || { peer="$candidate"; break; }
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
  step "Reset $NODE deployment state and remove deployed containers"
  ssh -T "$NODE" "NODE='$NODE' bash -s" <<'REMOTE'
set -Eeuo pipefail

compose_down_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  if [[ ! -f "$dir/compose.yaml" ]]; then
    return 0
  fi

  if [[ -f "$dir/.env" ]]; then
    docker compose --env-file "$dir/.env" -f "$dir/compose.yaml" down -v --remove-orphans || true
  else
    docker compose -f "$dir/compose.yaml" down -v --remove-orphans || true
  fi
}

compose_down_dir "/srv/dai/monitoring-agent"
compose_down_dir "/srv/dai/edge"
compose_down_dir "/srv/dai/deploy/$NODE"

rm -rf -- \
  "/srv/dai/deploy/$NODE" \
  "/tmp/gdc-deploy-"*-"$NODE" \
  "/tmp/gdc-reset-"*-"$NODE"
REMOTE
  if [[ -e "$STATE/joined/$NODE" ]]; then
    rm -f "$STATE/joined/$NODE"
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
