#!/usr/bin/env bash
# Exercise the clock boundary of the pre-canary trust check without changing
# the process clock or sleeping. The production script only receives `date`
# through PATH, so this fixture supplies a closed deterministic clock.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  '-u +%s') printf '%s\n' "${GDC_TEST_NOW_EPOCH:?}" ;;
  '-u -d 1970-01-01T00:01:40Z +%s') printf '100\n' ;;
  '-u -d 1970-01-01T00:01:41Z +%s') printf '101\n' ;;
  *) exit 64 ;;
esac
EOF
chmod 0755 "$tmp/bin/date"

receipt="$tmp/lineage-receipt.json"
write_receipt() {
  jq -cn --arg expires_at "$1" \
    '{bootstrap:{trust:{expires_at:$expires_at}}}' >"$receipt"
}

run_check() {
  GDC_TEST_NOW_EPOCH=100 PATH="$tmp/bin:$PATH" \
    "$ROOT/scripts/verify-lineage-trust-fresh.sh" "$receipt"
}

# The contract is strict: a timestamp equal to the current second is expired.
write_receipt '1970-01-01T00:01:40Z'
if run_check >/dev/null 2>&1; then
  echo 'lineage trust at its expiry boundary unexpectedly passed' >&2
  exit 1
fi

write_receipt '1970-01-01T00:01:41Z'
run_check >/dev/null

write_receipt 'not-a-timestamp'
if run_check >/dev/null 2>&1; then
  echo 'invalid lineage trust timestamp unexpectedly passed' >&2
  exit 1
fi

printf 'PASS pre-canary lineage trust rejects expiry-boundary and invalid timestamps while accepting a future second\n'
