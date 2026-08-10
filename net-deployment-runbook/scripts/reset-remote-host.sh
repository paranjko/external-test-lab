#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'reset-remote-host.sh must run as root' >&2; exit 1; }
[[ -n "${GDC_RESET_MANAGED_ALIASES:-}" ]] || { echo 'GDC_RESET_MANAGED_ALIASES is required' >&2; exit 1; }
read -r -a managed_aliases <<<"$GDC_RESET_MANAGED_ALIASES"
(( ${#managed_aliases[@]} > 0 )) || { echo 'GDC_RESET_MANAGED_ALIASES must not be empty' >&2; exit 1; }

managed_project() {
  local project="$1" alias
  for alias in "${managed_aliases[@]}"; do
    [[ "$project" == "$alias" || "$project" == "gdc-qualify-${alias#gdc-}" ]] && return 0
  done
  return 1
}

for alias in "${managed_aliases[@]}"; do
  systemctl disable --now "gdc-poc-winddown-watch@$alias.service" >/dev/null 2>&1 || true
done

mapfile -t containers < <(docker ps -aq --filter label=com.docker.compose.project)
for container in "${containers[@]}"; do
  project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")"
  managed_project "$project" && docker rm -f "$container" >/dev/null
done

# Public observability is preserved, but gateway state is tied to a specific
# chain and its escrow IDs. Never carry it into a freshly reset network.
mapfile -t gateway_containers < <(docker ps -aq \
  --filter label=com.docker.compose.project=gdc-ops \
  --filter label=com.docker.compose.service=devshard-gateway)
(( ${#gateway_containers[@]} == 0 )) || docker rm -f "${gateway_containers[@]}" >/dev/null
mapfile -t gateway_volumes < <(docker volume ls -q --filter label=com.docker.compose.project=gdc-ops | grep -E 'gateway-data' || true)
(( ${#gateway_volumes[@]} == 0 )) || docker volume rm -f "${gateway_volumes[@]}" >/dev/null
rm -f /srv/dai/ops/gateway.env

mapfile -t volumes < <(docker volume ls -q --filter label=com.docker.compose.project)
for volume in "${volumes[@]}"; do
  project="$(docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$volume")"
  managed_project "$project" && docker volume rm -f "$volume" >/dev/null
done

mapfile -t networks < <(docker network ls -q --filter label=com.docker.compose.project)
for network in "${networks[@]}"; do
  project="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$network")"
  managed_project "$project" && docker network rm "$network" >/dev/null
done

# Delete only paths whose names came from the deployment inventory.  Do not
# sweep /srv/dai: it is an operator-managed filesystem and may hold unrelated
# workloads. HF cache, Docker/containerd state, observability, bot and Caddy
# are deliberately retained.
for alias in "${managed_aliases[@]}"; do
  rm -rf -- "/srv/dai/deploy/$alias" "/srv/dai/$alias"
done
rm -f -- /srv/dai/shared/genesis.json /srv/dai/shared/genesis.sha256 /srv/dai/ops/gateway.env
printf 'Removed Gonka deployment configuration and artifacts from %s\n' "$(hostname)"
