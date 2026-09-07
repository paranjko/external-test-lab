#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/profiles/candidates/release-notes.template.md"

[[ -s "$TEMPLATE" ]]
for field in \
  '{{PROFILE}}' '{{LAYER}}' '{{SOURCE_REPOSITORY}}' '{{SOURCE_REF}}' '{{SOURCE_COMMIT}}' \
  '{{RUNTIME_OCI_ARCHIVE}}' '{{HOST_OCI_ARCHIVE}}' '{{GATEWAY_OCI_ARCHIVE}}' '{{UPGRADE_ARCHIVE}}'; do
  grep -Fq -- "$field" "$TEMPLATE"
done

grep -Fq './gdc.sh release candidate prepare' "$TEMPLATE"
grep -Fq './gdc.sh release candidate build {{PROFILE}} --wait' "$TEMPLATE"
grep -Fq './gdc.sh release candidate verify {{PROFILE}}' "$TEMPLATE"
grep -Fq 'gh attestation verify "$artifact" -R paranjko/external-test-lab' "$TEMPLATE"
grep -Fq -- '--predicate-type https://spdx.dev/Document' "$TEMPLATE"
! grep -Fq -- '--signer-workflow' "$TEMPLATE"

printf '%s\n' 'PASS candidate release-notes template covers artifact, reproduction, and attestation verification'
