#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
installer="$ROOT/../install_inferenced.sh"

sh -n "$installer"
grep -Fq 'gh attestation verify install_inferenced.sh -R paranjko/external-test-lab && sh install_inferenced.sh' "$installer"
grep -Fq 'install_inferenced.sh' "$ROOT/Makefile"
grep -Fq 'subject-path: install_inferenced.sh' "$ROOT/../.github/workflows/site-publish.yml"
python3 "$ROOT/scripts/test-install-inferenced.py"
