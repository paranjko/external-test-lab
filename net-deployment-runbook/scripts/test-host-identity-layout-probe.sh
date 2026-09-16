#!/usr/bin/env bash
# The probe that decides whether `gdc host reset` may remove the deployment
# root answers from the signing key itself. A directory or a p2p marker says
# nothing about which copy is live, and an interrupted migration leaves both.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Run the shipped remote snippet against a scratch tree instead of /srv/dai.
sed -n '/^host_identity_layout()/,/^}/p' "$ROOT/scripts/phase-node.sh" \
  | sed -n "/<<'REMOTE'/,/^REMOTE$/p" | sed '1d;$d' >"$tmp/probe.sh"
[[ -s "$tmp/probe.sh" ]] || { echo 'the identity layout probe could not be extracted' >&2; exit 1; }
grep -Fq 'priv_validator_key.softsign' "$tmp/probe.sh" \
  || { echo 'the identity layout probe does not read the signing key' >&2; exit 1; }
sed "s#/srv/dai#$tmp/srv/dai#g" "$tmp/probe.sh" >"$tmp/probe.run.sh"
mv "$tmp/probe.run.sh" "$tmp/probe.sh"

node=gdc-node0
layout_of() {
  bash "$tmp/probe.sh" gdc-identity-layout "$node" \
    | grep -E '^gdc-identity-layout=(v1|v2|none|unknown)$' | tail -n 1 | cut -d= -f2
}
reset_tree() { rm -rf "$tmp/srv"; mkdir -p "$tmp/srv/dai"; }
legacy_key() {
  mkdir -p "$tmp/srv/dai/$node/tmkms/secrets"
  printf '%s\n' "${1:-legacy-key}" >"$tmp/srv/dai/$node/tmkms/secrets/priv_validator_key.softsign"
}
stable_key() {
  mkdir -p "$tmp/srv/dai/signer/$node/tmkms/secrets"
  printf '%s\n' "${1:-legacy-key}" >"$tmp/srv/dai/signer/$node/tmkms/secrets/priv_validator_key.softsign"
}
p2p_marker() {
  mkdir -p "$tmp/srv/dai/identity/$node/p2p"
  printf '{"priv_key":{}}\n' >"$tmp/srv/dai/identity/$node/p2p/node_key.json"
}
expect() {
  local want="$1" got
  got="$(layout_of)"
  [[ "$got" == "$want" ]] || { echo "identity layout: expected $want, got $got" >&2; exit 1; }
}

# A Host that holds nothing is reset without a question.
reset_tree
expect none

# First generation: the only key lives below the deployment root reset removes.
reset_tree; legacy_key
expect v1

# Stable roots: the deployment root holds no key.
reset_tree; stable_key; p2p_marker
expect v2

# An interrupted migration leaves the p2p marker of the new layout while the
# only signing key is still the legacy one. The old probe answered v2 here and
# the reset removed that key.
reset_tree; legacy_key; p2p_marker
expect v1

# The same trap without any migration: an empty stable signer directory.
reset_tree; legacy_key; mkdir -p "$tmp/srv/dai/signer/$node/tmkms/secrets"
expect v1

# A finished migration may keep a byte-identical legacy copy; that Host is
# reset normally, because the live key is in the stable root.
reset_tree; legacy_key same-key; stable_key same-key; p2p_marker
expect v2

# Two different keys is not a migration anyone can reason about: refuse.
reset_tree; legacy_key one-key; stable_key other-key
expect v1

# Identity material with no key at all is not recognised, and must not be
# mistaken for an empty Host.
reset_tree; mkdir -p "$tmp/srv/dai/identity/$node"
expect unknown

printf 'PASS host identity layout is decided by the signing key, not by a directory\n'
