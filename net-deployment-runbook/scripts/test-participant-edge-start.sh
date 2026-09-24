#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# A participant edge starts Caddy only. The edge Compose file also defines
# gateway-admission, whose script only `gateway apply` installs; a bare `up -d`
# left that container restart-looping on every joined Host.
for phase in phase-join.sh phase-join-resume-canonical.sh; do
  grep -Fq 'start_stack "$NODE" "/srv/dai/deploy/edge" caddy' "$ROOT/scripts/$phase" \
    || { echo "$phase starts every service of the participant edge" >&2; exit 1; }
done
grep -Fq 'gateway-admission:' "$ROOT/04-ops/edge-node/compose.yaml"
if grep -Fq 'gateway-admission-proxy.py' "$ROOT/04-ops/edge-node/install-edge.sh"; then
  echo 'install-edge.sh now installs the admission proxy; revisit the participant edge start' >&2; exit 1
fi

# shellcheck source=/dev/null
source <(sed -n '/^start_stack()/,/^}/p' "$ROOT/scripts/lib.sh")
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
ssh() { printf '%s\n' "$2" >>"$tmp/ssh.log"; }

start_stack host-a /srv/dai/deploy/edge caddy >/dev/null
grep -Fxq "cd '/srv/dai/deploy/edge' && docker compose up -d caddy >start.log 2>&1" "$tmp/ssh.log"
: >"$tmp/ssh.log"
start_stack host-a /srv/dai/deploy/monitoring-agent >/dev/null
grep -Fxq "cd '/srv/dai/deploy/monitoring-agent' && docker compose up -d >start.log 2>&1" "$tmp/ssh.log"
# The names are spliced into a remote shell string.
if (start_stack host-a /srv/dai/deploy/edge 'caddy; reboot') >/dev/null 2>&1; then
  echo 'start_stack accepted an unsafe service name' >&2; exit 1
fi
printf 'PASS a participant edge starts Caddy only; start_stack still starts a whole project by default\n'
