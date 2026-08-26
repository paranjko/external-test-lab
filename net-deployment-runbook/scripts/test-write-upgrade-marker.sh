#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d /tmp/gdc-test-upgrade-marker.XXXXXX)"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

cat >"$temporary/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$TEST_MARKER_COMMANDS"
cat >>"$TEST_MARKER_INPUT"
EOF
chmod +x "$temporary/ssh"

profile_hash="$(printf candidate | sha256sum | awk '{print $1}')"
TEST_MARKER_COMMANDS="$temporary/commands" TEST_MARKER_INPUT="$temporary/input" \
PATH="$temporary:$PATH" \
  "$ROOT/scripts/write-upgrade-marker.sh" node1 v2026.08.25-rc.0 "$profile_hash" cosmovisor >/dev/null
grep -Fq '/srv/dai/deploy/node1/.gdc-binary-upgrade' "$temporary/commands"
! grep -Fq '/srv/dai/deploy/node1/.gdc-release' "$temporary/commands"

: >"$temporary/commands"
: >"$temporary/input"
TEST_MARKER_COMMANDS="$temporary/commands" TEST_MARKER_INPUT="$temporary/input" \
PATH="$temporary:$PATH" \
  "$ROOT/scripts/write-upgrade-marker.sh" node1 v2026.08.06 "$profile_hash" full >/dev/null
grep -Fq '/srv/dai/deploy/node1/.gdc-release' "$temporary/commands"
! grep -Fq '/srv/dai/deploy/node1/.gdc-binary-upgrade' "$temporary/commands"
grep -Fxq "v2026.08.06 $profile_hash" "$temporary/input"

printf 'PASS candidate Cosmovisor upgrades cannot claim the full release marker\n'
