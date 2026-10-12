#!/usr/bin/env bash
# Exercise bounded DAPI worker release readback without a Host or DAPI mock.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/date" <<'SH'
#!/usr/bin/env bash
cat "$GDC_TEST_CLOCK"
SH
cat >"$tmp/bin/sleep" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
clock="$(<"$GDC_TEST_CLOCK")"
printf '%s\n' "$((clock + $1))" >"$GDC_TEST_CLOCK"
SH
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
if [[ "$args" == *'-X DELETE'* ]]; then
  printf 'delete\n' >>"$GDC_TEST_EVENTS"
  [[ "${GDC_TEST_DELETE_RESULT:-timeout}" == success ]] && exit 0
  exit 28
fi
printf 'read\n' >>"$GDC_TEST_EVENTS"
reads="$(wc -l <"$GDC_TEST_EVENTS")"
if (( reads > GDC_TEST_READY_AFTER )); then
  printf '[]\n'
else
  printf '[{"node":{"id":"lent-worker"}}]\n'
fi
SH
chmod 0755 "$tmp/bin/date" "$tmp/bin/sleep" "$tmp/bin/curl"

run_wait() {
  env PATH="$tmp/bin:$PATH" GDC_TEST_CLOCK="$tmp/clock" GDC_TEST_EVENTS="$tmp/events" \
    GDC_TEST_READY_AFTER="$1" GDC_TEST_DELETE_RESULT="$2" \
    bash "$ROOT/scripts/wait-dapi-worker-removal.sh" --node-id lent-worker \
      --timeout-seconds "$3" --poll-seconds 1
}

run_default_wait() {
  env PATH="$tmp/bin:$PATH" GDC_TEST_CLOCK="$tmp/clock" GDC_TEST_EVENTS="$tmp/events" \
    GDC_TEST_READY_AFTER="$1" GDC_TEST_DELETE_RESULT="$2" \
    bash "$ROOT/scripts/wait-dapi-worker-removal.sh" --node-id lent-worker
}

has_exact_line() {
  local file="$1" expected="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$expected" ]] && return 0
  done <"$file"
  return 1
}

count_exact_lines() {
  local file="$1" expected="$2" line count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$expected" ]] && count=$((count + 1))
  done <"$file"
  printf '%s\n' "$count"
}

printf '100\n' >"$tmp/clock"; : >"$tmp/events"
run_wait 2 timeout 5 >"$tmp/drain.out"
[[ "$(head -n1 "$tmp/events")" == delete ]]
[[ "$(count_exact_lines "$tmp/events" read)" == 2 ]]
has_exact_line "$tmp/drain.out" 'WAIT DAPI did not confirm worker removal node_id=lent-worker; waiting for broker readback'
has_exact_line "$tmp/drain.out" 'PASS DAPI confirmed worker removal node_id=lent-worker elapsed=1s'

printf '100\n' >"$tmp/clock"; : >"$tmp/events"
if run_wait 99 timeout 2 >"$tmp/deadline.out" 2>&1; then
  echo 'unconfirmed DAPI worker removal unexpectedly passed' >&2
  exit 1
fi
has_exact_line "$tmp/deadline.out" 'DAPI did not confirm worker removal node_id=lent-worker within 2s (worker is still registered)'
[[ "$(head -n1 "$tmp/events")" == delete ]]

printf '100\n' >"$tmp/clock"; : >"$tmp/events"
run_default_wait 2 timeout >"$tmp/default.out"
has_exact_line "$tmp/default.out" 'WAIT DAPI worker removal node_id=lent-worker elapsed=0s remaining=960s last=worker is still registered'
has_exact_line "$tmp/default.out" 'PASS DAPI confirmed worker removal node_id=lent-worker elapsed=15s'

printf 'PASS DAPI worker removal waits for broker readback and retains a bounded refusal\n'
