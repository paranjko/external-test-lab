#!/usr/bin/env sh
set -eu

STATE_DIR=${STATE_DIR:-/root/.inference}
INIT_FLAG="$STATE_DIR/.node_initialized"

# The active data directory is a replaceable state-sync generation.  Never
# let its initialisation choose a new P2P key when the Host identity mounted
# by Compose is already authoritative.
if [ -s /gdc-identity/p2p/node_key.json ]; then
  install -d -m 0700 "$STATE_DIR/config"
  install -m 0600 /gdc-identity/p2p/node_key.json "$STATE_DIR/config/node_key.json"
fi

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
