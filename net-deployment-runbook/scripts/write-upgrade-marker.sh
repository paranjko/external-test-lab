#!/usr/bin/env bash
set -Eeuo pipefail

node="${1:-}"
profile="${2:-}"
profile_hash="${3:-}"
scope="${4:-}"
[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'invalid Host alias' >&2; exit 2; }
[[ "$profile" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-rc\.[0-9]+)?$ ]] \
  || { echo 'invalid release profile' >&2; exit 2; }
[[ "$profile_hash" =~ ^[0-9a-f]{64}$ ]] || { echo 'invalid release profile hash' >&2; exit 2; }

case "$scope" in
  full) marker='.gdc-release' ;;
  cosmovisor) marker='.gdc-binary-upgrade' ;;
  *) echo 'marker scope must be full or cosmovisor' >&2; exit 2 ;;
esac

printf '%s %s\n' "$profile" "$profile_hash" \
  | ssh "$node" "sudo tee /srv/dai/deploy/$node/$marker >/dev/null && sudo chmod 600 /srv/dai/deploy/$node/$marker"
printf 'READY %s marker recorded for %s\n' "$scope" "$node"
