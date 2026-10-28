#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
installer="$ROOT/../install_inferenced.sh"

sh -n "$installer"
grep -Fq 'gh attestation verify install_inferenced.sh -R paranjko/external-test-lab && sh install_inferenced.sh' "$installer"
# Resolve the executable recipe through both supported Make entrypoints
for makefile in Makefile make/site.mk; do
  recipe=$(make --no-print-directory -C "$ROOT" -f "$makefile" -n prepare-static-site)
  [[ "$recipe" == *'install -m 0755 ../install_inferenced.sh '* ]] || {
    echo "Site release does not install the public CLI installer via $makefile" >&2
    exit 1
  }
done
grep -Fq 'subject-path: install_inferenced.sh' "$ROOT/../.github/workflows/site-publish.yml"
python3 "$ROOT/scripts/test-install-inferenced.py"
