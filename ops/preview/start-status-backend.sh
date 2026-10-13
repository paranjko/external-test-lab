#!/usr/bin/env bash
set -Eeuo pipefail

collector="${GDC_NETWORK_OBSERVER_COLLECTOR:-/usr/local/lib/gonka-devnet/network-observer.sh}"
environment=/etc/gonka/gdc-network-observer.env
state_dir=/tmp/gonka-network-observer

[[ -r "$environment" && -x "$collector" ]] || {
  echo 'source-bound network observer files are unavailable' >&2
  exit 1
}
install -d -m 0755 "$state_dir"

/usr/bin/python3 /opt/gdc-preview/network-observer-runtime.py &
observer_pid=$!
(
  set -a
  # This file is rendered from the validated public preview inventory.
  # shellcheck source=/dev/null
  . "$environment"
  set +a
  while true; do
    started="$(date +%s)"
    /bin/bash "$collector" --refresh-requested || true
    elapsed=$(( $(date +%s) - started ))
    (( elapsed >= 60 )) || sleep "$((60 - elapsed))"
  done
) &
refresh_pid=$!
/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!

cleanup() {
  kill "$observer_pid" "$refresh_pid" "$caddy_pid" 2>/dev/null || true
  wait "$observer_pid" "$refresh_pid" "$caddy_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
set +e
wait -n "$observer_pid" "$refresh_pid" "$caddy_pid"
status=$?
set -e
exit "$status"
