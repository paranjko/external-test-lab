#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "$1" == -G && "$2" == join-fixture ]]; then printf "hostname 198.51.100.10\\n"; exit 0; fi' \
  'host="${@: -2:1}"' \
  'case "$host" in' \
  '  join-fixture|node3.example.net) printf "debug1: Connecting to %s [198.51.100.10] port 22.\\n" "$host" >&2 ;;' \
  '  other.example.net) printf "debug1: Connecting to %s [198.51.100.11] port 22.\\n" "$host" >&2 ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  'exit 255' >"$tmp/bin/ssh"
chmod 700 "$tmp/bin/ssh"

[[ "$(PATH="$tmp/bin:$PATH" "$ROOT/scripts/detect-public-host.sh" join-fixture node3.example.net)" == node3.example.net ]]
if PATH="$tmp/bin:$PATH" "$ROOT/scripts/detect-public-host.sh" join-fixture other.example.net >/dev/null 2>&1; then
  echo 'explicit public host accepted an unrelated SSH address' >&2
  exit 1
fi
printf 'PASS explicit public-host resolver contract\n'
