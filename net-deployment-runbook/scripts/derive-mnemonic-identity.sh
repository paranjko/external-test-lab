#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ $# == 4 || $# == 5 ]] \
  || { echo 'usage: derive-mnemonic-identity.sh MNEMONIC_FILE PASSWORD_FILE KEY_NAME EXPECTED_ADDRESS [EXPECTED_PUBKEY]' >&2; exit 2; }
MNEMONIC_FILE="$1"
PASSWORD_FILE="$2"
KEY_NAME="$3"
EXPECTED_ADDRESS="$4"
EXPECTED_PUBKEY="${5:-}"
[[ -s "$MNEMONIC_FILE" && -r "$MNEMONIC_FILE" ]] \
  || { echo 'recovery mnemonic is not readable' >&2; exit 2; }
[[ -s "$PASSWORD_FILE" && -r "$PASSWORD_FILE" ]] \
  || { echo 'recovery keyring password is not readable' >&2; exit 2; }
[[ "$KEY_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || { echo 'recovery key name is invalid' >&2; exit 2; }
[[ "$EXPECTED_ADDRESS" =~ ^gonka1[0-9a-z]{20,90}$ ]] \
  || { echo 'expected recovery account address is invalid' >&2; exit 2; }

check_home="$(mktemp -d)"
trap 'rm -rf "$check_home"' EXIT
password="$(<"$PASSWORD_FILE")"
output="$check_home/recover.out"

run_inferenced() {
  if [[ -n "${GDC_RECOVERY_INFERENCED_BIN:-}" ]]; then
    [[ "$GDC_RECOVERY_INFERENCED_BIN" == /* && -x "$GDC_RECOVERY_INFERENCED_BIN" ]] \
      || { echo 'recovery inferenced CLI is unavailable' >&2; return 1; }
    "$GDC_RECOVERY_INFERENCED_BIN" --home "$check_home/keyring" "$@"
  else
    GDC_OPERATOR_HOME="$check_home/keyring" "$ROOT/scripts/inferenced.sh" "$@"
  fi
}

if ! printf '%s\n%s\n%s\n' "$(<"$MNEMONIC_FILE")" "$password" "$password" \
  | run_inferenced keys add "$KEY_NAME" --recover --keyring-backend file >"$output" 2>&1; then
  echo 'recovery mnemonic cannot be imported in an isolated keyring' >&2
  exit 1
fi
address="$(printf '%s\n' "$password" \
  | run_inferenced keys show "$KEY_NAME" --keyring-backend file -a | tail -n1 | tr -d '\r')"
pubkey_json="$(printf '%s\n' "$password" \
  | run_inferenced keys show "$KEY_NAME" --keyring-backend file --pubkey)"
pubkey="$(jq -er .key <<<"$pubkey_json")"
[[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] \
  || { echo 'recovery mnemonic produced an invalid account address' >&2; exit 1; }
[[ "$(base64 -d <<<"$pubkey" | wc -c)" -eq 33 ]] \
  || { echo 'recovery mnemonic produced an invalid account public key' >&2; exit 1; }
[[ "$address" == "$EXPECTED_ADDRESS" ]] \
  || { echo 'recovery mnemonic controls another account address' >&2; exit 1; }
[[ -z "$EXPECTED_PUBKEY" || "$pubkey" == "$EXPECTED_PUBKEY" ]] \
  || { echo 'recovery mnemonic controls another account public key' >&2; exit 1; }
jq -n --arg address "$address" --arg pubkey "$pubkey" '{address:$address,pubkey:$pubkey}'
