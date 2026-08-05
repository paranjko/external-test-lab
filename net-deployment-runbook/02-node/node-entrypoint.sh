#!/usr/bin/env sh
set -eu

STATE_DIR=${STATE_DIR:-/root/.inference}
INIT_FLAG="$STATE_DIR/.node_initialized"

if [ "${INIT_ONLY:-false}" = true ]; then
  exec sh ./init-docker.sh
fi

# inferenced 0.2.15 rejects an empty seed list even for the sole Genesis node.
# Identity bootstrap has already initialized config.toml, so complete only the
# Genesis-file step and let the upstream entrypoint perform normal configuration.
if [ "${IS_GENESIS:-false}" = true ] && [ ! -f "$INIT_FLAG" ]; then
  [ -s "$STATE_DIR/config/config.toml" ] || {
    echo 'Genesis identity bootstrap is missing config.toml' >&2
    exit 1
  }
  cp /root/genesis.json "$STATE_DIR/config/genesis.json"
  chmod a-wx "$STATE_DIR/config/genesis.json"
  touch "$INIT_FLAG"
fi

exec sh ./init-docker.sh
