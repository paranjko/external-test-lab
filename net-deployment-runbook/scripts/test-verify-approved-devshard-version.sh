#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url='https://example.invalid/devshardd-v4.zip'
sha="$(printf '4%.0s' {1..64})"
jq -n --arg url "$url" --arg sha "$sha" '{params:{devshard_escrow_params:{approved_versions:[
  {name:"v3",binary:"https://example.invalid/devshardd-v3.zip",sha256:("3" * 64)},
  {name:"v4",binary:$url,sha256:$sha},
  {name:"v5",binary:"https://example.invalid/devshardd-v5.zip",sha256:("5" * 64)}
]}}}' >"$tmp/params.json"

"$ROOT/scripts/verify-approved-devshard-version.sh" "$tmp/params.json" v4 "$url" "$sha" >/dev/null

if "$ROOT/scripts/verify-approved-devshard-version.sh" "$tmp/params.json" v4 "$url" "$(printf '0%.0s' {1..64})" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'mismatched DevShard checksum was accepted' >&2
  exit 1
fi
grep -Fq 'not uniquely approved with the pinned URL and SHA-256' "$tmp/err"

jq '.params.devshard_escrow_params.approved_versions += [
  {name:"v4",binary:"https://example.invalid/conflicting-v4.zip",sha256:("9" * 64)}
]' "$tmp/params.json" >"$tmp/duplicate.json"
if "$ROOT/scripts/verify-approved-devshard-version.sh" "$tmp/duplicate.json" v4 "$url" "$sha" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'duplicate DevShard protocol name was accepted' >&2
  exit 1
fi
grep -Fq 'not uniquely approved with the pinned URL and SHA-256' "$tmp/err"

jq '.params.devshard_escrow_params.approved_versions += ["invalid"]' \
  "$tmp/params.json" >"$tmp/malformed.json"
if "$ROOT/scripts/verify-approved-devshard-version.sh" "$tmp/malformed.json" v4 "$url" "$sha" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'malformed DevShard approval entry was accepted' >&2
  exit 1
fi
grep -Fq 'not uniquely approved with the pinned URL and SHA-256' "$tmp/err"

printf 'PASS effective DevShard approval verification\n'
