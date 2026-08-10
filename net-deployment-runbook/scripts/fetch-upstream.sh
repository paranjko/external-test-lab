#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
# `fetch-upstream.sh` is executed as a child process by the gateway-image
# builder.  The parent has loaded `.env`, but shell variables are not
# automatically inherited by a child shell.  Load the same profile here so
# the repository URL and immutable commit are both defined.
load_project
DEST="${1:-$ROOT/vendor/gonka}"
if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" fetch --tags --force origin
else
  mkdir -p "$(dirname "$DEST")"
  git clone --filter=blob:none "$GONKA_REPOSITORY" "$DEST"
fi
git -C "$DEST" checkout --detach "$GONKA_COMMIT"
ACTUAL="$(git -C "$DEST" rev-parse HEAD)"
[[ "$ACTUAL" == "$GONKA_COMMIT" ]] || { echo "Commit mismatch: $ACTUAL" >&2; exit 1; }
printf 'Pinned upstream: %s\n' "$ACTUAL"
