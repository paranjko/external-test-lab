#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
. "$ROOT/scripts/portable.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/with space – ü"
printf 'fixture\n' >"$tmp/with space – ü/file name"
ln -s "with space – ü/file name" "$tmp/file link"
expected_file=$(CDPATH='' cd -P "$tmp/with space – ü" && pwd -P)/file\ name
[ "$(gdc_realpath_existing "$tmp/file link")" = "$expected_file" ]
! gdc_realpath_existing "$tmp/missing" >/dev/null 2>&1

printf 'fixture\n' >"$tmp/checksum"
portable_digest=$(gdc_sha256 "$tmp/checksum")
case "$portable_digest" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) echo 'portable SHA-256 backend returned an invalid digest' >&2; exit 1 ;;
esac

mkdir -p "$tmp/hash-fail"
cat >"$tmp/hash-fail/sha256sum" <<'EOF'
#!/bin/sh
exit 17
EOF
chmod 0755 "$tmp/hash-fail/sha256sum"
if (PATH="$tmp/hash-fail:$PATH"; gdc_sha256 "$tmp/checksum") >"$tmp/hash-fail.out" 2>"$tmp/hash-fail.err"; then
  echo 'failed SHA-256 backend unexpectedly produced a digest' >&2
  exit 1
fi

# shellcheck disable=SC2123 # The test intentionally removes command lookup.
if (PATH="$tmp/no-jq"; gdc_require_jq) >"$tmp/no-jq.out" 2>"$tmp/no-jq.err"; then
  echo 'missing jq unexpectedly passed the portable preflight' >&2
  exit 1
fi
grep -Fq 'dependency_missing: jq >= 1.6' "$tmp/no-jq.err"
mkdir -p "$tmp/jq-1.5"
cat >"$tmp/jq-1.5/jq" <<'EOF'
#!/bin/sh
printf 'jq-1.5\n'
EOF
chmod 0755 "$tmp/jq-1.5/jq"
if (PATH="$tmp/jq-1.5:$PATH"; gdc_require_jq) >"$tmp/old-jq.out" 2>"$tmp/old-jq.err"; then
  echo 'jq 1.5 unexpectedly passed the portable preflight' >&2
  exit 1
fi
grep -Fq 'dependency_missing: jq >= 1.6' "$tmp/old-jq.err"

future_utc=$(gdc_utc_after_seconds 1)
printf '%s\n' "$future_utc" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
printf 'Z2RjCg==\n' >"$tmp/base64"
[ "$(gdc_base64_decode "$tmp/base64")" = gdc ]
[ "$(gdc_file_size "$tmp/base64")" = 9 ]

# A resolver may print a valid address while ping exits non-zero because ICMP
# is filtered. The address must survive Bash pipefail in that case.
mkdir -p "$tmp/ping-bin"
cat >"$tmp/ping-bin/ping" <<'EOF'
#!/bin/sh
printf 'PING example.test (192.0.2.10): 56 data bytes\n'
exit 2
EOF
chmod 0755 "$tmp/ping-bin/ping"
[ "$(PATH="$tmp/ping-bin:$PATH" bash -o pipefail -c '. "$1"; gdc_resolve_ipv4 example.test' sh "$ROOT/scripts/portable.sh")" = 192.0.2.10 ]
for invalid_ipv4 in 192.0.2 192.0.2.300 192.0..1 192.0.2.1.9; do
  if gdc_resolve_ipv4 "$invalid_ipv4" >"$tmp/invalid-ipv4.out" 2>/dev/null; then
    echo "malformed IPv4 literal unexpectedly accepted: $invalid_ipv4" >&2
    exit 1
  fi
done
[ "$(gdc_resolve_ipv4 192.0.2.10)" = 192.0.2.10 ]

for public_ipv4 in 1.1.1.1 8.8.8.8 203.1.1.1; do
  gdc_is_public_ipv4 "$public_ipv4"
done
for rejected_public_ipv4 in \
  '1.1.1' '1.1.1.1.1' '01.1.1.1' '1.01.1.1' '1.1.1.01' \
  '1.1.1.256' '1.1.1.-1' '1.1.1.1@evil' '1.1.1.1%eth0' \
  '[1.1.1.1]' '1.1.1.1:8000' '2001:db8::1' ' 1.1.1.1' '1.1.1.1 '; do
  if gdc_is_public_ipv4 "$rejected_public_ipv4"; then
    echo "non-canonical or non-public IPv4 unexpectedly accepted: $rejected_public_ipv4" >&2
    exit 1
  fi
done
for reserved_ipv4 in 0.0.0.1 10.1.2.3 100.64.0.1 127.0.0.1 169.254.1.1 172.16.0.1 192.0.2.1 192.168.1.1 198.18.0.1 198.51.100.1 203.0.113.1 224.0.0.1; do
  if gdc_is_public_ipv4 "$reserved_ipv4"; then
    echo "reserved/private IPv4 unexpectedly accepted: $reserved_ipv4" >&2
    exit 1
  fi
done

