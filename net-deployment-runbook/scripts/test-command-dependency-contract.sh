#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
required="$ROOT/dependencies/ci-test-commands.txt"
optional="$ROOT/dependencies/optional-commands.txt"
schema_requirements="$ROOT/dependencies/bootstrap-schema-requirements.txt"
makefile="$ROOT/Makefile"
workflow="$ROOT/../.github/workflows/net-deployment-runbook.yml"

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

[[ -r "$schema_requirements" ]] || {
  echo "Bootstrap schema requirements are missing: $schema_requirements" >&2
  exit 1
}
grep -Fqx 'jsonschema==4.23.0' "$schema_requirements" || {
  echo 'Bootstrap schema dependency must stay pinned to jsonschema==4.23.0' >&2
  exit 1
}
grep -Fq 'bootstrap-schema-dependencies:' "$makefile" &&
  grep -Fq -- '--requirement dependencies/bootstrap-schema-requirements.txt' "$makefile" || {
    echo 'Bootstrap schema dependency target must install its declared requirement manifest' >&2
    exit 1
  }
schema_groups="matrix.group == 'bootstrap' || matrix.group == 'core' || matrix.group == 'join'"
[[ "$(grep -Fc "$schema_groups" "$workflow")" -eq 2 ]] &&
  grep -Fq "uses: actions/setup-python@v5.0.0" "$workflow" &&
  grep -Fq "python-version: '3.12'" "$workflow" &&
  grep -Fq 'run: make -C net-deployment-runbook bootstrap-schema-dependencies' "$workflow" || {
    echo 'Bootstrap schema requirement must be provisioned for bootstrap, core, and join CI groups' >&2
    exit 1
  }

forbidden_command="$(printf '%s%s' r g)"
if grep -R -n -E --include='*.sh' --exclude-dir=vendor --exclude-dir=.data \
  "(^|[^[:alnum:]_])${forbidden_command}([[:space:];|&()])" \
  "$ROOT"; then
  echo "$forbidden_command is not a runbook dependency; use grep or declare and provision a replacement" >&2
  exit 1
fi

printf 'PASS declared CI command baseline is present and %s is not required by shell code\n' "$forbidden_command"
