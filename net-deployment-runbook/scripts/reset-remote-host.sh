#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'reset-remote-host.sh must run as root' >&2; exit 1; }
[[ -n "${GDC_RESET_MANAGED_ALIASES:-}" ]] || { echo 'GDC_RESET_MANAGED_ALIASES is required' >&2; exit 1; }
read -r -a managed_aliases <<<"$GDC_RESET_MANAGED_ALIASES"
(( ${#managed_aliases[@]} > 0 )) || { echo 'GDC_RESET_MANAGED_ALIASES must not be empty' >&2; exit 1; }
preserve_public_edge="${GDC_RESET_PRESERVE_PUBLIC_EDGE:-false}"
[[ "$preserve_public_edge" =~ ^(true|false)$ ]] || { echo 'GDC_RESET_PRESERVE_PUBLIC_EDGE must be true or false' >&2; exit 1; }

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

# Keep the public TLS listener and static status site alive on the configured
# public edge Host. Reset republishes its state immediately afterwards; this
# prevents chain cleanup from becoming a public-site outage.
for project in gdc-edge gdc-ops; do
  [[ "$project" == gdc-edge && "$preserve_public_edge" == true ]] && continue
  mapfile -t project_containers < <(docker ps -aq --filter "label=com.docker.compose.project=$project")
  (( ${#project_containers[@]} == 0 )) || docker rm -f "${project_containers[@]}" >/dev/null
  mapfile -t project_volumes < <(docker volume ls -q --filter "label=com.docker.compose.project=$project")
  (( ${#project_volumes[@]} == 0 )) || docker volume rm -f "${project_volumes[@]}" >/dev/null
  mapfile -t project_networks < <(docker network ls -q --filter "label=com.docker.compose.project=$project")
  (( ${#project_networks[@]} == 0 )) || docker network rm "${project_networks[@]}" >/dev/null
done

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
# workloads. HF cache, Docker/containerd state and bot data are retained.
for alias in "${managed_aliases[@]}"; do
  rm -rf -- "/srv/dai/deploy/$alias" "/srv/dai/$alias"
done
[[ "$preserve_public_edge" == true ]] || rm -rf -- /srv/dai/edge
rm -rf -- /srv/dai/ops
rm -f -- /srv/dai/shared/genesis.json /srv/dai/shared/genesis.sha256
printf 'Removed Gonka deployment configuration and artifacts from %s\n' "$(hostname)"
