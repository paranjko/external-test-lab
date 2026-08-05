#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/profile.sh"
load_profiles
TOOL_IMAGE="${GDC_INFERENCED_TOOL_IMAGE:-$INFERENCED_IMAGE}"
[[ "$TOOL_IMAGE" == *@sha256:* ]] || { echo 'GDC_INFERENCED_TOOL_IMAGE must be immutable by digest' >&2; exit 2; }
HOME_DIR="${GDC_OPERATOR_HOME:-$ROOT/state/operator-home}"
mkdir -p "$HOME_DIR"
chmod 700 "$HOME_DIR"
TTY=()
[[ -t 0 && -t 1 ]] && TTY=(-t)
exec docker run --rm -i "${TTY[@]}" --network host \
  --user "$(id -u):$(id -g)" \
  -e HOME=/home/gdc \
  -v "$HOME_DIR:/home/gdc/.inference" \
  -v "$ROOT:/kit" \
  -w /kit \
  --entrypoint inferenced \
  "$TOOL_IMAGE" "$@"
