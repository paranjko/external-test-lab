#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# A participant edge starts Caddy only. The edge Compose file also defines
# gateway-admission, whose script only `gateway apply` installs; a bare `up -d`
# left that container restart-looping on every joined Host.
grep -Fq 'join_start_verified_auxiliary_services "$NODE" "$PUBLIC_EDGE_NODE"' "$ROOT/scripts/phase-join.sh" \
  || { echo 'normal JOIN bypasses the shared participant service boundary' >&2; exit 1; }
grep -Fq 'join_start_verified_auxiliary_services "$NODE" "$PUBLIC_EDGE_NODE"' "$ROOT/scripts/lib-join-resume.sh" \
  || { echo 'resumed JOIN bypasses the shared participant service boundary' >&2; exit 1; }
grep -Fq 'gateway-admission:' "$ROOT/04-ops/edge-node/compose.yaml"
if grep -Fq 'gateway-admission-proxy.py' "$ROOT/04-ops/edge-node/install-edge.sh"; then
  echo 'install-edge.sh now installs the admission proxy; revisit the participant edge start' >&2; exit 1
fi

# shellcheck source=/dev/null
source <(sed -n '/^start_stack()/,/^}/p' "$ROOT/scripts/lib.sh")
# shellcheck source=lib-post-sync-join.sh
source "$ROOT/scripts/lib-post-sync-join.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
ssh() {
  [[ $# == 2 && "$1" == host-a ]] || die 'unexpected SSH target or arguments'
  case "$2" in
    "cd '/srv/dai/deploy/edge' && docker compose up -d caddy >start.log 2>&1"|\
    "cd '/srv/dai/deploy/monitoring-agent' && docker compose up -d >start.log 2>&1") ;;
    *) die "unexpected SSH command: $2" ;;
  esac
  printf '%s\n' "$2" >>"$tmp/ssh.log"
}

start_stack host-a /srv/dai/deploy/edge caddy >/dev/null
grep -Fxq "cd '/srv/dai/deploy/edge' && docker compose up -d caddy >start.log 2>&1" "$tmp/ssh.log"
: >"$tmp/ssh.log"
start_stack host-a /srv/dai/deploy/monitoring-agent >/dev/null
grep -Fxq "cd '/srv/dai/deploy/monitoring-agent' && docker compose up -d >start.log 2>&1" "$tmp/ssh.log"

: >"$tmp/ssh.log"
join_start_verified_auxiliary_services host-a public-edge >/dev/null
[[ "$(wc -l <"$tmp/ssh.log")" == 2 ]]
grep -Fxq "cd '/srv/dai/deploy/edge' && docker compose up -d caddy >start.log 2>&1" "$tmp/ssh.log"
grep -Fxq "cd '/srv/dai/deploy/monitoring-agent' && docker compose up -d >start.log 2>&1" "$tmp/ssh.log"
: >"$tmp/ssh.log"
join_start_verified_auxiliary_services host-a host-a >/dev/null
[[ "$(wc -l <"$tmp/ssh.log")" == 1 ]]
grep -Fxq "cd '/srv/dai/deploy/monitoring-agent' && docker compose up -d >start.log 2>&1" "$tmp/ssh.log"
# The names are spliced into a remote shell string.
if (start_stack host-a /srv/dai/deploy/edge 'caddy; reboot') >/dev/null 2>&1; then
  echo 'start_stack accepted an unsafe service name' >&2; exit 1
fi
printf 'PASS a participant edge starts Caddy only; start_stack still starts a whole project by default\n'
