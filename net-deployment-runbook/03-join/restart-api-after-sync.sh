#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 1 ]] || { echo "Usage: $0 SSH_ALIAS" >&2; exit 2; }
NODE="$1"
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid SSH alias' >&2; exit 2; }

# DAPI owns the phase tracker while a colocated MLNode owns its local PoC
# artifact stage. Either service may have started while its local CometBFT
# node was catching up. Reopen both only after the node has proved caught up,
# so the first lifecycle PoC uses one current chain stage rather than retaining
# a stale artifact stage from pre-sync startup. A network-only Host has no
# local MLNode, so it restarts DAPI alone.
ssh -T "$NODE" "NODE='$NODE' bash -s" <<'REMOTE'
set -Eeuo pipefail
cd "/srv/dai/deploy/$NODE"
compose_files=(-f compose.yaml)
services=(api)
if [[ "$(cat .local-ml 2>/dev/null || printf false)" == true ]]; then
  compose_files+=(-f compose.ml-local.yaml)
  services+=(mlnode)
fi
compose=(sudo docker compose "${compose_files[@]}")
"${compose[@]}" restart "${services[@]}"

deadline=$((SECONDS + ${GDC_API_RESTART_WAIT_SECONDS:-90}))
while (( SECONDS < deadline )); do
  service_states="$("${compose[@]}" ps "${services[@]}" --format '{{.Service}} {{.State}}' 2>/dev/null || true)"
  node_status="$(curl -fsS --connect-timeout 3 --max-time 5 http://127.0.0.1:26657/status 2>/dev/null || true)"
  catching_up="$(jq -r '.result.sync_info.catching_up | tostring' <<<"$node_status" 2>/dev/null || true)"
  services_ready=true
  for service in "${services[@]}"; do
    grep -Fxq "$service running" <<<"$service_states" || services_ready=false
  done
  if [[ "$services_ready" == true && "$catching_up" == false ]]; then
    printf 'READY post-sync services restarted: %s\n' "${services[*]}"
    exit 0
  fi
  sleep 2
done

printf 'FAILED post-sync services did not become ready without losing node synchronization\n' >&2
exit 1
REMOTE
