#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 KEY_NAME PASSWORD_FILE" >&2; exit 2; }
NAME="$1"; PASSWORD_FILE="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSWORD="$(<"$PASSWORD_FILE")"
ADDRESS="$(printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" keys show "$NAME" --keyring-backend file -a | tail -n1 | tr -d '\r')"
PUB_JSON="$(printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" keys show "$NAME" --keyring-backend file --pubkey)"
OUT="$ROOT/artifacts/accounts/$NAME.json"
mkdir -p "$(dirname "$OUT")"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]{20,90}$ ]] || {
  echo "Invalid address from keyring: $ADDRESS" >&2
  exit 1
}
KEY="$(jq -er .key <<<"$PUB_JSON")"
[[ "$(base64 -d <<<"$KEY" | wc -c)" -eq 33 ]] || {
  echo 'Expected a 33-byte secp256k1 public key' >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
jq -n --arg name "$NAME" --arg address "$ADDRESS" --arg key "$KEY" \
  '{name:$name,address:$address,account_pubkey_b64:$key}' >"$OUT"
echo "$OUT"
