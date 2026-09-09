#!/usr/bin/env bash
set -Eeuo pipefail
TEST_REAL_PYTHON3="$(command -v python3)"
export TEST_REAL_PYTHON3
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$1" == -G && "$2" == join-fixture ]] || exit 2' \
  'printf "hostname 198.51.100.10\\n"' >"$tmp/bin/ssh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$1" == */resolve-ipv4.py ]] || exec "$TEST_REAL_PYTHON3" "$@"' \
  'case "$2" in' \
  '  198.51.100.10|node3.example.net) printf "198.51.100.10\\n" "$2" ;;' \
  '  other.example.net) printf "198.51.100.11\\n" "$2" ;;' \
  '  *) exit 2 ;;' \
  'esac' >"$tmp/bin/python3"
chmod 700 "$tmp/bin/ssh" "$tmp/bin/python3"

[[ "$(PATH="$tmp/bin:$PATH" "$ROOT/scripts/detect-public-host.sh" join-fixture node3.example.net)" == node3.example.net ]]
if PATH="$tmp/bin:$PATH" "$ROOT/scripts/detect-public-host.sh" join-fixture other.example.net >/dev/null 2>&1; then
  echo 'explicit public host accepted an unrelated SSH address' >&2
  exit 1
fi
printf 'PASS explicit public-host resolver contract\n'
