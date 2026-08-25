#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
  echo "Usage: $0 BOOTSTRAP_DIRECTORY BOOTSTRAP_URL" >&2
  exit 2
}

bootstrap_dir="$1"
bootstrap_url="$2"
manifest="$bootstrap_dir/manifest.sha256"
[[ -f "$manifest" ]] || {
  echo "public JOIN bootstrap manifest is missing: bootstrap_url=$bootstrap_url" >&2
  exit 1
}

declare -A required=(
  [./genesis/genesis.json]=1
  [./genesis/genesis.sha256]=1
  [./genesis/genesis-seeds.txt]=1
  [./profile/genesis.env]=1
  [./topology.env]=1
  [./gateway/join-client-key]=1
)
declare -A seen=()
checked=0

while read -r expected path extra || [[ -n "${expected:-}${path:-}${extra:-}" ]]; do
  [[ "$expected" =~ ^[0-9a-f]{64}$ && -n "$path" && -z "$extra" ]] || {
    echo "public JOIN bootstrap manifest has an invalid checksum entry: $expected $path${extra:+ $extra}" >&2
    exit 1
  }
  [[ "${required[$path]+present}" == present ]] || {
    echo "public JOIN bootstrap manifest has an unexpected path: path=$path bootstrap_url=$bootstrap_url" >&2
    exit 1
  }
  [[ "${seen[$path]+present}" != present ]] || {
    echo "public JOIN bootstrap manifest has a duplicate path: path=$path bootstrap_url=$bootstrap_url" >&2
    exit 1
  }
  actual="$(sha256sum "$bootstrap_dir/${path#./}" | awk '{print $1}')" || {
    echo "public JOIN bootstrap checksum could not read file=$path bootstrap_url=$bootstrap_url" >&2
    exit 1
  }
  [[ "$actual" == "$expected" ]] || {
    printf 'public JOIN bootstrap checksum mismatch bootstrap_url=%s file=%s expected_sha256=%s actual_sha256=%s\n' \
      "$bootstrap_url" "$path" "$expected" "$actual" >&2
    exit 1
  }
  seen[$path]=1
  checked=$((checked + 1))
done <"$manifest"

for path in "${!required[@]}"; do
  [[ "${seen[$path]+present}" == present ]] || {
    echo "public JOIN bootstrap manifest is incomplete: missing_path=$path bootstrap_url=$bootstrap_url" >&2
    exit 1
  }
done
[[ "$checked" -eq "${#required[@]}" ]] || {
  echo "public JOIN bootstrap manifest is incomplete: expected_files=${#required[@]} checked_files=$checked bootstrap_url=$bootstrap_url" >&2
  exit 1
}
