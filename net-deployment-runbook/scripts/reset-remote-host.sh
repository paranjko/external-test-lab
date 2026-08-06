#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'reset-remote-host.sh must run as root' >&2; exit 1; }

mapfile -t poc_watch_units < <(systemctl list-units --all --plain --no-legend \
  'gdc-poc-winddown-watch@*.service' 2>/dev/null | awk '{print $1}')
for unit in "${poc_watch_units[@]}"; do
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

project_is_resettable() {
  # The node4 Telegram issuer is a secondary service. A chain rehearsal reset
  # must not destroy its finite pre-authorised key pool or the only active
  # long-poll consumer.
  # The public status and observability plane must remain available after a
  # chain reset so it can show the reset/offline state rather than vanish.
  [[ "$1" != gonka-devnet-bot && "$1" != gdc-ops && "$1" != gdc-edge ]]
}

mapfile -t containers < <(docker ps -aq --filter label=com.docker.compose.project)
for container in "${containers[@]}"; do
  project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")"
  project_is_resettable "$project" && docker rm -f "$container" >/dev/null
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
  project_is_resettable "$project" && docker volume rm -f "$volume" >/dev/null
done

mapfile -t networks < <(docker network ls -q --filter label=com.docker.compose.project)
for network in "${networks[@]}"; do
  project="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$network")"
  project_is_resettable "$project" && docker network rm "$network" >/dev/null
done

if [[ -d /srv/dai ]]; then
  # These directories back bind-mounted Docker paths.  Removing either while
  # its mount remains active turns the mount source into "(deleted)" and
  # leaves containerd unable to start.  A chain reset removes only deployment
  # artifacts, never the host container runtime or its image cache.
  find /srv/dai -mindepth 1 -maxdepth 1 \
    ! -name docker ! -name containerd ! -name hf-cache \
    ! -name gonka-devnet-bot ! -name ops ! -name edge ! -name caddy \
    -exec rm -rf -- {} +
fi
rm -rf -- /srv/dai.previous.* /tmp/gdc-*
printf 'Removed Gonka deployment configuration and artifacts from %s\n' "$(hostname)"
