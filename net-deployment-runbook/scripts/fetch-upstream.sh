#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/profile.sh"
load_profiles
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
