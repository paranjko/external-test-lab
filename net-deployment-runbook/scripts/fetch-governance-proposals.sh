#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
  echo 'usage: fetch-governance-proposals.sh SSH_ALIAS OUTPUT.json' >&2
  exit 2
}

node="$1"
output="$2"
read -r -a ssh_command <<<"${GDC_SSH_BIN:-ssh}"
(( ${#ssh_command[@]} > 0 )) || { echo 'GDC_SSH_BIN must not be empty' >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
aggregate="$tmp/proposals.json"
seen_keys="$tmp/seen-keys.txt"
printf '{"proposals":[]}\n' >"$aggregate"
: >"$seen_keys"
next_key=''

for page_number in $(seq 1 1000); do
  query='pagination.limit=100'
  if [[ -n "$next_key" ]]; then
    if grep -Fxq -- "$next_key" "$seen_keys"; then
      echo "governance proposal pagination repeated a continuation key on page $page_number" >&2
      exit 1
    fi
    printf '%s\n' "$next_key" >>"$seen_keys"
    encoded_key="$(jq -rn --arg value "$next_key" '$value | @uri')"
    query+="&pagination.key=$encoded_key"
  fi

  page="$tmp/page-$page_number.json"
  url="http://127.0.0.1:1317/cosmos/gov/v1/proposals?$query"
  "${ssh_command[@]}" "$node" "curl -fsS '$url'" >"$page"
  jq -e '
    (.proposals | type == "array")
    and (((.pagination.next_key // "") | type) == "string")
  ' "$page" >/dev/null || {
    echo "governance proposal page $page_number has an invalid response shape" >&2
    exit 1
  }
  jq -s '{proposals: ((.[0].proposals // []) + (.[1].proposals // []))}' \
    "$aggregate" "$page" >"$tmp/aggregate.next.json"
  mv "$tmp/aggregate.next.json" "$aggregate"
  next_key="$(jq -r '.pagination.next_key // empty' "$page")"
  if [[ -z "$next_key" ]]; then
    jq -e '([.proposals[]?.id | tostring] | length) == ([.proposals[]?.id | tostring] | unique | length)' \
      "$aggregate" >/dev/null || {
      echo 'governance proposal pagination returned duplicate proposal IDs' >&2
      exit 1
    }
    install -m 0600 "$aggregate" "$output"
    exit 0
  fi
done

echo 'governance proposal pagination exceeded 1000 pages' >&2
exit 1
