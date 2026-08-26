#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/recover-running-host-deployment-secrets.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'KEYRING_PASSWORD=%s\n' "$GDC_TEST_REMOTE_KEYRING"
printf 'POSTGRES_PASSWORD=%s\n' "$GDC_TEST_REMOTE_POSTGRES"
EOF
chmod +x "$tmp/bin/ssh"

keyring='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
postgres='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
export GDC_TEST_REMOTE_KEYRING="$keyring" GDC_TEST_REMOTE_POSTGRES="$postgres"
PATH="$tmp/bin:$PATH" "$CHECK" gdc-node2 "$tmp/secrets" >"$tmp/first.log"
[[ "$(<"$tmp/secrets/gdc-node2.keyring")" == "$keyring" ]]
[[ "$(<"$tmp/secrets/gdc-node2.postgres")" == "$postgres" ]]
[[ "$(stat -c %a "$tmp/secrets/gdc-node2.keyring")" == 600 ]]
[[ "$(stat -c %a "$tmp/secrets/gdc-node2.postgres")" == 600 ]]
! grep -Fq "$keyring" "$tmp/first.log"
! grep -Fq "$postgres" "$tmp/first.log"

PATH="$tmp/bin:$PATH" bash -x "$CHECK" gdc-node2 "$tmp/secrets" \
  >"$tmp/xtrace.out" 2>"$tmp/xtrace.err"
! grep -Fq "$keyring" "$tmp/xtrace.out" "$tmp/xtrace.err"
! grep -Fq "$postgres" "$tmp/xtrace.out" "$tmp/xtrace.err"

PATH="$tmp/bin:$PATH" "$CHECK" gdc-node2 "$tmp/secrets" >"$tmp/repeat.log"

export GDC_TEST_REMOTE_KEYRING='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
if PATH="$tmp/bin:$PATH" "$CHECK" gdc-node2 "$tmp/secrets" \
  >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
  echo 'a changed running Host keyring password must fail recovery' >&2
  exit 1
fi
grep -Fq 'local node keyring password conflicts' "$tmp/conflict.err"
[[ "$(<"$tmp/secrets/gdc-node2.keyring")" == "$keyring" ]]

export GDC_TEST_REMOTE_KEYRING=short
if PATH="$tmp/bin:$PATH" "$CHECK" gdc-node3 "$tmp/malformed" \
  >"$tmp/malformed.out" 2>"$tmp/malformed.err"; then
  echo 'a malformed running Host password must fail recovery' >&2
  exit 1
fi
grep -Fq 'deployment has malformed KEYRING_PASSWORD' "$tmp/malformed.err"
[[ ! -e "$tmp/malformed/gdc-node3.keyring" ]]

printf 'PASS running Host deployment secret recovery\n'
