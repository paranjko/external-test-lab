#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

shopt -s nullglob
found=0
for skill_md in skills/*/SKILL.md; do
  skills-ref validate "$(dirname "$skill_md")"
  found=$((found + 1))
done
test "$found" -ge 1

# Discovery must find the actual name rows, not a mention in a description.
# This verification must not upload unpublished skill contents as telemetry.
skills_cli="$PWD/skills/node_modules/.bin/skills"
test -x "$skills_cli" || { printf '%s\n' 'Run make -C skills dependencies first.' >&2; exit 1; }
list_out="$(DISABLE_TELEMETRY=1 "$skills_cli" add . --list -y)"
printf '%s\n' "$list_out"
printf '%s\n' "$list_out" | sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' | awk '
{
  line = $0
  sub(/^[^A-Za-z0-9_-]+/, "", line)
  if (line == "openai-host-compat") host = 1
  if (line == "openai-responses-adapter") resp = 1
  if (line == "gonka-validator-diagnosis") diagnosis = 1
}
END { if (!host || !resp || !diagnosis) exit 1 }
'
