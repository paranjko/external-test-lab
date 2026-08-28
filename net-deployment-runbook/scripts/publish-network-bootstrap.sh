#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --artifact FILE --published FILE" >&2; }

ARTIFACT=''
PUBLISHED=''
while (($#)); do
  case "$1" in
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --published) PUBLISHED="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$ARTIFACT" && -n "$PUBLISHED" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/scripts/network-bootstrap.py" verify "$ARTIFACT" >/dev/null
mkdir -p "$(dirname "$PUBLISHED")"
stage="$(mktemp "$(dirname "$PUBLISHED")/.${PUBLISHED##*/}.XXXXXX")"
trap 'rm -f -- "$stage"' EXIT
install -m 0644 "$ARTIFACT" "$stage"
python3 "$ROOT/scripts/network-bootstrap.py" verify "$stage" >/dev/null
if [[ -e "$PUBLISHED" ]] && cmp -s "$stage" "$PUBLISHED"; then
  printf 'PASS published network bootstrap unchanged sha256=%s\n' "$(sha256sum "$PUBLISHED" | awk '{print $1}')"
  exit 0
fi
mv -f -- "$stage" "$PUBLISHED"
printf 'PASS atomically published network bootstrap sha256=%s\n' "$(sha256sum "$PUBLISHED" | awk '{print $1}')"
