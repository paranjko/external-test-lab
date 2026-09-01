#!/usr/bin/env sh
set -eu

current=/root/.dapi/cosmovisor/current
binary="$current/bin/decentralized-api"
selection=/root/.dapi/.gdc-runtime-binary

if [ -s "$selection" ]; then
  IFS= read -r selected <"$selection"
  case "$selected" in
    cosmovisor/upgrades/*/bin/decentralized-api) ;;
    *)
      printf 'ERROR invalid DAPI runtime selection\n' >&2
      exit 1
      ;;
  esac
  [ -x "/root/.dapi/$selected" ] || {
    printf 'ERROR selected DAPI runtime is unavailable\n' >&2
    exit 1
  }
  exec "/root/.dapi/$selected"
fi

# The upstream image entrypoint always runs `cosmovisor init`. After the first
# protocol upgrade `current` already exists, so restarting the container would
# fail before Cosmovisor can run the selected binary. Initialization is only a
# first-start operation; later starts must preserve and run the existing link.
if [ -L "$current" ] && [ -x "$binary" ]; then
  exec cosmovisor run
fi

exec sh ./init-docker.sh
