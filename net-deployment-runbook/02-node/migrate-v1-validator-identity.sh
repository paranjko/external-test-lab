#!/usr/bin/env bash
# Read a verified v1 restore tree and materialize the stable v2 Host roots.
# The legacy source is deliberately retained; it is never moved or rewritten.
set -Eeuo pipefail
gdc_lock_acquire() {
  local lock_dir="${1}.d" pid
  if ! mkdir -m 0700 -- "$lock_dir" 2>/dev/null; then
    [[ -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]] || return 1
    pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$pid" 2>/dev/null || return 1
    rm -f -- "$lock_dir/pid"; rmdir -- "$lock_dir" 2>/dev/null || return 1
    mkdir -m 0700 -- "$lock_dir" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" >"$lock_dir/pid" || { rmdir -- "$lock_dir" 2>/dev/null || true; return 1; }
  GDC_LOCK_DIR="$lock_dir"
}
gdc_lock_release() {
  local lock_dir="${1:-}"
  [[ -n "$lock_dir" && -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]] || return 0
  [[ "$(cat "$lock_dir/pid" 2>/dev/null || true)" == "$$" ]] || return 0
  rm -f -- "$lock_dir/pid"; rmdir -- "$lock_dir" 2>/dev/null || true
}
[[ $# -eq 1 && "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "Usage: sudo $0 NODE" >&2; exit 2; }
[[ $EUID -eq 0 || "${GDC_IDENTITY_LAYOUT_TEST_MODE:-false}" == true ]] || { echo 'Run with sudo' >&2; exit 1; }
node="$1"
root=/srv/dai
if [[ "${GDC_IDENTITY_LAYOUT_TEST_MODE:-false}" == true ]]; then
  root="${GDC_IDENTITY_LAYOUT_TEST_ROOT:-}"
  [[ "$root" =~ ^/tmp/gdc-identity-layout\.[A-Za-z0-9._-]+$ && -d "$root" ]] || { echo 'invalid identity layout test root' >&2; exit 2; }
fi
legacy="$root/$node"
identity="$root/identity"
signer="$root/signer"
for required in "$legacy/inference/config/node_key.json" "$legacy/tmkms/tmkms.toml" "$legacy/tmkms/secrets/priv_validator_key.softsign" "$legacy/tmkms/secrets/kms-identity.key" "$legacy/tmkms/state/priv_validator_state.json"; do
  [[ -s "$required" && ! -L "$required" ]] || { echo 'legacy validator identity is incomplete' >&2; exit 1; }
done
install -d -m 0755 "$root"
lock="$root/.gdc-identity-layout.lock"
gdc_lock_acquire "$lock" 0 'another identity layout migration is in progress' || { echo 'another identity layout migration is in progress' >&2; exit 1; }
lock_dir="$GDC_LOCK_DIR"
trap 'gdc_lock_release "${lock_dir:-}"' EXIT
if [[ -e "$identity/p2p/node_key.json" || -e "$signer/tmkms" ]]; then
  [[ -s "$identity/p2p/node_key.json" && -d "$identity/warm/keyring-file" && -d "$signer/tmkms" ]] || { echo 'stable validator identity is partial or ambiguous' >&2; exit 1; }
  cmp -s "$legacy/inference/config/node_key.json" "$identity/p2p/node_key.json" || { echo 'stable P2P identity conflicts with legacy restore' >&2; exit 1; }
  diff -qr "$legacy/tmkms" "$signer/tmkms" >/dev/null || { echo 'stable signer identity conflicts with legacy restore' >&2; exit 1; }
  printf 'READY stable validator identity already matches v1 restore\n'; exit 0
fi
stage="$(mktemp -d "$root/.gdc-identity-layout.XXXXXX")"; trap 'rm -rf -- "$stage"; gdc_lock_release "${lock_dir:-}"' EXIT
install -d -m 0700 "$stage/identity/p2p" "$stage/identity/warm/keyring-file" "$stage/signer"
install -m 0600 "$legacy/inference/config/node_key.json" "$stage/identity/p2p/node_key.json"
cp -a "$legacy/tmkms" "$stage/signer/tmkms"
if [[ "${GDC_IDENTITY_LAYOUT_TEST_MODE:-false}" != true ]]; then chown -R root:root "$stage"; fi
find "$stage" -type d -exec chmod 0700 {} +; find "$stage" -type f -exec chmod 0600 {} +
mv "$stage/identity" "$identity"; mv "$stage/signer" "$signer"; trap - EXIT; rmdir "$stage"; gdc_lock_release "$lock_dir"
printf 'READY migrated validator identity to stable layout v2\n'
