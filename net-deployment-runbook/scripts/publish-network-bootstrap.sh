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
artifact_name="$(basename "$ARTIFACT")"
published_name="$(basename "$PUBLISHED")"
[[ "$artifact_name" == "$published_name" ]] || {
  echo "bootstrap publication target name differs artifact=$artifact_name target=$published_name" >&2
  exit 2
}
case "$artifact_name" in
  v1.bootstrap.schema.json)
    cmp -s "$ARTIFACT" "$ROOT/bootstrap/v1.bootstrap.schema.json" || {
      echo 'bootstrap publication schema differs from the repository v1 schema' >&2
      exit 1
    }
    ;;
  gonka-mainnet.json|gonka-testnet.json|gonka-devnet-community.json)
    python3 "$ROOT/scripts/network-bootstrap.py" verify "$ARTIFACT" >/dev/null
    ;;
  *)
    echo "unsupported bootstrap publication artifact=$artifact_name" >&2
    exit 2
    ;;
esac
mkdir -p "$(dirname "$PUBLISHED")"
stage="$(mktemp "$(dirname "$PUBLISHED")/.${PUBLISHED##*/}.XXXXXX")"
trap 'rm -f -- "$stage"' EXIT
install -m 0644 "$ARTIFACT" "$stage"
case "$artifact_name" in
  v1.bootstrap.schema.json) cmp -s "$stage" "$ROOT/bootstrap/v1.bootstrap.schema.json" ;;
  *) python3 "$ROOT/scripts/network-bootstrap.py" verify "$stage" >/dev/null ;;
esac
if [[ -e "$PUBLISHED" ]] && cmp -s "$stage" "$PUBLISHED"; then
  printf 'PASS published bootstrap artifact unchanged artifact=%s sha256=%s\n' "$artifact_name" "$(sha256sum "$PUBLISHED" | awk '{print $1}')"
  exit 0
fi
mv -f -- "$stage" "$PUBLISHED"
printf 'PASS atomically published bootstrap artifact artifact=%s sha256=%s\n' "$artifact_name" "$(sha256sum "$PUBLISHED" | awk '{print $1}')"
