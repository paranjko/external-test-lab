#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
installer="$ROOT/../install_inferenced.sh"

bash -n "$installer"
grep -Fq "PINNED_VERSION='0.2.15'" "$installer"
grep -Fq "RELEASE_TAG='release/v0.2.15'" "$installer"
grep -Fq 'downloaded archive SHA-256 does not match the pinned release artifact' "$installer"
grep -Fq 'gh attestation verify install_inferenced.sh -R paranjko/external-test-lab && sh install_inferenced.sh' "$installer"
if grep -Fq 'api.github.com/repos/gonka-ai/gonka/releases' "$installer"; then
  echo 'installer must not resolve a mutable latest release' >&2
  exit 1
fi
if grep -Fq 'raw.githubusercontent.com' "$installer"; then
  echo 'installer instructions must use the attested public installer URL' >&2
  exit 1
fi
grep -Fq 'install_inferenced.sh' "$ROOT/Makefile"
grep -Fq 'subject-path: install_inferenced.sh' "$ROOT/../.github/workflows/site-publish.yml"
printf 'PASS installer uses pinned official artifacts and is included in the attested site release\n'
