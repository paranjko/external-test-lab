#!/usr/bin/env bash
# Stop the signerless canary and prove that no node container still holds its
# candidate generation before an active data pointer can be changed.
set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "Usage: sudo $0 DEPLOY_DIR" >&2; exit 2; }
deploy="$1"
[[ $EUID -eq 0 && -d "$deploy" && -r "$deploy/.env" && -r "$deploy/compose.yaml" ]] || { echo 'invalid canary-stop input' >&2; exit 2; }
docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" stop node
if ! running="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" ps -q node)"; then
  echo 'canary_still_running: cannot read candidate node container state' >&2
  exit 1
fi
[[ -z "$running" ]] || { echo 'canary_still_running: node container remains after controlled stop' >&2; exit 1; }
printf 'PASS signerless state-sync canary is stopped before promotion\n'
