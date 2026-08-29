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
if [[ "$(cat "$FIXTURE/scenario")" == timeout-success ]]; then
  count="$(cat "$FIXTURE/timeout-count")"
  printf '%s\n' "$((count + 1))" > "$FIXTURE/timeout-count"
  (( count > 0 )) || exit 124
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
      retry-success)
        if (( count == 0 )); then
          printf '%s\n' '{"status":"failed","reason":"gateway_returned_HTTP_429"}'
          exit 1
        fi
        ;;
      persistent)
        printf '%s\n' '{"status":"failed","reason":"gateway_returned_HTTP_503"}'
        exit 1
        ;;
      permanent)
        printf '%s\n' '{"status":"failed","reason":"gateway_returned_HTTP_401"}'
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

run_case retry-success 20
[[ "$(cat "$tmp/retry-success/docker-count")" == 2 ]]
grep -Fq 'gateway_returned_HTTP_429' "$tmp/retry-success.out"

run_case timeout-success 20
[[ "$(cat "$tmp/timeout-success/timeout-count")" == 2 ]]
[[ "$(cat "$tmp/timeout-success/docker-count")" == 1 ]]
grep -Fq 'probe_timeout' "$tmp/timeout-success.out"

if run_case persistent 12; then
  printf 'persistent retryable failure unexpectedly passed\n' >&2
  exit 1
fi
[[ "$(cat "$tmp/persistent/docker-count")" -gt 1 ]]
grep -Fq 'did not recover within 12s' "$tmp/persistent.err"

if run_case permanent 20; then
  printf 'permanent failure unexpectedly passed\n' >&2
  exit 1
fi
[[ "$(cat "$tmp/permanent/docker-count")" == 1 ]]
grep -Fq 'reason=gateway_returned_HTTP_401' "$tmp/permanent.err"

printf 'PASS Telegram consumer probe retry, expiry, cancellation, and fail-fast contracts\n'
