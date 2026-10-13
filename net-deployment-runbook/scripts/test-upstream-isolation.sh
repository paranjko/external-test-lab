#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

checksum="$(jq -cS . "$ROOT/test/fixtures/recovery/denom.json" | sha256sum | awk '{print $1}')"
[[ "$checksum" == 8719d0a58d07906eb54a34b193a5fd24e49d11f98737ba4f490de95f41617cf6 ]] || {
  echo 'recovery denomination fixture changed; verify against pinned source' >&2
  exit 1
}
if awk '/^test:/{printing=1} printing && /^test-command-dependency-contract:/{exit} printing' "$ROOT/Makefile" \
  | grep -Eq 'verify-release-profiles|fetch-upstream'; then
  echo 'ordinary tests must not fetch or audit a Gonka checkout' >&2
  exit 1
fi
if sed -n '/^  runbook-contracts:/,/^  upstream-profiles:/p' "$ROOT/../.github/workflows/net-deployment-runbook.yml" \
  | grep -q 'repository: gonka-ai/gonka'; then
  echo 'ordinary CI contracts must not check out Gonka' >&2
  exit 1
fi
grep -Fq 'denom_metadata="$ROOT/test/fixtures/recovery/denom.json"' "$ROOT/scripts/test-recover-incident-runtime.sh"
printf 'PASS ordinary tests and recovery metadata are independent of a Gonka checkout\n'
