#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/validator-backup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
GDC_HOME="$tmp/operator"; GDC_DATA_ROOT="$tmp/data"
IDENTITIES="$tmp/identities"; ACCOUNTS="$tmp/accounts"; GENESIS="$tmp/genesis"
mkdir -p "$GDC_HOME/mnemonics" "$GDC_DATA_ROOT" "$IDENTITIES" "$ACCOUNTS" "$GENESIS"
printf 'fixture\n' >"$GDC_HOME/mnemonics/fixture-cold.mnemonic"
printf 'fixture\n' >"$GDC_HOME/mnemonics/fixture-warm.mnemonic"
printf '{}\n' >"$IDENTITIES/fixture.json"
printf '{}\n' >"$ACCOUNTS/fixture-cold.json"
printf '{"chain_id":"fixture"}\n' >"$GENESIS/genesis.json"
node_ml_host() { :; }
ssh() {
  printf '%s\n' "$*" >>"$tmp/ssh.log"
  [[ $# == 3 && "$1" == -T && "$2" == fixture && "$3" == "sudo test -s '/srv/dai/identity/p2p/node_key.json' && sudo test -d '/srv/dai/identity/warm/keyring-file' && sudo test -d '/srv/dai/signer/tmkms'" ]] || {
    printf 'unexpected SSH operation\n' >"$tmp/unexpected"
    return 97
  }
  return 1
}
if create_backup fixture >"$tmp/out" 2>&1; then
  echo 'backup unexpectedly accepted missing canonical identity roots' >&2; exit 1
fi
grep -Fq 'canonical identity roots are required; legacy layouts are unsupported' "$tmp/out"
[[ "$(wc -l <"$tmp/ssh.log")" == 1 && ! -e "$tmp/unexpected" ]]
[[ -z "$(find "$GDC_DATA_ROOT" -type f -print -quit)" ]]
[[ ! -e "$ROOT/02-node/migrate-v1-validator-identity.sh" ]]
printf 'PASS backup refuses noncanonical identity without migration or archive creation\n'
