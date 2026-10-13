#!/usr/bin/env sh
# Container-side initial runtime installation; subsequent on-chain upgrades
# belong to Cosmovisor and are never reset to the Bootstrap version.
set -eu
[ "$#" -eq 3 ] || exit 2
state=$1 package=$2 executable=$3
case "$state" in /*) ;; *) exit 2 ;; esac
case "$executable" in inferenced|decentralized-api) ;; *) exit 2 ;; esac
fail() { echo "ERROR Bootstrap runtime: $1" >&2; exit 1; }
cosmo="$state/cosmovisor"
[ ! -L "$cosmo" ] || fail 'Cosmovisor home is a symlink'
(cd "$package/bin" && sha256sum -c ../SHA256SUMS) >/dev/null || fail 'staged package is corrupt'
if [ -e "$cosmo" ] || [ -L "$cosmo" ]; then
  [ -d "$cosmo" ] || fail 'Cosmovisor home is not a directory'
  cmp -s "$cosmo/genesis/archive.sha256" "$package/archive.sha256" || fail 'retained initial runtime differs from Bootstrap; use explicit recovery'
  (cd "$cosmo/genesis/bin" && sha256sum -c "$package/SHA256SUMS") >/dev/null || fail 'retained initial runtime is corrupt'
  selected="$(readlink -f "$cosmo/current")" || fail 'current is not resolvable'
  case "$selected" in "$cosmo/genesis"|"$cosmo"/upgrades/*) ;; *) fail 'current escapes Cosmovisor home' ;; esac
  [ -L "$cosmo/current" ] && [ -x "$selected/bin/$executable" ] || fail 'current has no executable'
  exit 0
fi
mkdir -p "$state"
staged="$(mktemp -d "$state/.bootstrap-runtime.XXXXXX")"
trap 'rm -rf "$staged"' EXIT HUP INT TERM
mkdir -p "$staged/genesis/bin"
cp "$package/bin/"* "$staged/genesis/bin/"
cp "$package/archive.sha256" "$staged/genesis/archive.sha256"
ln -s genesis "$staged/current"
mv "$staged" "$cosmo"
