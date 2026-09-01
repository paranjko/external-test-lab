#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT/04-ops/site/index.html}"
OUTPUT="${2:-}"
[[ -n "$OUTPUT" ]] || { echo "usage: $0 [source-index.html] <output-index.html>" >&2; exit 2; }
[[ -f "$SOURCE" ]] || { echo "site source does not exist: $SOURCE" >&2; exit 2; }

REPOSITORY="$(git -C "$ROOT" rev-parse --show-toplevel)"
SITE_PATH="$(realpath --relative-to="$REPOSITORY" "$ROOT/04-ops/site")"
if [[ -n "${SITE_REVISION:-}" ]]; then
  COMMIT="$SITE_REVISION"
else
  COMMIT="$(git -C "$REPOSITORY" log -n 1 --pretty=format:%H -- "$SITE_PATH")"
fi
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "cannot determine the site source revision" >&2; exit 1; }
SHORT_COMMIT="${COMMIT:0:7}"
REFERENCE_URL="https://github.com/paranjko/external-test-lab/tree/$COMMIT/$SITE_PATH"

mkdir -p "$(dirname "$OUTPUT")"
TEMPORARY="$(mktemp "$(dirname "$OUTPUT")/.site-index.XXXXXX")"
trap 'rm -f "$TEMPORARY"' EXIT

sed -E "s#https://github\.com/paranjko/external-test-lab/tree/[0-9a-f]+/$SITE_PATH\"[^>]*>ref:[0-9a-f]+#${REFERENCE_URL}\" target=\"_blank\" rel=\"noopener\">ref:${SHORT_COMMIT}#" "$SOURCE" >"$TEMPORARY"
grep -Fq "$REFERENCE_URL" "$TEMPORARY" || { echo "site source revision link was not rendered" >&2; exit 1; }
grep -Fq "ref:$SHORT_COMMIT" "$TEMPORARY" || { echo "site source short revision was not rendered" >&2; exit 1; }
mv "$TEMPORARY" "$OUTPUT"
