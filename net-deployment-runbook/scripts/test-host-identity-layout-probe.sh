#!/usr/bin/env bash
# The linked-GPU-host probe never migrates identity. It recognizes only the
# flat layout; any legacy or incomplete material is conservatively unknown.
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
legacy_identity() {
  mkdir -p "$tmp/srv/dai/signer/$node/tmkms/secrets"
  printf '%s\n' "${1:-legacy-key}" >"$tmp/srv/dai/signer/$node/tmkms/secrets/priv_validator_key.softsign"
}
stable_key() {
  mkdir -p "$tmp/srv/dai/signer/tmkms/secrets"
  printf '%s\n' "${1:-legacy-key}" >"$tmp/srv/dai/signer/tmkms/secrets/priv_validator_key.softsign"
}
p2p_marker() {
  mkdir -p "$tmp/srv/dai/identity/p2p"
  printf '{"priv_key":{}}\n' >"$tmp/srv/dai/identity/p2p/node_key.json"
}
expect() {
  local want="$1" got
  got="$(layout_of)"
  [[ "$got" == "$want" ]] || { echo "identity layout: expected $want, got $got" >&2; exit 1; }
}

# A Host that holds nothing is reset without a question.
reset_tree
expect none

# Stable roots: the deployment root holds no key.
reset_tree; stable_key; p2p_marker
expect v2

# Legacy identity is not a linked GPU Host. This probe has no ownership to
# normalize it, so it refuses a linked reset through the unknown verdict.
reset_tree; legacy_identity
expect unknown

# A direct flat marker is still nonempty. The caller refuses any result other
# than `none`, so this cannot authorize a linked GPU reset.
reset_tree; legacy_identity; p2p_marker
expect v2

# A flat signer is authoritative even if another stale directory exists.
reset_tree; legacy_identity same-key; stable_key same-key; p2p_marker
expect v2

# A flat signer remains a stable layout. The owning Host reset reader applies
# the stronger mixed-layout refusal before it archives a validator.
reset_tree; legacy_identity one-key; stable_key other-key
expect v2

# Identity material with no key at all is not recognised, and must not be
# mistaken for an empty Host.
reset_tree; mkdir -p "$tmp/srv/dai/identity"
expect unknown

printf 'PASS linked GPU identity probe accepts only flat or empty layout\n'
