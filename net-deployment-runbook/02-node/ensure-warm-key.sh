#!/usr/bin/env bash
# Bind the operator's already verified warm identity to the promoted data
# generation. Identity bootstrap uses a temporary data location before the
# signerless state-sync candidate exists, so its file keyring is deliberately
# not an input to promotion.
set -Eeuo pipefail

usage() { echo "Usage: $0 --expected-address GONKA_ADDRESS" >&2; }
expected_address=''
while (($#)); do
  case "$1" in
    --expected-address) expected_address="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$expected_address" =~ ^gonka1[0-9a-z]{20,90}$ ]] || { usage; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -s "$HERE/.env" ]] || { echo "missing deployment environment" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$HERE/.env"
set +a
[[ -n "${KEY_NAME:-}" && -n "${KEYRING_PASSWORD:-}" ]] || {
  echo 'deployment environment lacks warm-key configuration' >&2
  exit 1
}

# The mnemonic is accepted only on standard input. It never becomes a remote
# file or command argument, and the temporary copy is removed even when the
# container command fails.
umask 077
mnemonic="$(mktemp "$HERE/.warm-key.XXXXXX")"
trap 'rm -f "$mnemonic"' EXIT
cat >"$mnemonic"
[[ -s "$mnemonic" ]] || { echo 'warm mnemonic input is empty' >&2; exit 2; }

compose=(docker compose --env-file "$HERE/.env" -f "$HERE/compose.yaml")
show_address() {
  "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
    'printf "%s\\n" "$KEYRING_PASSWORD" | inferenced keys show "$KEY_NAME" --keyring-backend file -a' \
    2>/dev/null | tail -n1 | tr -d '\r'
}

actual_address="$(show_address || true)"
if [[ -z "$actual_address" ]]; then
  key_output="$(mktemp "$HERE/.warm-key-import.XXXXXX")"
  trap 'rm -f "$mnemonic" "$key_output"' EXIT
  if ! printf '%s\n%s\n%s\n' "$(<"$mnemonic")" "$KEYRING_PASSWORD" "$KEYRING_PASSWORD" \
    | "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
        'inferenced keys add "$KEY_NAME" --recover --keyring-backend file' \
        >"$key_output" 2>&1; then
    if grep -qiE 'mnemonic|recovery phrase|bip39' "$key_output"; then
      echo 'cannot restore promoted warm key: mnemonic_rejected' >&2
    elif grep -qiE 'passphrase|password|keyring' "$key_output"; then
      echo 'cannot restore promoted warm key: keyring_authentication_failed' >&2
    else
      echo 'cannot restore promoted warm key: inferenced_rejected_recovery' >&2
    fi
    exit 1
  fi
  actual_address="$(show_address || true)"
fi

[[ "$actual_address" == "$expected_address" ]] || {
  echo 'promoted warm key does not match the restored public identity' >&2
  exit 1
}
printf 'READY promoted warm key matches restored identity\n'
