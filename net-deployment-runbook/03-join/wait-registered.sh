#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 NODE_PUBLIC_URL ACCOUNT_ADDRESS [timeout-seconds]" >&2; exit 2; }
BASE="${1%/}"; ADDRESS="$2"; TIMEOUT="${3:-300}"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]{20,90}$ ]] || { echo 'Invalid Gonka address' >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -ge 30 ]] || { echo 'Invalid timeout' >&2; exit 2; }
DEADLINE=$((SECONDS + TIMEOUT))
printf 'WAIT  participant registration %s\n' "$ADDRESS"
while (( SECONDS < DEADLINE )); do
  if curl --connect-timeout 5 --max-time 10 -fsS "$BASE/v2/participants/$ADDRESS" >/dev/null 2>&1; then
    printf 'READY participant registered %s\n' "$ADDRESS"
    exit 0
  fi
  sleep 5
done
printf 'FAILED participant %s was not registered within %ss\n' "$ADDRESS" "$TIMEOUT" >&2
exit 1
