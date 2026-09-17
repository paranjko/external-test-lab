#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$ROOT/scripts/publish-amd-mlnode-ci.sh"

grep -Fq 'GITHUB_ACTIONS' "$script"
grep -Fq 'GITHUB_OUTPUT' "$script"
grep -Fq '"$ROOT/scripts/build-amd-mlnode.sh" "$profile" --ci-publish' "$script"
grep -Fq 'subject_name=' "$script"
grep -Fq 'subject_digest=' "$script"
printf 'PASS AMD MLNode CI publication wrapper contract\n'
