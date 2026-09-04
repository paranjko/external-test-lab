#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

validate_paths() {
  local state="$1" candidate="$2" deployment_env="$3"
  if [[ "${GDC_VALIDATOR_IDENTITY_TEST_MODE:-false}" == true ]]; then
    [[ "$state" == /* && "$state" != / && "$candidate" == /* && "$candidate" != / \
      && "$deployment_env" == /* && "$deployment_env" != / ]] \
      || die 'validator identity restore requires absolute bounded paths'
  else
    [[ "$state" =~ ^/srv/dai/[A-Za-z0-9][A-Za-z0-9._-]*$ \
      && "$candidate" =~ ^/tmp/gdc-[A-Za-z0-9][A-Za-z0-9._-]*-validator-restore-[A-Za-z0-9]+$ \
      && "$deployment_env" == "/srv/dai/deploy/${state##*/}/.env" ]] \
      || die 'validator identity restore paths are outside the managed Host scope'
  fi
}

decode_canonical_base64() {
  local source_file="$1" output_file="$2" expected_size="$3" encoded canonical size
  base64 -d "$source_file" >"$output_file" 2>/dev/null \
    || die 'validator identity contains malformed key material'
  size="$(wc -c <"$output_file" | tr -d ' ')"
  [[ "$size" == "$expected_size" ]] \
    || die 'validator identity contains malformed key material'
  encoded="$(tr -d '\r\n' <"$source_file")"
  canonical="$(base64 <"$output_file" | tr -d '\n')"
  [[ "$encoded" == "$canonical" ]] \
    || die 'validator identity contains non-canonical key material'
}

validate_consensus_key() (
  set +x
  set -Eeuo pipefail
  local consensus_key="$1" work canonical
  [[ "$consensus_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || die 'validator backup contains an invalid consensus public key'
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  printf '%s' "$consensus_key" | base64 -d >"$work/key.raw" 2>/dev/null \
    || die 'validator backup contains an invalid consensus public key'
  [[ "$(wc -c <"$work/key.raw" | tr -d ' ')" == 32 ]] \
    || die 'validator backup consensus public key must contain 32 bytes'
  canonical="$(base64 <"$work/key.raw" | tr -d '\n')"
  [[ "$canonical" == "$consensus_key" ]] \
    || die 'validator backup contains a non-canonical consensus public key'
)

derive_ed25519_public_key() (
  set +x
  set -Eeuo pipefail
  local key_file="$1" work key_size prefix derived_public
  command -v openssl >/dev/null 2>&1 \
    || die 'openssl is required to verify the validator identity'
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  base64 -d "$key_file" >"$work/key.raw" 2>/dev/null \
    || die 'validator identity contains malformed Ed25519 key material'
  key_size="$(wc -c <"$work/key.raw" | tr -d ' ')"
  [[ "$key_size" == 32 || "$key_size" == 64 ]] \
    || die 'validator identity contains malformed Ed25519 key material'
  [[ "$(tr -d '\r\n' <"$key_file")" == "$(base64 <"$work/key.raw" | tr -d '\n')" ]] \
    || die 'validator identity contains non-canonical Ed25519 key material'
  head -c 32 "$work/key.raw" >"$work/seed.raw"
  printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20' \
    >"$work/key.der"
  command cat "$work/seed.raw" >>"$work/key.der"
  openssl pkey -inform DER -in "$work/key.der" -pubout -outform DER \
    >"$work/public.der" 2>/dev/null \
    || die 'validator identity Ed25519 public key derivation failed'
  [[ "$(wc -c <"$work/public.der" | tr -d ' ')" == 44 ]] \
    || die 'validator identity Ed25519 public key encoding is invalid'
  prefix="$(od -An -tx1 -N12 "$work/public.der" | tr -d ' \n')"
  [[ "$prefix" == 302a300506032b6570032100 ]] \
    || die 'validator identity key is not Ed25519'
  tail -c 32 "$work/public.der" >"$work/public.raw"
  if [[ "$key_size" == 64 ]]; then
    tail -c 32 "$work/key.raw" >"$work/expanded-public.raw"
    cmp -s "$work/expanded-public.raw" "$work/public.raw" \
      || die 'validator identity expanded Ed25519 key is inconsistent'
  fi
  derived_public="$(base64 <"$work/public.raw" | tr -d '\n')"
  printf '%s\n' "$derived_public"
)

identity_tree_digest() {
  local root="$1"
  (
    cd "$root"
    find . -xdev -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print $1}'
}

validate_candidate_shape() {
  local candidate="$1" relative
  [[ -d "$candidate" && ! -L "$candidate" ]] \
    || die 'staged validator identity root is invalid'
  if find "$candidate" -xdev \( -type l -o \( ! -type f ! -type d \) \) \
    -print -quit | grep -q .; then
    die 'staged validator identity contains a link or special file'
  fi
  while IFS= read -r -d '' relative; do
    relative="${relative#./}"
    case "$relative" in
      tmkms|tmkms/*|inference|inference/config|inference/config/node_key.json) ;;
      *) die 'staged validator identity contains an unexpected path' ;;
    esac
  done < <(cd "$candidate" && find . -xdev -mindepth 1 -print0)
}

validate_tmkms_state() {
  local state_file="$1"
  jq -e '
    type == "object"
    and (keys | sort) == ["block_id","height","round","step"]
    and (.height | type == "string" and test("^[0-9]+$"))
    and (.round | type == "string" and test("^[0-9]+$"))
    and (.step | type == "number" and . == floor and . >= -128 and . <= 127)
    and (.block_id == null or (
      (.block_id | type == "object")
      and (.block_id.hash | type == "string" and test("^[0-9A-Fa-f]{64}$"))
      and ((.block_id.parts // .block_id.part_set_header) as $parts
        | ($parts | type == "object")
        and ($parts.total | type == "number" and . == floor and . >= 0 and . <= 4294967295)
        and ($parts.hash | type == "string" and test("^[0-9A-Fa-f]{64}$")))
    ))
  ' "$state_file" >/dev/null 2>&1 \
    || die 'validator identity contains malformed TMKMS signing state'
}

validate_node_key() (
  set +x
  set -Eeuo pipefail
  local node_key="$1" work derived embedded
  jq -e '
    type == "object" and (keys == ["priv_key"])
    and (.priv_key | type == "object" and (keys | sort) == ["type","value"])
    and .priv_key.type == "tendermint/PrivKeyEd25519"
    and (.priv_key.value | type == "string")
  ' "$node_key" >/dev/null 2>&1 \
    || die 'validator identity contains a malformed P2P node key'
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  jq -er .priv_key.value "$node_key" >"$work/node-key.base64" 2>/dev/null \
    || die 'validator identity contains a malformed P2P node key'
  decode_canonical_base64 "$work/node-key.base64" "$work/node-key.raw" 64
  derived="$(derive_ed25519_public_key "$work/node-key.base64")"
  embedded="$(tail -c 32 "$work/node-key.raw" | base64 | tr -d '\n')"
  [[ "$derived" == "$embedded" ]] \
    || die 'validator identity P2P node key is cryptographically inconsistent'
)

validate_candidate_material() {
  local candidate="$1" expected_consensus_key="$2" work actual_consensus_key path
  local softsign="$candidate/tmkms/secrets/priv_validator_key.softsign"
  local kms_identity="$candidate/tmkms/secrets/kms-identity.key"
  local signing_state="$candidate/tmkms/state/priv_validator_state.json"
  local tmkms_config="$candidate/tmkms/tmkms.toml"
  local node_key="$candidate/inference/config/node_key.json"
  for path in "$softsign" "$kms_identity" "$signing_state" "$tmkms_config" "$node_key"; do
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] \
      || die 'staged validator identity is incomplete'
  done
  actual_consensus_key="$(derive_ed25519_public_key "$softsign")"
  [[ "$actual_consensus_key" == "$expected_consensus_key" ]] \
    || die 'staged TMKMS key does not match the validator backup consensus identity'
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' RETURN
  decode_canonical_base64 "$kms_identity" "$work/kms-identity.raw" 32
  validate_tmkms_state "$signing_state"
  validate_node_key "$node_key"
  if ! grep -Eq '^state_file[[:space:]]*=[[:space:]]*"/root/\.tmkms/state/priv_validator_state\.json"[[:space:]]*$' "$tmkms_config" \
    || ! grep -Eq '^path[[:space:]]*=[[:space:]]*"/root/\.tmkms/secrets/priv_validator_key\.softsign"[[:space:]]*$' "$tmkms_config" \
    || ! grep -Eq '^secret_key[[:space:]]*=[[:space:]]*"/root/\.tmkms/secrets/kms-identity\.key"[[:space:]]*$' "$tmkms_config"; then
    die 'validator identity contains a malformed TMKMS configuration'
  fi
  trap - RETURN
  rm -rf -- "$work"
}

validate_stable_material() {
  local identity="$1" signer="$2" expected_consensus_key="$3" work actual_consensus_key path
  local softsign="$signer/tmkms/secrets/priv_validator_key.softsign"
  local kms_identity="$signer/tmkms/secrets/kms-identity.key"
  local signing_state="$signer/tmkms/state/priv_validator_state.json"
  local tmkms_config="$signer/tmkms/tmkms.toml"
  local node_key="$identity/p2p/node_key.json"
  [[ -d "$identity" && ! -L "$identity" \
    && -d "$identity/p2p" && ! -L "$identity/p2p" \
    && -d "$identity/warm/keyring-file" && ! -L "$identity/warm/keyring-file" \
    && -d "$signer" && ! -L "$signer" \
    && -d "$signer/tmkms" && ! -L "$signer/tmkms" \
    && -d "$signer/tmkms/secrets" && ! -L "$signer/tmkms/secrets" \
    && -d "$signer/tmkms/state" && ! -L "$signer/tmkms/state" ]] \
    || die 'stable validator identity roots are partial or ambiguous'
  for path in "$softsign" "$kms_identity" "$signing_state" "$tmkms_config" "$node_key"; do
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] \
      || die 'stable validator identity roots are partial or ambiguous'
  done
  actual_consensus_key="$(derive_ed25519_public_key "$softsign")"
  [[ "$actual_consensus_key" == "$expected_consensus_key" ]] \
    || die 'stable validator identity conflicts with the supplied backup'
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' RETURN
  decode_canonical_base64 "$kms_identity" "$work/kms-identity.raw" 32
  validate_tmkms_state "$signing_state"
  validate_node_key "$node_key"
  if ! grep -Eq '^state_file[[:space:]]*=[[:space:]]*"/root/\.tmkms/state/priv_validator_state\.json"[[:space:]]*$' "$tmkms_config" \
    || ! grep -Eq '^path[[:space:]]*=[[:space:]]*"/root/\.tmkms/secrets/priv_validator_key\.softsign"[[:space:]]*$' "$tmkms_config" \
    || ! grep -Eq '^secret_key[[:space:]]*=[[:space:]]*"/root/\.tmkms/secrets/kms-identity\.key"[[:space:]]*$' "$tmkms_config"; then
    die 'stable validator identity contains a malformed TMKMS configuration'
  fi
  trap - RETURN
  rm -rf -- "$work"
}

remote_restore() {
  local state="$1" candidate="$2" expected_consensus_key="$3" deployment_env="$4"
  local expected_bundle_sha256="$5" lock marker transaction='' current_digest node stable_identity stable_signer
  validate_paths "$state" "$candidate" "$deployment_env"
  validate_consensus_key "$expected_consensus_key"
  [[ "$expected_bundle_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || die 'validator identity bundle digest is invalid'
  command -v flock >/dev/null 2>&1 \
    || die 'flock is required to protect validator identity restore'
  if [[ ! -e "${state%/*}" ]]; then
    install -d -m 0755 "${state%/*}"
  fi
  [[ -d "${state%/*}" && ! -L "${state%/*}" ]] \
    || die 'validator identity parent directory is invalid'
  lock="${state%/*}/.gdc-validator-identity-$(basename "$state").lock"
  exec 9>"$lock"
  flock -n 9 || die 'another validator identity operation is in progress'
  trap 'rm -rf -- "$candidate"; [[ -z "${transaction:-}" ]] || rm -rf -- "$transaction"' EXIT

  # Close the unprivileged upload race before inspecting any descendant.
  [[ -d "$candidate" && ! -L "$candidate" ]] \
    || die 'staged validator identity root is invalid'
  chown root:root "$candidate"
  chmod 0700 "$candidate"
  chown -R root:root "$candidate"
  validate_candidate_shape "$candidate"
  validate_candidate_material "$candidate" "$expected_consensus_key"
  current_digest="$(identity_tree_digest "$candidate")"
  [[ "$current_digest" == "$expected_bundle_sha256" ]] \
    || die 'staged validator identity does not match the validated backup bundle'

  node="$(basename "$state")"
  stable_identity="${state%/*}/identity/$node"
  stable_signer="${state%/*}/signer/$node"
  if [[ -e "$stable_identity" || -e "$stable_signer" ]]; then
    validate_stable_material "$stable_identity" "$stable_signer" "$expected_consensus_key"
    if ! cmp -s "$candidate/inference/config/node_key.json" "$stable_identity/p2p/node_key.json" \
      || ! cmp -s "$candidate/tmkms/secrets/priv_validator_key.softsign" \
        "$stable_signer/tmkms/secrets/priv_validator_key.softsign" \
      || ! cmp -s "$candidate/tmkms/secrets/kms-identity.key" \
        "$stable_signer/tmkms/secrets/kms-identity.key"; then
      die 'stable validator identity conflicts with the supplied backup'
    fi
    # The signing-state height advances after an archive is created. The
    # current, validated Host state wins and is never rolled back to backup.
    printf 'stable_existing\n'
    return 0
  fi

  marker="$state/.gdc-validator-identity-restore.sha256"
  if [[ -s "$deployment_env" ]]; then
    [[ -d "$state" && ! -L "$state" ]] \
      || die 'running validator identity state is inaccessible'
    validate_candidate_material "$state" "$expected_consensus_key"
    if ! cmp -s "$candidate/tmkms/secrets/priv_validator_key.softsign" \
      "$state/tmkms/secrets/priv_validator_key.softsign" \
      || ! cmp -s "$candidate/tmkms/secrets/kms-identity.key" \
        "$state/tmkms/secrets/kms-identity.key" \
      || ! cmp -s "$candidate/inference/config/node_key.json" \
        "$state/inference/config/node_key.json"; then
      die 'running validator identity does not match the supplied backup'
    fi
    printf 'existing\n'
    return 0
  fi

  if [[ -e "$state" ]]; then
    if [[ -f "$marker" && ! -L "$marker" \
      && "$(<"$marker")" == "$expected_bundle_sha256" ]]; then
      validate_candidate_material "$state" "$expected_consensus_key"
      if ! diff -qr "$candidate/tmkms" "$state/tmkms" >/dev/null 2>&1 \
        || ! cmp -s "$candidate/inference/config/node_key.json" \
          "$state/inference/config/node_key.json"; then
        die 'interrupted validator identity restore is inconsistent'
      fi
      printf 'installed\n'
      return 0
    fi
    if [[ -d "$state" && ! -L "$state" \
      && -z "$(find "$state" -xdev -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      rmdir "$state"
    else
      die 'validator identity state is partial, mixed, or ambiguous'
    fi
  fi

  transaction="$(mktemp -d "${state%/*}/.$(basename "$state").validator-restore.XXXXXX")"
  install -d -m 0700 "$transaction/inference/config"
  cp -a "$candidate/tmkms" "$transaction/tmkms"
  install -m 0600 "$candidate/inference/config/node_key.json" \
    "$transaction/inference/config/node_key.json"
  printf '%s\n' "$expected_bundle_sha256" \
    >"$transaction/.gdc-validator-identity-restore.sha256"
  chown -R root:root "$transaction"
  find "$transaction" -type d -exec chmod 0700 {} +
  find "$transaction" -type f -exec chmod 0600 {} +
  validate_candidate_material "$transaction" "$expected_consensus_key"
  if [[ "${GDC_VALIDATOR_IDENTITY_TEST_INTERRUPT:-}" == before-activate ]]; then
    die 'simulated validator identity interruption before atomic activation'
  fi
  mv "$transaction" "$state"
  transaction=''
  printf 'installed\n'
}

[[ $# == 5 ]] \
  || die 'usage: build-validator-identity-restore-command.sh STATE CANDIDATE CONSENSUS_KEY DEPLOYMENT_ENV BUNDLE_SHA256'

state="$1"
candidate="$2"
consensus_key="$3"
deployment_env="$4"
bundle_sha256="$5"

if [[ "${GDC_VALIDATOR_IDENTITY_REMOTE:-false}" == true ]]; then
  remote_restore "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"
  exit 0
fi

validate_paths "$state" "$candidate" "$deployment_env"
validate_consensus_key "$consensus_key"
[[ "$bundle_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || die 'validator identity bundle digest is invalid'

printf 'sudo env GDC_VALIDATOR_IDENTITY_REMOTE=true bash -s --'
printf ' %q' "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"
printf '\n'
