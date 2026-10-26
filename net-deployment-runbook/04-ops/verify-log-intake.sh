#!/usr/bin/env bash
set -Eeuo pipefail
# Prove the installed intake route end to end: refused without the token, stored with it.
host="${1:?public host required}"
fragment="${2:?rendered intake fragment required}"
[[ "$host" =~ ^[A-Za-z0-9.-]+$ && -s "$fragment" ]] || exit 2
token="$(sed -n 's/.*header Authorization "Bearer \([A-Za-z0-9]*\)".*/\1/p' "$fragment")"
[[ -n "$token" ]] || { echo 'intake fragment carries no push token' >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'Authorization: Bearer %s\n' "$token" >"$work/header"
url="https://$host/ops-logs/push"
marker="intake-check-$(date -u +%s)-$$"
body="$(printf '{"streams":[{"stream":{"host":"gdc-ops","component":"log-intake-check"},"values":[["%s","%s"]]}]}' "$(date +%s%N)" "$marker")"
code="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -X POST -H 'Content-Type: application/json' --data "$body" "$url")"
[[ "$code" == 403 ]] || { echo "intake accepted a push without the token: HTTP $code" >&2; exit 1; }
code="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -X POST -H 'Content-Type: application/json' -H @"$work/header" --data "$body" "$url")"
[[ "$code" == 204 ]] || { echo "intake refused a push with the token: HTTP $code" >&2; exit 1; }
for _ in $(seq 1 15); do
  if curl -fsSG -m 10 http://127.0.0.1:3100/loki/api/v1/query_range \
      --data-urlencode 'query={component="log-intake-check"}' --data-urlencode 'since=10m' \
      | grep -Fq "$marker"; then
    printf 'PASS log intake refuses a push without the token and stores one with it host=%s\n' "$host"
    exit 0
  fi
  sleep 2
done
echo 'pushed line did not reach the log store' >&2
exit 1
