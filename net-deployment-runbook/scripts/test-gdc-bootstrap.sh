#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/jq" <<'EOF'
#!/bin/sh
printf 'jq-1.6\n'
EOF
chmod 0755 "$tmp/bin/jq"

cat >"$tmp/bin/bash" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -c ]; then exit 1; fi
printf '%s\n' "$@" >"$GDC_BOOTSTRAP_CAPTURE"
EOF
chmod 0755 "$tmp/bin/bash"

# An old PATH Bash is rejected before the launcher starts when no Homebrew
# fallback is present. macOS CI deliberately installs that fallback, which is
# exercised by the public launcher contracts below instead.
homebrew_bash=''
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [ -x "$candidate" ]; then
    homebrew_bash=$candidate
    break
  fi
done
if [ -z "$homebrew_bash" ]; then
  if PATH="$tmp/bin:/usr/bin:/bin" GDC_BOOTSTRAP_CAPTURE="$tmp/old.capture" \
    "$ROOT/gdc.sh" host join --plan target >"$tmp/old.out" 2>"$tmp/old.err"; then
    echo 'Bash 3-compatible shim unexpectedly passed bootstrap' >&2
    exit 1
  fi
  grep -Fq 'Bash >= 5 is required' "$tmp/old.err"
  [[ ! -e "$tmp/old.capture" ]]
else
  "$homebrew_bash" -c '(( BASH_VERSINFO[0] >= 5 ))'
fi

cat >"$tmp/bin/bash" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -c ]; then exit 0; fi
printf '%s\n' "$@" >"$GDC_BOOTSTRAP_CAPTURE"
EOF
chmod 0755 "$tmp/bin/bash"
PATH="$tmp/bin:/usr/bin:/bin" GDC_BOOTSTRAP_CAPTURE="$tmp/argv.capture" \
  "$ROOT/gdc.sh" host join --plan target
mapfile -t argv <"$tmp/argv.capture"
[[ "${argv[0]}" == "$ROOT/gdc-bash.sh" ]]
[[ "${argv[1]}" == host && "${argv[2]}" == join && "${argv[3]}" == --plan && "${argv[4]}" == target ]]

# Do not assume that a platform lacks a system jq. The bootstrap needs only
# dirname before it rejects the missing executable, so this lookup path is
# hermetic while retaining the standard command required for root resolution.
mkdir -p "$tmp/no-jq"
cat >"$tmp/no-jq/dirname" <<'EOF'
#!/bin/sh
exec /usr/bin/dirname "$@"
EOF
chmod 0755 "$tmp/no-jq/dirname"
if PATH="$tmp/no-jq" "$ROOT/gdc.sh" host join --plan target >"$tmp/jq.out" 2>"$tmp/jq.err"; then
  echo 'missing jq unexpectedly reached Bash bootstrap' >&2
  exit 1
fi
grep -Fq 'jq >= 1.6' "$tmp/jq.err"

mkdir -p "$tmp/jq-1.5"
cat >"$tmp/jq-1.5/jq" <<'EOF'
#!/bin/sh
printf 'jq-1.5\n'
EOF
chmod 0755 "$tmp/jq-1.5/jq"
if PATH="$tmp/jq-1.5:$tmp/no-jq" "$ROOT/gdc.sh" host join --plan target >"$tmp/old-jq.out" 2>"$tmp/old-jq.err"; then
  echo 'jq 1.5 unexpectedly reached Bash bootstrap' >&2
  exit 1
fi
grep -Fq 'jq >= 1.6' "$tmp/old-jq.err"

# The fixed Homebrew candidates are intentional and must survive refactors.
grep -Fqx '  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do' "$ROOT/gdc.sh"
printf 'PASS GDC Bash bootstrap contract\n'
