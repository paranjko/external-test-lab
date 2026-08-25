#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reconcile="$ROOT/04-ops/edge-node/reconcile-join-bootstrap.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

published="$tmp/published/join-bootstrap"
mkdir -p "$published/genesis"
printf 'previous\n' >"$published/genesis/genesis.json"
(cd "$published" && sha256sum genesis/genesis.json >manifest.sha256)
sed -i 's#  genesis/#  ./genesis/#' "$published/manifest.sha256"
before="$(sha256sum "$published/manifest.sha256")"

"$reconcile" "$tmp/no-staged-bundle" "$published"
[[ "$(sha256sum "$published/manifest.sha256")" == "$before" ]]
grep -Fxq previous "$published/genesis/genesis.json"

staged="$tmp/staged"
mkdir -p "$staged/genesis"
printf 'replacement\n' >"$staged/genesis/genesis.json"
(cd "$staged" && sha256sum genesis/genesis.json >manifest.sha256)
sed -i 's#  genesis/#  ./genesis/#' "$staged/manifest.sha256"
"$reconcile" "$staged" "$published"
grep -Fxq replacement "$published/genesis/genesis.json"
[[ "$(sha256sum "$published/manifest.sha256")" != "$before" ]]

printf '0%.0s' {1..64} >"$staged/manifest.sha256"
printf '  ./genesis/genesis.json\n' >>"$staged/manifest.sha256"
if "$reconcile" "$staged" "$published"; then
  echo 'invalid staged bootstrap replaced the published bundle' >&2
  exit 1
fi
grep -Fxq replacement "$published/genesis/genesis.json"
printf 'PASS edge bootstrap publication retains or atomically replaces a verified bundle\n'
