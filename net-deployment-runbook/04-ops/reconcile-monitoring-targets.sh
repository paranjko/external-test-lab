#!/usr/bin/env bash
set -Eeuo pipefail
# Static inventory owns configured hosts; JOIN discovery owns additional hosts.
root="${1:?targets directory required}"
retired_file="${2:?retired host list required}"
[[ -d "$root/static/host" && ! -L "$root" && -f "$retired_file" ]] || exit 2
retired="$(<"$retired_file")"
for host in $retired; do
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'invalid retired host' >&2; exit 2; }
  [[ ! -e "$root/static/host/$host.json" ]] || { echo "retired host remains in static inventory: $host" >&2; exit 2; }
done
archive=''
for job in host cadvisor gonka-node; do
  [[ ! -L "$root/join/$job" ]] || exit 2
  for file in "$root/join/$job/"*.json; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || exit 2
    host="${file##*/}"; host="${host%.json}"
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
    jq -e --arg host "$host" 'type == "array" and length > 0 and all(.[]; .labels.host == $host)' "$file" >/dev/null
    if [[ -e "$root/static/host/$host.json" || " $retired " == *" $host "* ]]; then
      if [[ -z "$archive" ]]; then archive="$(mktemp -d "${root%/}/../retired-targets.XXXXXX")"; fi
      mkdir -p "$archive/$job"
      mv -- "$file" "$archive/$job/$host.json"
      printf 'RECONCILED job=%s host=%s backup=%s\n' "$job" "$host" "$archive"
    fi
  done
done
