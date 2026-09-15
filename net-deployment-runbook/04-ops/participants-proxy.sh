#!/usr/bin/env bash
# Read-only HTTP adapter launched per connection by systemd socket activation.
set -Eeuo pipefail
umask 077

collect_participants() {
  local api="${GDC_PARTICIPANTS_CHAIN_API:-http://127.0.0.1:1317}"
  local path=/productscience/inference/inference page height key='' cursor_keys='[]'
  local all='[]' params total remaining deadline=$((SECONDS+20))
  local pin=()
  while :; do
    remaining=$((deadline-SECONDS))
    ((remaining>0)) || return 1
    page="$(curl -fsS --connect-timeout 2 --max-time "$remaining" --max-filesize 16777216 \
      --get "$api$path/participant" "${pin[@]}" --data-urlencode pagination.limit=100 \
      --data-urlencode pagination.count_total=true --data-urlencode "pagination.key=$key")"
    jq -e '.participant | type=="array" and length<=100 and all(.[]; .address | type=="string" and length>0)' <<<"$page" >/dev/null
    jq -e '.pagination | type=="object" and (.next_key==null or (.next_key|type=="string"))' <<<"$page" >/dev/null
    if [[ -z "$key" ]]; then
      height="$(jq -er '.block_height | strings | select(test("^[1-9][0-9]*$"))' <<<"$page")"
      total="$(jq -er '.pagination.total | strings | select(test("^[0-9]+$"))' <<<"$page")"
      pin=(-H "x-cosmos-block-height: $height")
    else
      [[ "$(jq -r .block_height <<<"$page")" == "$height" ]] || return 1
    fi
    all="$(jq -cn --argjson prior "$all" --argjson page "$page" '$prior+$page.participant')"
    key="$(jq -r '.pagination.next_key // empty' <<<"$page")"
    [[ -n "$key" ]] || break
    jq -e --arg key "$key" 'index($key)==null' <<<"$cursor_keys" >/dev/null
    cursor_keys="$(jq -c --arg key "$key" '.+[$key]' <<<"$cursor_keys")"
  done
  jq -e --argjson total "$total" 'length==$total and ([.[].address]|unique|length)==$total' <<<"$all" >/dev/null
  remaining=$((deadline-SECONDS))
  ((remaining>0)) || return 1
  params="$(curl -fsS --connect-timeout 2 --max-time "$remaining" --max-filesize 16777216 \
    "${pin[@]}" "$api$path/params")"
  jq -e '.params.participant_access_params.blocked_participant_addresses |
    type=="array" and all(.[]; type=="string")' <<<"$params" >/dev/null
  jq -cn --arg height "$height" --argjson all "$all" --argjson params "$params" '
    $params.params.participant_access_params.blocked_participant_addresses as $blocked |
    [$all[] | select(.address as $address | $blocked | index($address)==null)] as $visible |
    {participant:$visible,block_height:$height,pagination:{next_key:null,total:($visible|length|tostring)}}'
}

if [[ "${1:-}" == --collect ]]; then
  collect_participants
  exit
fi

respond() {
  local status="$1" body="$2"
  printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: %s\r\n\r\n%s' \
    "$status" "$(LC_ALL=C printf %s "$body" | wc -c)" "$body"
}
IFS= read -r -t 3 request || exit 0
request="${request%$'\r'}"
read -r method target version extra <<<"$request"
if [[ -n "${extra:-}" || ! "${version:-}" =~ ^HTTP/1\.[01]$ || "${#request}" -gt 4096 ]]; then
  respond '400 Bad Request' '{"error":"invalid_request"}'; exit
fi
if [[ "$method" != GET ]]; then
  respond '405 Method Not Allowed' '{"error":"read_only"}'; exit
fi
if [[ "${target%%\?*}" != /status/participants ]]; then
  respond '404 Not Found' '{"error":"not_found"}'; exit
fi
# Consume bounded headers; never forward caller headers, URLs or pagination.
headers_done=false
for ((header_count=0;header_count<64;header_count++)); do
  IFS= read -r -t 3 header || break
  [[ "${#header}" -le 8192 ]] || break
  if [[ -z "${header%$'\r'}" ]]; then headers_done=true; break; fi
done
if [[ "$headers_done" != true ]]; then
  respond '400 Bad Request' '{"error":"invalid_headers"}'; exit
fi
result="$(mktemp)"
trap 'rm -f -- "$result"' EXIT
# A separate Bash keeps errexit effective for every upstream/schema check.
if bash "${BASH_SOURCE[0]}" --collect >"$result"; then
  respond '200 OK' "$(<"$result")"
else
  respond '503 Service Unavailable' '{"error":"participant_registry_unavailable"}'
fi
