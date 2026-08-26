#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

key_file="${1:-}"
[[ -s "$key_file" ]] || die 'TMKMS softsign key is unavailable'
command -v openssl >/dev/null 2>&1 || die 'openssl is required to verify the TMKMS softsign key'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if ! base64 -d "$key_file" >"$work/key.raw" 2>/dev/null; then
  die 'TMKMS softsign key is not valid base64'
fi
key_size="$(wc -c <"$work/key.raw" | tr -d ' ')"
[[ "$key_size" == 32 || "$key_size" == 64 ]] \
  || die 'TMKMS softsign key must contain a 32-byte seed or 64-byte expanded key'
head -c 32 "$work/key.raw" >"$work/seed.raw"

# RFC 8410 PKCS#8 wrapper for a raw Ed25519 seed. OpenSSL then derives the
# public key without exposing private material in command arguments or output.
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
