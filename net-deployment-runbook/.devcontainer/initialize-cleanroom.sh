#!/usr/bin/env bash
set -Eeuo pipefail

readonly source_root=/opt/runbook-source
readonly workspace_root=/workspace
readonly cleanroom_gdc_home=/workspaces/.data

if [[ ! -f "${source_root}/.env.example" ]]; then
  echo 'FAIL the filtered runbook snapshot is missing' >&2
  exit 1
fi

# Re-seed the filtered image snapshot so every recreated cleanroom starts clean.
sudo install -d -o "$(id -u)" -g "$(id -g)" "${workspace_root}"
sudo rsync -a --delete --chown="$(id -u):$(id -g)" \
  "${source_root}/" "${workspace_root}/"
sudo install -d -o "$(id -u)" -g "$(id -g)" "$cleanroom_gdc_home"
install -d "$HOME/.local/bin"
install -m 0755 "$source_root/.devcontainer/gdc" "$HOME/.local/bin/gdc"

deadline=$((SECONDS + 60))
until docker info >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo 'FAIL the isolated Docker daemon did not become ready within 60 seconds' >&2
    exit 1
  fi
  sleep 1
done

# Docker-in-Docker volumes also survive container replacement. Remove their
# runtime state so a reset cannot inherit containers, images, or data volumes.
mapfile -t inner_containers < <(docker ps --all --quiet)
if (( ${#inner_containers[@]} > 0 )); then
  docker rm --force "${inner_containers[@]}" >/dev/null
fi
docker system prune --all --force --volumes >/dev/null

cd "${workspace_root}"
exec bash .devcontainer/verify-cleanroom.sh
