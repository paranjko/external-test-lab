#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
script="$ROOT/scripts/run-amd-mlnode-trial.sh"

if "$script" >/dev/null 2>&1; then
  echo 'AMD trial accepted an image without a digest' >&2
  exit 1
fi
grep -Fq -- '--device /dev/kfd' "$script"
grep -Fq 'renderD128' "$script"
grep -Fq -- '--group-add' "$script"
port_binding="$(printf '127.0.0.1:$%s:8080' '{port}')"
grep -Fq "$port_binding" "$script"
grep -Fq '/api/v1/inference/up/async' "$script"
grep -Fq '/v1/chat/completions' "$script"
printf 'PASS AMD MLNode trial requires an immutable image and ROCm device mapping\n'
