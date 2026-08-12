#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile identities

MNEMONICS="$GDC_HOME/mnemonics"
step 'Local secrets and account backups'
"$ROOT/scripts/make-secrets.sh" "$SECRETS" "$GENESIS_NODE"
step 'Cold accounts for Genesis participant, gateway, and public faucet'
"$ROOT/01-identities-genesis/create-cold-accounts.sh" "$SECRETS/operator.keyring" "$GENESIS_NODE" gdc-gateway gdc-faucet
step 'Genesis participant identity'
"$ROOT/01-identities-genesis/collect-identities.sh" "$INVENTORY" "$SECRETS" "$IDENTITIES" "$MNEMONICS" "$GENESIS_NODE" \
  || die 'the Genesis participant identity could not be created'
printf 'BACKUP  %s mnemonic files and %s cold-address references in %s\n' \
  "$(find "$MNEMONICS" -maxdepth 1 -type f -name '*.mnemonic' | wc -l)" \
  "$(find "$MNEMONICS" -maxdepth 1 -type f -name '*-cold.address' | wc -l)" "$MNEMONICS"
