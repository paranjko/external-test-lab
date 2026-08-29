#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 || $# -eq 3 ]] || {
  echo 'usage: validate-devshard-governance-protocols.sh REQUESTED ALLOWED [CURRENT]' >&2
  exit 2
}

requested="$1"
allowed="$2"
current_supplied=false
current=''
if [[ $# -eq 3 ]]; then
  current_supplied=true
  current="$3"
fi
read -r -a requested_protocols <<<"$requested"
read -r -a allowed_protocols <<<"$allowed"
(( ${#requested_protocols[@]} > 0 )) || { echo 'requested DevShard protocol set must not be empty' >&2; exit 2; }
(( ${#allowed_protocols[@]} > 0 )) || { echo 'governance DevShard candidate set must not be empty' >&2; exit 2; }

normalized_requested=()
for protocol in "${requested_protocols[@]}"; do
  [[ "$protocol" =~ ^v[1-9][0-9]*$ ]] || { echo "invalid requested DevShard protocol: $protocol" >&2; exit 2; }
  [[ " ${normalized_requested[*]} " != *" $protocol "* ]] || { echo "duplicate requested DevShard protocol: $protocol" >&2; exit 2; }
  [[ " ${allowed_protocols[*]} " == *" $protocol "* ]] || {
    echo "DevShard protocol $protocol is not an immutable governance candidate in the selected profile" >&2
    exit 2
  }
  normalized_requested+=("$protocol")
done

normalized_allowed=()
missing=()
for protocol in "${allowed_protocols[@]}"; do
  [[ "$protocol" =~ ^v[1-9][0-9]*$ ]] || { echo "invalid governance DevShard candidate: $protocol" >&2; exit 2; }
  [[ " ${normalized_allowed[*]} " != *" $protocol "* ]] || { echo "duplicate governance DevShard candidate: $protocol" >&2; exit 2; }
  normalized_allowed+=("$protocol")
  [[ " ${normalized_requested[*]} " == *" $protocol "* ]] || missing+=("$protocol")
done

# MsgUpdateParams replaces approved_versions wholesale. A partial selector
# would therefore revoke omitted protocols rather than add the requested ones.
if (( ${#normalized_requested[@]} != ${#normalized_allowed[@]} || ${#missing[@]} > 0 )); then
  printf 'requested DevShard protocol set must exactly match the selected profile candidates: %s' \
    "${normalized_allowed[*]}" >&2
  (( ${#missing[@]} == 0 )) || printf ' (missing: %s)' "${missing[*]}" >&2
  printf '\n' >&2
  exit 2
fi

if [[ "$current_supplied" == true ]]; then
  read -r -a current_protocols <<<"$current"
  normalized_current=()
  for protocol in "${current_protocols[@]}"; do
    [[ "$protocol" =~ ^v[1-9][0-9]*$ ]] \
      || { echo "invalid currently approved DevShard protocol: $protocol" >&2; exit 2; }
    [[ " ${normalized_current[*]} " != *" $protocol "* ]] \
      || { echo "duplicate currently approved DevShard protocol: $protocol" >&2; exit 2; }
    normalized_current+=("$protocol")
    [[ " ${normalized_requested[*]} " == *" $protocol "* ]] || {
      echo "requested DevShard governance set would revoke currently approved protocol: $protocol" >&2
      exit 2
    }
  done
fi

# Emit profile order so semantically identical user input renders identical
# proposal bytes and metadata.
printf '%s\n' "${normalized_allowed[*]}"
