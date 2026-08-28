#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --artifacts DIR --published DIR" >&2; }
ARTIFACTS=''
PUBLISHED=''
while (($#)); do
  case "$1" in
    --artifacts) ARTIFACTS="$2"; shift 2 ;;
    --published) PUBLISHED="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -d "$ARTIFACTS" && -n "$PUBLISHED" ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema='v1.bootstrap.schema.json'
documents=(gonka-mainnet.json gonka-testnet.json gonka-devnet-community.json)
[[ -f "$ARTIFACTS/$schema" ]] || { echo "bootstrap publication lacks $schema" >&2; exit 1; }
cmp -s "$ARTIFACTS/$schema" "$ROOT/bootstrap/$schema" || {
  echo 'bootstrap publication schema differs from the repository v1 schema' >&2
  exit 1
}
for document in "${documents[@]}"; do
  [[ -f "$ARTIFACTS/$document" ]] || { echo "bootstrap publication lacks $document" >&2; exit 1; }
  python3 "$ROOT/scripts/network-bootstrap.py" verify "$ARTIFACTS/$document" >/dev/null
done

mkdir -p "$PUBLISHED"
stage="$(mktemp -d "$PUBLISHED/.network-bootstrap.XXXXXX")"
link_stage=''
trap 'rm -rf -- "$stage" "$link_stage"' EXIT
install -m 0644 "$ARTIFACTS/$schema" "$stage/$schema"
for document in "${documents[@]}"; do
  install -m 0644 "$ARTIFACTS/$document" "$stage/$document"
done
for document in "${documents[@]}"; do
  python3 "$ROOT/scripts/network-bootstrap.py" verify "$stage/$document" >/dev/null
done
release_sha256="$({
  sha256sum "$stage/$schema" | awk '{print $1}'
  for document in "${documents[@]}"; do sha256sum "$stage/$document" | awk '{print $1}'; done
} | sha256sum | awk '{print $1}')"
release="releases/$release_sha256"
mkdir -p "$PUBLISHED/releases"
if [[ -e "$PUBLISHED/$release" ]]; then
  cmp -s "$stage/$schema" "$PUBLISHED/$release/$schema" || { echo 'existing bootstrap release has a different schema' >&2; exit 1; }
  for document in "${documents[@]}"; do
    cmp -s "$stage/$document" "$PUBLISHED/$release/$document" || { echo "existing bootstrap release differs document=$document" >&2; exit 1; }
  done
  rm -rf -- "$stage"
else
  chmod 0755 "$stage"
  mv -T "$stage" "$PUBLISHED/$release"
fi
stage=''
link_stage="$PUBLISHED/.current.$release_sha256"
ln -s "$release" "$link_stage"
mv -Tf "$link_stage" "$PUBLISHED/current"
printf 'PASS published network bootstrap set documents=%s schema=%s\n' "${#documents[@]}" "$schema"
