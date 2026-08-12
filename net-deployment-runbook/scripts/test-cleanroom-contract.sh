#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/.devcontainer/verify-cleanroom.sh"
DOC="$ROOT/.devcontainer/README.md"
IGNORE="$ROOT/.dockerignore"

[[ -x "$VERIFY" ]]
for forbidden_path in accounts mnemonics runs secrets state; do
  grep -Fq "    $forbidden_path" "$VERIFY"
  grep -Fxq "$forbidden_path/" "$IGNORE"
done
grep -Fq 'host credential leaked into cleanroom' "$VERIFY"
grep -Fq 'GDC_HOME=/workspaces/external-join' "$DOC"
grep -Fq 'not a live independent-operator PASS by itself' "$DOC"

echo 'PASS cleanroom external-operator isolation contract'
