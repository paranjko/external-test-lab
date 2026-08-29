#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
probe_loop="$ROOT/scripts/telegram-consumer-probe-loop.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/date" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
value="$(cat "$FIXTURE/clock")"
printf '%s\n' "$value"
printf '%s\n' "$((value + 1))" > "$FIXTURE/clock"
MOCK

cat > "$tmp/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '{"status":"ok","inference_ready":true,"last_success_age_seconds":0}'
MOCK

cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
shift
if [[ "$(cat "$FIXTURE/scenario")" == timeout ]]; then
  count="$(cat "$FIXTURE/timeout-count")"
  printf '%s\n' "$((count + 1))" > "$FIXTURE/timeout-count"
  exit 124
fi
exec "$@"
MOCK

cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  ps)
    printf '%s\n' bot-id
    ;;
  inspect)
    printf 'MODEL=%s\n' "$TEST_MODEL"
    ;;
  exec)
    count="$(cat "$FIXTURE/docker-count")"
    printf '%s\n' "$((count + 1))" > "$FIXTURE/docker-count"
    case "$(cat "$FIXTURE/scenario")" in
      pre-dispatch-success)
        if (( count == 0 )); then
          printf '%s\n' '{"status":"failed","reason":"gateway_pre_dispatch_rejected"}'
          exit 1
        fi
        ;;
      persistent-pre-dispatch)
        printf '%s\n' '{"status":"failed","reason":"gateway_pre_dispatch_rejected"}'
        exit 1
        ;;
      generic-503)
        printf '%s\n' '{"status":"failed","reason":"gateway_returned_HTTP_503"}'
        exit 1
        ;;
      dispatched-503)
        printf '%s\n' '{"status":"failed","reason":"gateway_returned_HTTP_503"}'
        exit 1
        ;;
      transport)
        printf '%s\n' '{"status":"failed","reason":"gateway_request_failed"}'
        exit 1
        ;;
      permanent)
        printf '%s\n' '{"status":"failed","reason":"gateway_returned_HTTP_401"}'
        exit 1
        ;;
      malformed)
        printf '%s\n' '{"status":"failed","reason":"gateway_returned_invalid_JSON"}'
        exit 1
        ;;
    esac
    printf '%s\n' '{"conversation_id_present":true,"output_present":true,"status":"completed","usage_present":true}'
    ;;
  *)
    exit 2
    ;;
esac
MOCK
chmod +x "$tmp/bin/"*

run_case() {
  local scenario="$1" sla="$2" output error
  output="$tmp/$scenario.out"
  error="$tmp/$scenario.err"
  mkdir -p "$tmp/$scenario"
  printf '%s\n' 100 > "$tmp/$scenario/clock"
  printf '%s\n' 0 > "$tmp/$scenario/docker-count"
  printf '%s\n' 0 > "$tmp/$scenario/timeout-count"
  printf '%s\n' "$scenario" > "$tmp/$scenario/scenario"
  FIXTURE="$tmp/$scenario" TEST_MODEL='Qwen/Qwen3-0.6B' PATH="$tmp/bin:$PATH" \
    bash "$probe_loop" 'Qwen/Qwen3-0.6B' "$sla" > "$output" 2> "$error"
}

run_case pre-dispatch-success 20
[[ "$(cat "$tmp/pre-dispatch-success/docker-count")" == 2 ]]
grep -Fq 'gateway_pre_dispatch_rejected' "$tmp/pre-dispatch-success.out"

if run_case timeout 20; then
  printf 'ambiguous timeout unexpectedly retried or passed\n' >&2
  exit 1
fi
[[ "$(cat "$tmp/timeout/timeout-count")" == 1 ]]
[[ "$(cat "$tmp/timeout/docker-count")" == 0 ]]
grep -Fq 'without safe retry attempt=1 reason=probe_timeout' "$tmp/timeout.err"

if run_case persistent-pre-dispatch 12; then
  printf 'persistent retryable failure unexpectedly passed\n' >&2
  exit 1
fi
[[ "$(cat "$tmp/persistent-pre-dispatch/docker-count")" -gt 1 ]]
grep -Fq 'did not recover within 12s' "$tmp/persistent-pre-dispatch.err"

for scenario in generic-503 dispatched-503 transport; do
  if run_case "$scenario" 20; then
    printf '%s unexpectedly retried or passed\n' "$scenario" >&2
    exit 1
  fi
  [[ "$(cat "$tmp/$scenario/docker-count")" == 1 ]]
done
grep -Fq 'without safe retry attempt=1 reason=gateway_returned_HTTP_503' "$tmp/generic-503.err"
grep -Fq 'without safe retry attempt=1 reason=gateway_returned_HTTP_503' "$tmp/dispatched-503.err"
grep -Fq 'without safe retry attempt=1 reason=gateway_request_failed' "$tmp/transport.err"

if run_case permanent 20; then
  printf 'permanent failure unexpectedly passed\n' >&2
  exit 1
fi
[[ "$(cat "$tmp/permanent/docker-count")" == 1 ]]
grep -Fq 'reason=gateway_returned_HTTP_401' "$tmp/permanent.err"

if run_case malformed 20; then
  printf 'malformed response unexpectedly passed\n' >&2
  exit 1
fi
[[ "$(cat "$tmp/malformed/docker-count")" == 1 ]]
grep -Fq 'reason=gateway_returned_invalid_JSON' "$tmp/malformed.err"

if run_case deadline-boundary 1; then
  printf 'expired deadline unexpectedly passed\n' >&2
  exit 1
fi
[[ "$(cat "$tmp/deadline-boundary/docker-count")" == 0 ]]
[[ "$(cat "$tmp/deadline-boundary/timeout-count")" == 0 ]]
grep -Fq 'did not recover within 1s attempts=0 last_reason=not_started' "$tmp/deadline-boundary.err"

printf 'PASS Telegram consumer probe retries only proven pre-dispatch rejection and fails closed otherwise\n'
