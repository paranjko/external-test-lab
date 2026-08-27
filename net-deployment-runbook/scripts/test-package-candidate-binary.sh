#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGER="$ROOT/scripts/package-candidate-binary.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

make_export() {
  local package_dir="$1"
  shift
  mkdir -p "$package_dir/build_output"
  while (( $# > 0 )); do
    printf '%s-content\n' "$1" >"$package_dir/build_output/$1"
    shift
  done
}

make_export "$temporary/inferenced-export" \
  inferenced libwasmvm_muslc.x86_64.a wrapped_token.wasm libgcc_s.so.1
"$PACKAGER" inferenced "$temporary/inferenced-export" "$temporary/inferenced.zip"
[[ "$(unzip -Z1 "$temporary/inferenced.zip")" == inferenced ]]
[[ "$(unzip -p "$temporary/inferenced.zip" inferenced)" == inferenced-content ]]
[[ -f "$temporary/inferenced-export/build_output/wrapped_token.wasm" ]]
mkdir -p "$temporary/operator-unpack"
unzip -q "$temporary/inferenced.zip" -d "$temporary/operator-unpack"
[[ -x "$temporary/operator-unpack/inferenced" ]]

make_export "$temporary/static-operator-export" inferenced
"$PACKAGER" inferenced-operator "$temporary/static-operator-export" \
  "$temporary/inferenced-operator.zip"
[[ "$(unzip -Z1 "$temporary/inferenced-operator.zip")" == inferenced ]]
[[ "$(unzip -p "$temporary/inferenced-operator.zip" inferenced)" == inferenced-content ]]

make_export "$temporary/dapi-export" \
  decentralized-api inferenced libwasmvm_muslc.x86_64.a libgcc_s.so.1
"$PACKAGER" decentralized-api "$temporary/dapi-export" "$temporary/decentralized-api.zip"
[[ "$(unzip -Z1 "$temporary/decentralized-api.zip")" == decentralized-api ]]
! unzip -Z1 "$temporary/decentralized-api.zip" | grep -Fqx inferenced

make_export "$temporary/edge-export" edge-api libgcc_s.so.1
"$PACKAGER" edge-api "$temporary/edge-export" "$temporary/edge-api.zip"
[[ "$(unzip -Z1 "$temporary/edge-api.zip")" == edge-api ]]

mkdir -p "$temporary/direct"
printf 'devshardd-binary\n' >"$temporary/direct/devshardd"
"$PACKAGER" devshardd "$temporary/direct" "$temporary/devshardd.zip"
[[ "$(unzip -Z1 "$temporary/devshardd.zip")" == devshardd ]]

make_export "$temporary/reject" \
  decentralized-api inferenced libwasmvm_muslc.x86_64.a libgcc_s.so.1 extra
if "$PACKAGER" decentralized-api "$temporary/reject" "$temporary/reject.zip" 2>/dev/null; then
  echo 'packager accepted an unexpected archive member' >&2
  exit 1
fi

make_export "$temporary/missing" inferenced libgcc_s.so.1 wrapped_token.wasm
if "$PACKAGER" inferenced "$temporary/missing" "$temporary/missing.zip" 2>/dev/null; then
  echo 'packager accepted an incomplete pinned exporter layout' >&2
  exit 1
fi

make_export "$temporary/root-extra" edge-api libgcc_s.so.1
printf 'unexpected\n' >"$temporary/root-extra/unreviewed"
if "$PACKAGER" edge-api "$temporary/root-extra" "$temporary/root-extra.zip" 2>/dev/null; then
  echo 'packager accepted an unexpected exporter-root entry' >&2
  exit 1
fi

printf 'PASS candidate binary archive layout\n'
