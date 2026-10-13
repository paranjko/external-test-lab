#!/usr/bin/env bash
# Partition entrypoints only: every invocation still follows external sources.
set -Eeuo pipefail
image="${1:?ShellCheck image is required}"
shard="${2:-0}"
shards="${3:-1}"
mode="${4:-run}"
[[ "$shard" =~ ^(0|[1-9][0-9]{0,3})$ && "$shards" =~ ^[1-9][0-9]{0,3}$ ]] &&
  (( shard < shards )) || { echo 'invalid ShellCheck shard index/count' >&2; exit 2; }
[[ "$mode" == run || "$mode" == --list ]] || { echo 'invalid ShellCheck mode' >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
inventory="$(make --no-print-directory shellcheck-files)"
mapfile -t files <<<"$inventory"
(( shards <= ${#files[@]} )) || { echo 'ShellCheck shard would be empty' >&2; exit 2; }
selected=()
for ((i=shard; i<${#files[@]}; i+=shards)); do
  selected+=("${files[$i]}")
done
if [[ "$mode" == --list ]]; then
  printf '%s\n' "${selected[@]}"
else
  printf 'ShellCheck shard %s/%s: %s entrypoints\n' "$shard" "$shards" "${#selected[@]}"
  docker run --rm --volume "$root:/mnt:ro" --workdir /mnt "$image" \
    --external-sources --severity=warning "${selected[@]}"
fi
