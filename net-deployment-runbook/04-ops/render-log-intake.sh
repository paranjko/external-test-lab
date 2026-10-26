#!/usr/bin/env bash
set -Eeuo pipefail
# Render the log intake route of the OPS edge: only inventory Hosts with the push token reach the log store.
token_file="${1:?push token file required}"
shift
(($#)) || { echo 'at least one log source CIDR is required' >&2; exit 2; }
[[ -s "$token_file" && ! -L "$token_file" ]] || { echo 'push token file is missing' >&2; exit 2; }
token="$(<"$token_file")"
[[ "$token" =~ ^[A-Za-z0-9]{32,128}$ ]] || { echo 'invalid log push token' >&2; exit 2; }
for cidr in "$@"; do
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] || { echo "invalid log source CIDR: $cidr" >&2; exit 2; }
  IFS=. read -r -a octets <<<"${cidr%/*}"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || { echo "invalid log source CIDR: $cidr" >&2; exit 2; }
  done
done
printf '  @log_push {\n    path /ops-logs/push\n    method POST\n    remote_ip %s\n    header Authorization "Bearer %s"\n  }\n' "$*" "$token"
printf '  handle @log_push {\n    rewrite * /loki/api/v1/push\n    reverse_proxy 127.0.0.1:3100\n  }\n'
printf '  handle /ops-logs/push {\n    respond 403\n  }\n'
