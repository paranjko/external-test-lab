#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && -r "$1" ]] || { echo 'shared inferenced resolver requires a readable JOIN profile' >&2; exit 2; }
profile="$1"
version="$(jq -er '.spec.components.core.expected_runtime.version' "$profile")"
expected_archive="$(jq -er '.spec.components.core.installation.binary.sha256' "$profile")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][A-Za-z0-9._+-]+)?$ && "$expected_archive" =~ ^[0-9a-f]{64}$ ]] \
  || { echo 'JOIN profile has invalid inferenced artifact identity' >&2; exit 1; }
operator_root="${GDC_INTERNAL_DATA_ROOT:-${GDC_HOME:-}}"
[[ -n "$operator_root" ]] || { echo 'operator data root is unavailable' >&2; exit 1; }
dir="$operator_root/bin/$version"; binary="$dir/inferenced"; metadata="$dir/artifact.env"
[[ ! -L "$operator_root" && ! -L "$operator_root/bin" && ! -L "$dir" && -f "$binary" && -x "$binary" && ! -L "$binary" && -f "$metadata" && ! -L "$metadata" ]] \
  || { echo 'shared inferenced CLI or metadata is missing or unsafe' >&2; exit 1; }
archive="$(awk -F= '$1 == "archive_sha256" {print $2}' "$metadata")"
platform="$(awk -F= '$1 == "platform" {print $2}' "$metadata")"
recorded_binary="$(awk -F= '$1 == "binary_sha256" {print $2}' "$metadata")"
actual_binary="$(sha256sum "$binary" | awk '{print $1}')"
[[ "$archive" == "$expected_archive" && "$platform" == LINUX_AMD64 && "$recorded_binary" == "$actual_binary" ]] \
  || { echo 'shared inferenced CLI does not match the JOIN profile artifact' >&2; exit 1; }
output="$("$binary" version 2>&1 || true)"
[[ "$output" =~ (^|[^0-9])v?${version//./\\.}([^0-9]|$) ]] \
  || { echo 'shared inferenced CLI reports the wrong version' >&2; exit 1; }
printf '%s\n' "$binary"
