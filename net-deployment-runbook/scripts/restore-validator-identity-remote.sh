#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

acquire_lock() {
  local lock_dir="${1}.d" pid entries
  while ! mkdir -m 0700 -- "$lock_dir" 2>/dev/null; do
    [[ -d "$lock_dir" && ! -L "$lock_dir" && -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]] \
      || die 'validator identity lock is unsafe'
    pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      die 'another validator identity operation is in progress'
    fi
    entries="$(find "$lock_dir" -mindepth 1 -maxdepth 1 -printf . 2>/dev/null || true)"
    [[ "$entries" == . ]] || die 'validator identity lock is unsafe'
    rm -f -- "$lock_dir/pid"; rmdir -- "$lock_dir" 2>/dev/null || continue
  done
  printf '%s\n' "$$" >"$lock_dir/pid" || die 'could not initialize validator identity lock'
  lock_dir="$lock_dir"
}

release_lock() {
  [[ -n "${lock_dir:-}" && -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]] || return 0
  [[ "$(cat "$lock_dir/pid" 2>/dev/null || true)" == "$$" ]] || return 0
  rm -f -- "$lock_dir/pid"; rmdir -- "$lock_dir" 2>/dev/null || true
}

state="${1:-}"
candidate="${2:-}"
expected_consensus_key="${3:-}"
deployment_env="${4:-}"
if [[ "${GDC_VALIDATOR_IDENTITY_TEST_MODE:-false}" == true ]]; then
  [[ "$state" == /* && "$state" != / && "$candidate" == /* && "$candidate" != / \
    && "$deployment_env" == /* && "$deployment_env" != / ]] \
    || die 'validator identity restore requires absolute bounded paths'
else
  [[ "$state" == /srv/dai \
    && "$candidate" =~ ^/tmp/gdc-[A-Za-z0-9][A-Za-z0-9._-]*-validator-restore-[0-9]+$ \
    && "$deployment_env" == /srv/dai/deploy/.env ]] \
    || die 'validator identity restore paths are outside the managed Host scope'
fi
[[ "$expected_consensus_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || die 'validator identity restore requires a valid consensus public key'

derive_tmkms_public_key() (
  set -Eeuo pipefail
  local key_file="$1" work key_size prefix
  [[ -s "$key_file" ]] || die 'TMKMS softsign key is unavailable'
  command -v openssl >/dev/null 2>&1 \
    || die 'openssl is required to verify the TMKMS softsign key'
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  base64 -d "$key_file" >"$work/key.raw" 2>/dev/null \
    || die 'TMKMS softsign key is not valid base64'
  key_size="$(wc -c <"$work/key.raw" | tr -d ' ')"
  [[ "$key_size" == 32 || "$key_size" == 64 ]] \
    || die 'TMKMS softsign key must contain a 32-byte seed or 64-byte expanded key'
  head -c 32 "$work/key.raw" >"$work/seed.raw"
  printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20' \
    >"$work/key.der"
  cat "$work/seed.raw" >>"$work/key.der"
  openssl pkey -inform DER -in "$work/key.der" -pubout -outform DER \
    >"$work/public.der" 2>/dev/null \
    || die 'TMKMS softsign public key derivation failed'
  [[ "$(wc -c <"$work/public.der" | tr -d ' ')" == 44 ]] \
    || die 'derived TMKMS public key has an unexpected encoding'
  prefix="$(od -An -tx1 -N12 "$work/public.der" | tr -d ' \n')"
  [[ "$prefix" == 302a300506032b6570032100 ]] \
    || die 'derived TMKMS public key is not Ed25519'
  tail -c 32 "$work/public.der" | base64 | tr -d '\n'
  printf '\n'
)

lock="/run/lock/gdc-validator-identity-$(basename "$state").lock"
acquire_lock "$lock"
trap 'rm -rf -- "$candidate"; release_lock' EXIT

# The candidate was uploaded by the unprivileged SSH account. Take ownership
# of its root before inspecting descendants so another process under that
# account cannot replace a checked key before the privileged install.
[[ -d "$candidate" && ! -L "$candidate" ]] || die 'staged validator identity root is invalid'
chown root:root "$candidate"
chmod 0700 "$candidate"
chown -R root:root "$candidate"
if find "$candidate" -xdev \( -type l -o \( ! -type f ! -type d \) \) \
  -print -quit | grep -q .; then
  die 'staged validator identity contains a link or special file'
fi

remote_files=(
  "$state/tmkms/secrets/priv_validator_key.softsign"
  "$state/tmkms/secrets/kms-identity.key"
  "$state/inference/config/node_key.json"
)
candidate_files=(
  "$candidate/tmkms/secrets/priv_validator_key.softsign"
  "$candidate/tmkms/secrets/kms-identity.key"
  "$candidate/inference/config/node_key.json"
)
for path in "${candidate_files[@]}"; do
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] \
    || die 'staged validator identity is incomplete'
done
candidate_consensus_key="$(derive_tmkms_public_key "${candidate_files[0]}")"
[[ "$candidate_consensus_key" == "$expected_consensus_key" ]] \
  || die 'staged TMKMS key does not match the validator backup consensus identity'

present=0
for path in "${remote_files[@]}"; do
  [[ -s "$path" ]] && present=$((present + 1))
done

case "$present" in
  3)
    remote_consensus_key="$(derive_tmkms_public_key "${remote_files[0]}")"
    [[ "$remote_consensus_key" == "$expected_consensus_key" ]] \
      || die 'running TMKMS key does not match the validator backup consensus identity'
    for index in 0 1 2; do
      cmp -s "${candidate_files[$index]}" "${remote_files[$index]}" \
        || die 'running validator identity does not match the supplied backup'
    done
    if [[ -s "$deployment_env" ]]; then
      printf 'existing\n'
    else
      # Identity may have been installed by an interrupted earlier restore.
      # Without a deployment, resume the normal restore path rather than
      # misclassifying the Host as an already running validator.
      printf 'installed\n'
    fi
    ;;
  0)
    [[ ! -e "$state/tmkms" && ! -e "$state/inference/config/node_key.json" ]] \
      || die 'validator identity state is inaccessible or incomplete'
    install -d -m 0700 "$state/tmkms" "$state/inference/config"
    cp -a "$candidate/tmkms/." "$state/tmkms/"
    install -m 0600 "$candidate/inference/config/node_key.json" \
      "$state/inference/config/node_key.json"
    chown -R root:root "$state/tmkms" "$state/inference/config/node_key.json"
    printf 'installed\n'
    ;;
  *)
    die 'validator identity state is incomplete'
    ;;
esac
