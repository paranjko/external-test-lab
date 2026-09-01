#!/usr/bin/env sh
set -eu

dapi_home="${1:-/root/.dapi}"
case "$dapi_home" in
  /*) ;;
  *)
    printf 'ERROR DAPI home must be an absolute path\n' >&2
    exit 2
    ;;
esac

current="$dapi_home/cosmovisor/current"
binary="$current/bin/decentralized-api"
cosmovisor_home="$dapi_home/cosmovisor"

# The upstream image entrypoint always runs `cosmovisor init`. After the first
# protocol upgrade `current` already exists, so restarting the container would
# fail before Cosmovisor can run the selected binary. Initialization is only a
# first-start operation; later starts must preserve and run the existing link.
if [ -L "$cosmovisor_home" ] \
  || { [ -e "$cosmovisor_home" ] && [ ! -d "$cosmovisor_home" ]; }; then
  printf 'ERROR initialized DAPI home has no runnable Cosmovisor current binary\n' >&2
  exit 1
fi

if [ -L "$current" ] && [ -f "$binary" ] && [ -x "$binary" ]; then
  exec cosmovisor run
fi

if [ -e "$current" ] || [ -L "$current" ]; then
  printf 'ERROR initialized DAPI home has no runnable Cosmovisor current binary\n' >&2
  exit 1
fi

if [ -d "$cosmovisor_home" ] \
  && [ -n "$(find "$cosmovisor_home" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  printf 'ERROR initialized DAPI home has no runnable Cosmovisor current binary\n' >&2
  exit 1
fi

exec sh ./init-docker.sh
