#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

[[ -s "$SECRETS/operator.keyring" ]] || die 'Genesis operator keyring is required to prepare the faucet signer'
mnemonic="$GDC_HOME/mnemonics/gdc-faucet-cold.mnemonic"
[[ -s "$mnemonic" ]] || die 'faucet mnemonic is missing; rerun genesis identities before starting the faucet'
password="$(<"$SECRETS/operator.keyring")"
signer_home="$STATE/faucet-signer-home"
rm -rf "$signer_home"
mkdir -p "$signer_home"

GDC_OPERATOR_HOME="$signer_home" "$ROOT/scripts/inferenced.sh" init faucet --chain-id "$CHAIN_ID" --default-denom "$BASE_DENOM" --overwrite >/dev/null 2>&1
if ! printf '%s\n%s\n%s\n' "$(<"$mnemonic")" "$password" "$password" \
  | GDC_OPERATOR_HOME="$signer_home" "$ROOT/scripts/inferenced.sh" keys add gdc-faucet-cold --recover --keyring-backend file >/dev/null 2>&1; then
  die 'failed to import the dedicated faucet key into its isolated signer home'
fi
address="$(printf '%s\n' "$password" | GDC_OPERATOR_HOME="$signer_home" "$ROOT/scripts/inferenced.sh" keys show gdc-faucet-cold --keyring-backend file -a)"
expected="$(jq -er .address "$ACCOUNTS/gdc-faucet-cold.json")"
[[ "$address" == "$expected" ]] || die 'isolated faucet signer address differs from the funded Genesis faucet account'
printf '%s\n' "$signer_home"
