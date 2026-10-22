#!/usr/bin/env bash
set -Eeuo pipefail
# Generate read-only routes independently of inference/admission routing.
# Input: [{id:"A_V6",node:"node-a",port:18146}, ...].
targets="${1:?targets JSON required}"
node="${2:?host alias required}"
collector="${3:?collector IPv4 CIDR required}"
[[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
[[ "$collector" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || exit 2
IFS=. read -r -a octets <<<"${collector%/32}"
for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || exit 2; done
jq -e '
  type == "array" and length > 0 and
  all(.[]; type == "object" and (keys | sort) == ["id","node","port"]
    and (.id | type == "string" and test("^[A-Z][A-Z0-9_]*$"))
    and (.node | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and (.port | type == "number" and floor == . and . >= 1024 and . <= 65535))
  and (length == ([.[].id] | unique | length))
  and (length == ([.[] | [.node,.port]] | unique | length))
' <<<"$targets" >/dev/null || { echo 'invalid gateway observation targets' >&2; exit 2; }
while IFS=$'\t' read -r id port; do
  for kind in metrics status; do
    upstream=/metrics
    [[ "$kind" != status ]] || upstream=/v1/status
    printf '  @observe_%s_%s {\n    path /ops-gateways/%s/%s\n    method GET\n    remote_ip %s\n  }\n' "$id" "$kind" "$id" "$kind" "$collector"
    printf '  handle @observe_%s_%s {\n    rewrite * %s\n    reverse_proxy 127.0.0.1:%s\n  }\n' "$id" "$kind" "$upstream" "$port"
    printf '  handle /ops-gateways/%s/%s {\n    respond 403\n  }\n' "$id" "$kind"
  done
done < <(jq -r --arg node "$node" '.[] | select(.node == $node) | [.id,.port] | @tsv' <<<"$targets")
