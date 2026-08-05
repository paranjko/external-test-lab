#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
[[ $# -eq 5 && "$1" =~ ^gdc-node[0-4]$ && -s "$2" && -s "$3" && "$4" == *@sha256:* && "$5" =~ ^[1-9][0-9]*$ ]] \
  || { echo "Usage: sudo $0 NODE COMPOSE START_NODE EXPLORER_IMAGE DASHBOARD_PORT" >&2; exit 2; }

NODE="$1"
COMPOSE="$2"
START_NODE="$3"
EXPLORER_IMAGE="$4"
DASHBOARD_PORT="$5"
DEST="/srv/dai/deploy/$NODE"
ENV="$DEST/.env"
[[ -s "$ENV" ]] || { echo "missing deployed environment: $ENV" >&2; exit 1; }

set_env() {
  local key="$1" value="$2" temporary
  temporary="$(mktemp "$DEST/.env.XXXXXX")"
  awk -F= -v key="$key" -v value="$value" '
    $1 == key { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV" >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$ENV"
}
set_env EXPLORER_IMAGE "$EXPLORER_IMAGE"
set_env DASHBOARD_PORT "$DASHBOARD_PORT"

install -m 0644 "$COMPOSE" "$DEST/compose.yaml"
install -m 0755 "$START_NODE" "$DEST/start-node.sh"
cd "$DEST"
docker compose --env-file .env -f compose.yaml config --quiet
docker compose --env-file .env -f compose.yaml pull explorer
docker compose --env-file .env -f compose.yaml up -d --force-recreate explorer proxy
