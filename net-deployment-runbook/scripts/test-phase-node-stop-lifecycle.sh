#!/usr/bin/env bash
# Exercise the installed stop path, including its first required SSH action.
# A standalone readiness probe is forbidden: it would be a second connection
# before the same remote operation without adding a safety boundary.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

kit="$tmp/kit"
mkdir -p "$kit/scripts" "$tmp/bin"
cp "$ROOT/scripts/phase-node.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${GDC_TEST_KIT:?}"
load_project() { :; }
topology_contains_node() { [[ "$1" == parent ]]; }
ssh_ready() {
  printf 'unexpected standalone readiness probe for %s\n' "$1" >&2
  exit 93
}
step() { printf '%s\n' "$*" >>"${GDC_TEST_EVENTS:?}"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
SH
chmod 0755 "$kit/scripts/lib.sh"

cat >"$kit/scripts/node-container-control.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 2 && "$1" == stop && "$2" == parent ]]
printf 'controller-stop:%s\n' "$2" >>"${GDC_TEST_EVENTS:?}"
SH
chmod 0755 "$kit/scripts/node-container-control.sh"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'unexpected direct SSH action: %s\n' "$*" >&2
exit 94
SH
chmod 0755 "$tmp/bin/ssh"

events="$tmp/events"
ssh_log="$tmp/ssh.log"
: >"$events"
: >"$ssh_log"

env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_EVENTS="$events" \
  GDC_TEST_SSH_LOG="$ssh_log" bash "$kit/scripts/phase-node.sh" stop parent >"$tmp/output" 2>&1

[[ "$(<"$events")" == $'Stop Network Node services on parent without deleting state\ncontroller-stop:parent' ]]
[[ ! -s "$ssh_log" ]]
[[ "$(<"$tmp/output")" == *'PASS parent stopped; persistent data was retained'* ]]

printf 'PASS ordinary node stop uses its lifecycle action as the sole SSH readiness check\n'
