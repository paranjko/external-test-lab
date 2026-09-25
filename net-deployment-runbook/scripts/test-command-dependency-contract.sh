#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
required="$ROOT/dependencies/ci-test-commands.txt"
optional="$ROOT/dependencies/optional-commands.txt"

for manifest in "$required" "$optional"; do
  [[ -r "$manifest" ]] || { echo "dependency manifest is missing: $manifest" >&2; exit 1; }
  LC_ALL=C sort -cu "$manifest" || {
    echo "dependency manifest is not sorted: $manifest" >&2
    exit 1
  }
done

while IFS= read -r command; do
  [[ -n "$command" && "$command" != \#* ]] || continue
  command -v "$command" >/dev/null 2>&1 || {
    echo "required CI test command is unavailable: $command" >&2
    exit 1
  }
done <"$required"

while IFS= read -r command; do
  [[ -n "$command" && "$command" != \#* ]] || continue
  if grep -Fqx -- "$command" "$required"; then
    echo "command is both required and optional: $command" >&2
    exit 1
  fi
done <"$optional"

forbidden_command="$(printf '%s%s' r g)"
if grep -R -n -E --include='*.sh' --exclude-dir=vendor \
  "(^|[^[:alnum:]_])${forbidden_command}([[:space:];|&()])" \
  "$ROOT"; then
  echo "$forbidden_command is not a runbook dependency; use grep or declare and provision a replacement" >&2
  exit 1
fi

printf 'PASS declared CI command baseline is present and %s is not required by shell code\n' "$forbidden_command"
