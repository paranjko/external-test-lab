#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-$ROOT/profiles/amd-mlnode/gfx1201.json}"
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'AMD artifact CI publication requires GitHub Actions' >&2; exit 2; }
[[ -n "${GITHUB_OUTPUT:-}" ]] || { echo 'AMD artifact CI publication requires GITHUB_OUTPUT' >&2; exit 2; }

result="$("$ROOT/scripts/build-amd-mlnode.sh" "$profile" --ci-publish)"
printf '%s\n' "$result"
published="$(awk '/^PUBLISHED ghcr\.io\/paranjko\/gdc-mlnode:.+@sha256:[a-f0-9]{64}$/ {print; exit}' <<<"$result")"
[[ -n "$published" ]] || { echo 'AMD artifact CI build did not report a published digest' >&2; exit 1; }
reference="${published#PUBLISHED }"
repository="${reference%%:*}"
digest="${reference##*@}"
printf 'subject_name=%s\nsubject_digest=%s\nreference=%s\n' "$repository" "$digest" "$reference" >>"$GITHUB_OUTPUT"
printf 'PUBLISHED_AMD_MLNODE=%s\n' "$reference"