mkdir -p "$tmp/private state – ü"
temporary_dir=$(gdc_mktemp_dir "$tmp/private state – ü/operator")
temporary_file=$(gdc_mktemp_file "$tmp/private state – ü/receipt")
[ -d "$temporary_dir" ]
[ -f "$temporary_file" ]
case "$temporary_dir:$temporary_file" in
  "$tmp/private state – ü"/*:"$tmp/private state – ü"/*) ;;
  *) echo 'portable temporary objects escaped the selected private state directory' >&2; exit 1 ;;
esac
rm -rf "$temporary_dir" "$temporary_file"

gdc_lock_acquire "$tmp/state" invocation-1 'host join --plan'
owner=$(gdc_lock_inspect "$tmp/state")
printf '%s\n' "$owner" | grep -Fq 'invocation=invocation-1'
if (gdc_lock_acquire "$tmp/state" invocation-2 report) >"$tmp/contended.out" 2>"$tmp/contended.err"; then
  echo 'second lock acquisition unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'lock_contended:' "$tmp/contended.err"
gdc_lock_release
[ ! -e "$tmp/state/.lifecycle.lock" ]

# Legacy regular-file locks require an explicitly quiescent migration. Never
# probe and unlink: an old descriptor could acquire the inode after the probe.
mkdir -p "$tmp/legacy-inactive"
: >"$tmp/legacy-inactive/.lifecycle.lock"
if (gdc_lock_acquire "$tmp/legacy-inactive" invocation-legacy migrate) >"$tmp/legacy-inactive.out" 2>"$tmp/legacy-inactive.err"; then
  echo 'legacy lock unexpectedly migrated without quiescence proof' >&2
  exit 1
fi
grep -Fq 'requires quiescent migration' "$tmp/legacy-inactive.err"
[ -f "$tmp/legacy-inactive/.lifecycle.lock" ]
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$tmp/legacy-live"
  legacy_live="$tmp/legacy-live/.lifecycle.lock"
  : >"$legacy_live"
  exec 9>"$legacy_live"
  flock -n 9
  if (gdc_lock_acquire "$tmp/legacy-live" invocation-legacy-live migrate) >"$tmp/legacy-live.out" 2>"$tmp/legacy-live.err"; then
    echo 'live legacy flock unexpectedly migrated' >&2
    exit 1
  fi
  grep -Fq 'requires quiescent migration' "$tmp/legacy-live.err"
  exec 9>&-
fi

# A process may remove only the directory for which it still owns the token.
gdc_lock_acquire "$tmp/owner-bound" invocation-3 backup
original_token=$GDC_LOCK_TOKEN
GDC_LOCK_TOKEN=not-the-owner
gdc_lock_release
[ -d "$tmp/owner-bound/.lifecycle.lock" ]
GDC_LOCK_TOKEN=$original_token
gdc_lock_release
[ ! -e "$tmp/owner-bound/.lifecycle.lock" ]

# A stale lock is evidence, not disposable state. A later invocation reports
# contention and leaves the exact directory in place for owner inspection.
mkdir -p "$tmp/stale/.lifecycle.lock"
printf 'token=interrupted-owner\n' >"$tmp/stale/.lifecycle.lock/owner"
if (gdc_lock_acquire "$tmp/stale" invocation-4 report) >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  echo 'stale lock unexpectedly passed acquisition' >&2
  exit 1
fi
grep -Fq 'lock_contended:' "$tmp/stale.err"
[ -d "$tmp/stale/.lifecycle.lock" ]
grep -Fq 'token=interrupted-owner' "$tmp/stale/.lifecycle.lock/owner"

# A present lock without a readable owner record is still contention evidence;
# host lock inspection must not report it as absent and permit a replacement.
mkdir -p "$tmp/unreadable/.lifecycle.lock"
if gdc_lock_inspect "$tmp/unreadable" >"$tmp/unreadable.out" 2>"$tmp/unreadable.err"; then
  echo 'lock with missing owner record unexpectedly passed inspection' >&2
  exit 1
fi
grep -Fq 'lock_io_error:' "$tmp/unreadable.err"
! grep -Fq 'owner=none' "$tmp/unreadable.out"

mkdir -p "$tmp/receipts"
: >"$tmp/receipts/0001-bootstrap_verified.json"
: >"$tmp/receipts/0002-network_observed.json"
[ "$(gdc_count_join_receipts "$tmp/receipts")" = 2 ]
[ "$(gdc_latest_join_receipt_name "$tmp/receipts")" = 0002-network_observed.json ]
: >"$tmp/receipts/0003-unsafe name.json"
if gdc_latest_join_receipt_name "$tmp/receipts" >/dev/null 2>&1; then
  echo 'unsafe JOIN receipt filename unexpectedly entered deterministic ordering' >&2
  exit 1
fi

mkdir -p "$tmp/bounded/one/two"
: >"$tmp/bounded/diagnostic-envelope.v1.json"
: >"$tmp/bounded/one/diagnostic-envelope.v1.json"
: >"$tmp/bounded/one/two/diagnostic-envelope.v1.json"
bounded_paths="$(gdc_find_regular_beneath_depth2 "$tmp/bounded" diagnostic-envelope.v1.json)"
bounded_root="$(gdc_realpath_existing "$tmp/bounded")"
printf '%s\n' "$bounded_paths" | grep -Fqx "$bounded_root/diagnostic-envelope.v1.json"
printf '%s\n' "$bounded_paths" | grep -Fqx "$bounded_root/one/diagnostic-envelope.v1.json"
printf '%s\n' "$bounded_paths" | grep -Fqx "$bounded_root/one/two/diagnostic-envelope.v1.json"
mkdir -p "$tmp/outside"
: >"$tmp/outside/diagnostic-envelope.v1.json"
ln -s "$tmp/outside" "$tmp/bounded/linked"
! printf '%s\n' "$bounded_paths" | grep -Fq "$tmp/bounded/linked/"

# A caller-owned signal trap releases its own completed setup, without ever
# granting it authority to remove a lock created by another process.
PORTABLE="$ROOT/scripts/portable.sh" LOCK_STATE="$tmp/trapped" sh -c '
  . "$PORTABLE"
  trap "gdc_lock_release; exit 0" TERM
  gdc_lock_acquire "$LOCK_STATE" invocation-5 plan
  kill -TERM $$
'
[ ! -e "$tmp/trapped/.lifecycle.lock" ]

printf 'PASS portable local operator primitives\n'
