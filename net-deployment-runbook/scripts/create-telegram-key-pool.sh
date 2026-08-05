#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --secrets-dir DIR [--count N]" >&2; }
SECRETS=''; COUNT=100
while (($#)); do
  case "$1" in
    --secrets-dir) SECRETS="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$SECRETS" && "$COUNT" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
(( COUNT <= 10000 )) || { echo 'count must not exceed 10000' >&2; exit 2; }
keys_file="$SECRETS/gateway.client-keys"
pool_file="$SECRETS/gateway-key-pool.json"
[[ -s "$keys_file" ]] || { echo "missing $keys_file" >&2; exit 1; }
[[ ! -e "$pool_file" ]] || { echo "$pool_file already exists; refuse to replace an issued-key pool" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for _ in $(seq 1 "$COUNT"); do
  printf 'sk-gdc-%s\n' "$(openssl rand -hex 24)" >>"$tmp"
done
sort -u "$tmp" -o "$tmp"
[[ "$(wc -l <"$tmp" | tr -d ' ')" == "$COUNT" ]] || { echo 'failed to generate unique keys' >&2; exit 1; }

umask 077
jq -Rn '[inputs]' <"$tmp" | jq -c '{keys:.}' >"$pool_file"
chmod 600 "$pool_file"
existing="$(tr -d '\r\n' <"$keys_file")"
new="$(paste -sd, "$tmp")"
printf '%s,%s\n' "$existing" "$new" >"$keys_file"
chmod 600 "$keys_file"
printf 'READY Telegram key pool: %s keys at %s\n' "$COUNT" "$pool_file"
