#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
library="$ROOT/scripts/lib.sh"

# The launcher sets ROOT from the executable path before sourcing lib.sh.
# `load_project` must preserve that value: otherwise an invocation from a
# worktree can silently execute profiles and helpers from another checkout.
grep -Fq 'ROOT="${ROOT:-$(kit_root)}"' "$library"
! grep -Fq 'ROOT="$(kit_root)"' "$library"

printf '%s\n' 'PASS launcher root contract'
