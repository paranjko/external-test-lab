#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile explorer

REMOTE="/tmp/gdc-explorer-$$"
# Keep the unavailable bootstrap host last: a node0 access outage must not
# prevent the independently reachable nodes from receiving the dashboard.
for node in gdc-node1 gdc-node2 gdc-node4 gdc-node0; do
  if host_is_skipped "$node"; then
    printf 'SKIP  explorer %s is excluded by GDC_SKIP_HOSTS\n' "$node"
    continue
  fi
  if [[ ! -e "$STATE/joined/$node" ]]; then
    printf 'SKIP  explorer %s is not joined to the current chain\n' "$node"
    continue
  fi
  step "Install pinned explorer dashboard on $node"
  ssh "$node" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a "$ROOT/02-node/compose.yaml" "$ROOT/02-node/start-node.sh" "$ROOT/02-node/install-explorer.sh" "$node:$REMOTE/"
  ssh -T "$node" "sudo '$REMOTE/install-explorer.sh' '$node' '$REMOTE/compose.yaml' '$REMOTE/start-node.sh' '$EXPLORER_IMAGE' '$DASHBOARD_PORT'; rm -rf '$REMOTE'"

  edge_env="$GENERATED/edge/$node.env"
  mkdir -p "$(dirname "$edge_env")"
  "$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$node" --output "$edge_env" >/dev/null
  ssh "$node" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a "$ROOT/04-ops/edge-node/" "$node:$REMOTE/edge/"
  scp -q "$edge_env" "$node:$REMOTE/edge.env"
  if [[ "$node" == gdc-node4 ]]; then
    caddy_start='docker compose up -d --force-recreate caddy'
  else
    # `public-grafana` is not started outside node4, but Compose still
    # interpolates its required hostname while it renders the caddy service.
    caddy_start='GRAFANA_HOST=unused.invalid docker compose up -d --force-recreate caddy'
  fi
  ssh -T "$node" "sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; rm -rf '$REMOTE'; cd /srv/dai/edge && $caddy_start"

  host="$(node_url "$node")"
  deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if curl -fsS "$host/dashboard/gonka/gov" | grep -qv 'Dashboard Not Configured'; then
      printf 'PASS explorer dashboard %s/dashboard/gonka/gov\n' "$host"
      break
    fi
    sleep 3
  done
  curl -fsS "$host/dashboard/gonka/gov" | grep -qv 'Dashboard Not Configured' \
    || die "explorer dashboard remains unavailable on $node"
  [[ "$(curl -ksS -o /dev/null -w '%{http_code}' "$host/")" == 308 ]] \
    || die "node root does not redirect to the explorer dashboard on $node"
done
