#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --input NODE_CONFIG --ml-host HOST --ml-alias SSH_ALIAS --output NODE_CONFIG --id-output FILE" >&2
}

input=''
ml_host=''
ml_alias=''
output=''
id_output=''
while (($#)); do
  case "$1" in
    --input) input="${2:-}"; shift 2 ;;
    --ml-host) ml_host="${2:-}"; shift 2 ;;
    --ml-alias) ml_alias="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --id-output) id_output="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -f "$input" && ! -L "$input" && -n "$output" && -n "$id_output" ]] || { usage; exit 2; }
[[ "$ml_host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'ML endpoint must be an IPv4 address or DNS name' >&2; exit 2; }
[[ "$ml_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'ML SSH alias is invalid' >&2; exit 2; }

jq -e '
  type == "array" and length > 0
  and all(.[]; (.id | type) == "string" and length > 0
      and (.host | type) == "string" and length > 0
      and (.inference_port | type) == "number"
      and (.poc_port | type) == "number")
  and (length as $count | [.[].id] | unique | length == $count)
  and (length as $count | [.[] | [ .host, .inference_port ]] | unique | length == $count)
' "$input" >/dev/null || { echo 'existing node configuration is not a valid unique ML endpoint list' >&2; exit 1; }

new_id="$(jq -er --arg alias "$ml_alias" '.[0].id + "--" + $alias' "$input")"
jq -e --arg id "$new_id" --arg host "$ml_host" '
  all(.[]; .id != $id and .host != $host)
' "$input" >/dev/null || { echo 'ML endpoint is already configured for this Network Node' >&2; exit 1; }

mkdir -p "$(dirname "$output")" "$(dirname "$id_output")"
jq --arg id "$new_id" --arg host "$ml_host" '
  .[0] as $template
  | . + [$template | .id = $id | .host = $host | .inference_port = 5000 | .poc_port = 5000]
' "$input" >"$output"
printf '%s\n' "$new_id" >"$id_output"
