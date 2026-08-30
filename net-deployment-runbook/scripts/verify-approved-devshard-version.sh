#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 4 ]] || {
  echo 'usage: verify-approved-devshard-version.sh PARAMS.json VERSION URL SHA256' >&2
  exit 2
}

params="$1"
version="$2"
expected_url="$3"
expected_sha="$4"
[[ -s "$params" ]] || { echo "inference params are missing or empty: $params" >&2; exit 2; }
[[ "$version" =~ ^v[1-9][0-9]*$ ]] || { echo "invalid DevShard version: $version" >&2; exit 2; }
[[ "$expected_url" =~ ^https:// ]] || { echo "invalid DevShard archive URL: $expected_url" >&2; exit 2; }
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid DevShard archive SHA-256: $expected_sha" >&2; exit 2; }

if ! jq -e --arg version "$version" --arg url "$expected_url" --arg sha "$expected_sha" '
  (.params // .).devshard_escrow_params.approved_versions as $versions
  | ($versions | type) == "array"
  and all($versions[];
    type == "object"
    and (.name | type == "string" and test("^v[1-9][0-9]*$"))
    and (.binary | type == "string" and test("^https://"))
    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
  and (($versions | map(.name) | length) == ($versions | map(.name) | unique | length))
  and ([$versions[] | select(.name == $version)] | length == 1)
  and ([$versions[] | select(.name == $version)][0]
    | .binary == $url and .sha256 == $sha)
' "$params" >/dev/null 2>&1; then
  echo "DevShard $version is not uniquely approved with the pinned URL and SHA-256" >&2
  exit 1
fi
printf 'PASS DevShard %s is approved with the pinned archive\n' "$version"
