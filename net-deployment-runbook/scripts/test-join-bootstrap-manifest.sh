#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$ROOT/scripts/verify-join-bootstrap-manifest.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/bootstrap"
paths=(genesis/genesis.json genesis/genesis.sha256 genesis/genesis-seeds.txt profile/genesis.env topology.env gateway/join-client-key)
for path in "${paths[@]}"; do
  mkdir -p "$fixture/$(dirname "$path")"
  printf '%s\n' "fixture:$path" >"$fixture/$path"
done
for path in "${paths[@]}"; do
  hash="$(sha256sum "$fixture/$path" | awk '{print $1}')"
  printf '%s  ./%s\n' "$hash" "$path"
done >"$fixture/manifest.sha256"

"$verifier" "$fixture" https://bootstrap.example.test/join-bootstrap

hash="$(sha256sum "$fixture/genesis/genesis.json" | awk '{print $1}')"
for _ in {1..6}; do
  printf '%s  ./genesis/genesis.json\n' "$hash"
done >"$fixture/manifest.sha256"
if "$verifier" "$fixture" https://bootstrap.example.test/join-bootstrap >"$tmp/duplicate.out" 2>"$tmp/duplicate.err"; then
  echo 'JOIN bootstrap manifest accepted duplicate paths' >&2
  exit 1
fi
grep -Fq 'duplicate path: path=./genesis/genesis.json' "$tmp/duplicate.err"

traversal_hash="$(sha256sum "$fixture/manifest.sha256" | awk '{print $1}')"
printf '%s  ./../manifest.sha256\n' "$traversal_hash" >"$fixture/manifest.sha256"
if "$verifier" "$fixture" https://bootstrap.example.test/join-bootstrap >"$tmp/traversal.out" 2>"$tmp/traversal.err"; then
  echo 'JOIN bootstrap manifest accepted a traversal path' >&2
  exit 1
fi
grep -Fq 'unexpected path: path=./../manifest.sha256' "$tmp/traversal.err"

printf '%s\n' 'PASS JOIN bootstrap manifest requires the exact unique file set'
