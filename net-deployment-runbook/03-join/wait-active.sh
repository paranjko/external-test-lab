#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 NODE_PUBLIC_URL ACCOUNT_ADDRESS [timeout-seconds]" >&2; exit 2; }
BASE="${1%/}"; ADDRESS="$2"; TIMEOUT="${3:-7200}"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]{20,90}$ ]] || { echo 'Invalid Gonka address' >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -ge 60 ]] || { echo 'Invalid timeout' >&2; exit 2; }
DEADLINE=$((SECONDS + TIMEOUT))
while (( SECONDS < DEADLINE )); do
  body="$(curl --connect-timeout 5 --max-time 10 -fsS "$BASE/v2/participants/$ADDRESS" || true)"
  status="$(jq -r '.participant.status // empty' <<<"$body" 2>/dev/null || true)"
  printf '%s  %s\n' "$(date -u +%FT%TZ)" "${status:-not-yet-visible}"
  case "$status" in
    ACTIVE|PARTICIPANT_STATUS_ACTIVE|1) exit 0 ;;
    INVALID|PARTICIPANT_STATUS_INVALID|3)
      jq . <<<"$body"
      exit 1
      ;;
  esac
  sleep 15
done
echo "Timed out after ${TIMEOUT}s waiting for participant $ADDRESS to become ACTIVE" >&2
exit 1
