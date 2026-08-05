#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

ACTION="${1:-}"
NODE_INPUT="${2:-}"
[[ "$NODE_INPUT" =~ ^(node[0-4]|gdc-node[0-4])$ ]] || die 'expected node0, node1, node2, node3, or node4'
if [[ "$NODE_INPUT" == gdc-* ]]; then NODE="$NODE_INPUT"; else NODE="gdc-$NODE_INPUT"; fi
[[ "$ACTION" =~ ^(stop|start|verify)$ ]] || die 'expected: node stop|start|verify nodeN'
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
  if [[ "$NODE" == gdc-node0 ]]; then peer=gdc-node1; else peer=gdc-node0; fi
  host_is_skipped "$peer" && die "cannot select a live peer for $NODE"
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
  if [[ "$NODE" == gdc-node0 ]]; then peer=gdc-node1; else peer=gdc-node0; fi
  host_is_skipped "$peer" && die "cannot select a live peer for $NODE"
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
esac
