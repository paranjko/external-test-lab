#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/date" <<'MOCK_DATE'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  '+%s %N') printf '%s %s\n' "$GDC_TEST_DATE_SECONDS" "$GDC_TEST_DATE_NANOSECONDS" ;;
  +%s) printf '%s\n' "$GDC_TEST_DATE_SECONDS" ;;
  *) exec /bin/date "$@" ;;
esac
MOCK_DATE
chmod +x "$tmp/date"

# Some date implementations treat the width in %3N as a minimum and emit all
# nine nanosecond digits. The former concatenation then labels nanoseconds as
# milliseconds: this 16 ms interval was published as 16,000,000 ms in the live
# gateway health document.
legacy_started=1700000000123456789
legacy_finished=1700000000139456789
[[ "$((legacy_finished - legacy_started))" == 16000000 ]]

# Production callers must all use the shared conversion instead of recreating
# the non-portable width format that caused the live readiness failure.
while IFS= read -r operational_script; do
  if grep -Fq 'date +%s%3N' "$operational_script"; then
    printf 'non-portable millisecond clock remains in %s\n' "$operational_script" >&2
    exit 1
  fi
done < <(find "$ROOT/04-ops" "$ROOT/scripts" -type f -name '*.sh' \
  ! -name 'test-epoch-millis.sh' -print)

# The shared launcher tree and the independently deployed OPS bundle each need
# a self-contained copy. Keep the implementations identical so minimal
# launcher fixtures do not acquire an OPS-tree dependency.
cmp "$ROOT/scripts/epoch-millis.sh" "$ROOT/04-ops/epoch-millis.sh"

# shellcheck source=epoch-millis.sh
source "$ROOT/scripts/epoch-millis.sh"

export PATH="$tmp:$PATH"
export GDC_TEST_DATE_SECONDS=1700000000
export GDC_TEST_DATE_NANOSECONDS=123456789
started_ms="$(epoch_millis)"
[[ "$started_ms" == 1700000000123 ]]

GDC_TEST_DATE_NANOSECONDS=139456789
finished_ms="$(epoch_millis)"
[[ "$finished_ms" == 1700000000139 ]]
[[ "$((finished_ms - started_ms))" == 16 ]]

# Hosts whose date does not implement %N still get a valid, conservative
# second-resolution millisecond value.
GDC_TEST_DATE_NANOSECONDS='%N'
[[ "$(epoch_millis)" == 1700000000000 ]]

printf 'PASS portable epoch millisecond clock\n'
