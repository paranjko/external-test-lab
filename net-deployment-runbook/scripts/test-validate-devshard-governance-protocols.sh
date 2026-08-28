#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

validator="$ROOT/scripts/validate-devshard-governance-protocols.sh"
[[ "$($validator 'v3 v4 v5' 'v3 v4 v5')" == 'v3 v4 v5' ]]
[[ "$($validator 'v5 v3 v4' 'v3 v4 v5')" == 'v3 v4 v5' ]]

if "$validator" 'v3 v5' 'v3 v4 v5' >"$tmp/out" 2>"$tmp/err"; then
  echo 'partial replacement of the governance protocol set was accepted' >&2
  exit 1
fi
grep -Fq 'must exactly match the selected profile candidates: v3 v4 v5 (missing: v4)' "$tmp/err"

if "$validator" 'v3 v6' 'v3 v4 v5' >"$tmp/out" 2>"$tmp/err"; then
  echo 'protocol outside the governance candidate set was accepted' >&2
  exit 1
fi
grep -Fq 'v6 is not an immutable governance candidate' "$tmp/err"

if "$validator" 'v3 v3' 'v3 v4 v5' >"$tmp/out" 2>"$tmp/err"; then
  echo 'duplicate requested protocol was accepted' >&2
  exit 1
fi
grep -Fq 'duplicate requested DevShard protocol: v3' "$tmp/err"

if "$validator" 'v3 v4 v5' 'v3 v4 v4 v5' >"$tmp/out" 2>"$tmp/err"; then
  echo 'duplicate governance candidate was accepted' >&2
  exit 1
fi
grep -Fq 'duplicate governance DevShard candidate: v4' "$tmp/err"

printf 'PASS DevShard governance protocol boundary\n'
