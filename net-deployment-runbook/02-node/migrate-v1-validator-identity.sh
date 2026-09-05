#!/usr/bin/env bash
# Read a verified v1 restore tree and materialize the stable v2 Host roots.
# The legacy source is deliberately retained; it is never moved or rewritten.
set -Eeuo pipefail
[[ $# -eq 1 && "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "Usage: sudo $0 NODE" >&2; exit 2; }
[[ $EUID -eq 0 || "${GDC_IDENTITY_LAYOUT_TEST_MODE:-false}" == true ]] || { echo 'Run with sudo' >&2; exit 1; }
node="$1"
root=/srv/dai
if [[ "${GDC_IDENTITY_LAYOUT_TEST_MODE:-false}" == true ]]; then
  root="${GDC_IDENTITY_LAYOUT_TEST_ROOT:-}"
  [[ "$root" =~ ^/tmp/gdc-identity-layout\.[A-Za-z0-9._-]+$ && -d "$root" ]] || { echo 'invalid identity layout test root' >&2; exit 2; }
fi
legacy="$root/$node"
identity="$root/identity/$node"
signer="$root/signer/$node"
for required in "$legacy/inference/config/node_key.json" "$legacy/tmkms/tmkms.toml" "$legacy/tmkms/secrets/priv_validator_key.softsign" "$legacy/tmkms/secrets/kms-identity.key" "$legacy/tmkms/state/priv_validator_state.json"; do
  [[ -s "$required" && ! -L "$required" ]] || { echo 'legacy validator identity is incomplete' >&2; exit 1; }
done
install -d -m 0755 "$root/identity" "$root/signer"
lock="$root/.gdc-identity-layout-$node.lock"; exec 9>"$lock"; flock -n 9 || { echo 'another identity layout migration is in progress' >&2; exit 1; }
if [[ -e "$identity" || -e "$signer" ]]; then
  [[ -s "$identity/p2p/node_key.json" && -d "$identity/warm/keyring-file" && -d "$signer/tmkms" ]] || { echo 'stable validator identity is partial or ambiguous' >&2; exit 1; }
  cmp -s "$legacy/inference/config/node_key.json" "$identity/p2p/node_key.json" || { echo 'stable P2P identity conflicts with legacy restore' >&2; exit 1; }
  diff -qr "$legacy/tmkms" "$signer/tmkms" >/dev/null || { echo 'stable signer identity conflicts with legacy restore' >&2; exit 1; }
  printf 'READY stable validator identity already matches v1 restore\n'; exit 0
fi
stage="$(mktemp -d "$root/.gdc-identity-layout-${node}.XXXXXX")"; trap 'rm -rf -- "$stage"' EXIT
install -d -m 0700 "$stage/identity/p2p" "$stage/identity/warm/keyring-file" "$stage/signer"
install -m 0600 "$legacy/inference/config/node_key.json" "$stage/identity/p2p/node_key.json"
cp -a "$legacy/tmkms" "$stage/signer/tmkms"
if [[ "${GDC_IDENTITY_LAYOUT_TEST_MODE:-false}" != true ]]; then chown -R root:root "$stage"; fi
find "$stage" -type d -exec chmod 0700 {} +; find "$stage" -type f -exec chmod 0600 {} +
mv "$stage/identity" "$identity"; mv "$stage/signer" "$signer"; trap - EXIT; rmdir "$stage"
printf 'READY migrated validator identity to stable layout v2\n'
