#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'reset-remote-host.sh must run as root' >&2; exit 1; }

project_is_resettable() {
  # G-Meter probe history and the node4 Telegram issuer are secondary
  # services. A chain rehearsal reset must not destroy their persistent state,
  # finite pre-authorised key pool, or the only active long-poll consumer.
  # The public status and observability plane must remain available after a
  # chain reset so it can show the reset/offline state rather than vanish.
  [[ "$1" != gmeter && "$1" != gonka-devnet-bot && "$1" != gdc-ops && "$1" != gdc-edge ]]
}

mapfile -t containers < <(docker ps -aq --filter label=com.docker.compose.project)
for container in "${containers[@]}"; do
  project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")"
  project_is_resettable "$project" && docker rm -f "$container" >/dev/null
done

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
    ! -name docker ! -name containerd ! -name hf-cache ! -name gmeter \
    ! -name gonka-devnet-bot ! -name ops ! -name edge ! -name caddy \
    -exec rm -rf -- {} +
fi
rm -rf -- /srv/dai.previous.* /tmp/gdc-*
printf 'Removed Gonka deployment configuration and artifacts from %s\n' "$(hostname)"
