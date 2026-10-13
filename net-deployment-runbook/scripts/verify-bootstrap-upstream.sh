#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 ]] || exit 2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap="$ROOT/../bootstrap/gonka-devnet-community.json"
commit="$(jq -er .software.deployment.commit "$bootstrap")"
while IFS=$'\t' read -r path expected; do
  actual="$(git -C "$1" show "$commit:$path" | sha256sum | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "Bootstrap recipe digest mismatch: $path" >&2; exit 1; }
done < <(jq -r '.software.deployment.compose_files[] | [.path,.sha256] | @tsv' "$bootstrap")
printf 'PASS Bootstrap recipe matches pinned upstream source\n'
