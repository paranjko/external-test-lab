#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 JOIN_RPC_URL SEED_RPC_URL [timeout-seconds]" >&2; exit 2; }
JOIN="${1%/}"; SEED="${2%/}"; TIMEOUT="${3:-3600}"
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -ge 30 ]] || { echo 'Invalid timeout' >&2; exit 2; }
DEADLINE=$((SECONDS + TIMEOUT))
join_height=unknown; seed_height=unknown; lag=unknown; catching=unknown
last_report=0
printf 'WAIT  synchronization: %s -> %s\n' "$JOIN" "$SEED"
while (( SECONDS < DEADLINE )); do
  join_json="$(curl --connect-timeout 5 --max-time 10 -fsS "$JOIN/status" 2>/dev/null || true)"
  seed_json="$(curl --connect-timeout 5 --max-time 10 -fsS "$SEED/status" 2>/dev/null || true)"
  if [[ -n "$join_json" && -n "$seed_json" ]]; then
    join_height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"$join_json")"
    seed_height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"$seed_json")"
    catching="$(jq -r '.result.sync_info.catching_up' <<<"$join_json")"
    if [[ "$join_height" =~ ^[0-9]+$ && "$seed_height" =~ ^[0-9]+$ && "$catching" =~ ^(true|false)$ ]]; then
      lag=$((seed_height - join_height)); (( lag < 0 )) && lag=0
      if [[ "$catching" == false && "$lag" -le 2 ]]; then
        printf 'READY  synchronized: join=%s seed=%s lag=%s\n' "$join_height" "$seed_height" "$lag"
        exit 0
      fi
    fi
  fi
  sleep 10
  elapsed=$((TIMEOUT - DEADLINE + SECONDS))
  if (( elapsed - last_report >= 30 )); then
    printf 'WAIT  synchronization: elapsed=%ss join=%s seed=%s lag=%s catching_up=%s\n' \
      "$elapsed" "$join_height" "$seed_height" "$lag" "$catching"
    last_report=$elapsed
  fi
done
printf 'FAILED  synchronization timeout after %ss: join=%s seed=%s lag=%s catching_up=%s\n' \
  "$TIMEOUT" "$join_height" "$seed_height" "$lag" "$catching" >&2
exit 1
