#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

base="${GDC_JOIN_BOOTSTRAP_URL:-https://${GENESIS_PUBLIC_HOST}/join-bootstrap}"
base="${base%/}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for path in genesis/genesis.json genesis/genesis.sha256 genesis/genesis-seeds.txt profile/genesis.env topology.env manifest.sha256; do
  mkdir -p "$tmp/$(dirname "$path")"
  curl -fsS --connect-timeout 10 --max-time 60 "$base/$path" -o "$tmp/$path"
done
(cd "$tmp" && sha256sum -c manifest.sha256)
grep -qx "release_profile=$GDC_RELEASE_PROFILE" "$tmp/profile/genesis.env" || die 'public join bootstrap release differs from selected profile'
install -d -m 0700 "$GENESIS" "$STATE/phase-profiles"
install -m 0600 "$tmp/genesis/genesis.json" "$GENESIS/genesis.json"
install -m 0600 "$tmp/genesis/genesis.sha256" "$GENESIS/genesis.sha256"
install -m 0600 "$tmp/genesis/genesis-seeds.txt" "$GENESIS/genesis-seeds.txt"
install -m 0600 "$tmp/profile/genesis.env" "$STATE/phase-profiles/genesis.env"
printf 'PASS imported public join bootstrap from %s\n' "$base"
