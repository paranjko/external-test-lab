#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
source "$ROOT/scripts/same-host-restore.sh"
machine="$(printf '%064d' 1)"; key="$(printf '%064d' 2)"
jq -cn --arg machine "$machine" --arg key "$key" '{schema_version:1,kind:"gdc-same-host-reset",machine_sha256:$machine,
  key_sha256:$key,chain_id:"fixture-chain",signer_stopped:true,signing_state:{height:"42",round:"0",step:0,block_id:null}}' >"$tmp/reset.json"
validate_reset_binding "$tmp/reset.json" "$machine" "$key" fixture-chain
! validate_reset_binding "$tmp/reset.json" other-machine "$key" fixture-chain
! validate_reset_binding "$tmp/reset.json" "$machine" other-key fixture-chain
! validate_reset_binding "$tmp/reset.json" "$machine" "$key" other-chain
jq '.signer_stopped=false' "$tmp/reset.json" >"$tmp/not-stopped.json"
! validate_reset_binding "$tmp/not-stopped.json" "$machine" "$key" fixture-chain
export RESTORE_TEST_DIR="$tmp"
jq -cn '{consensus_pubkey:"fixture-key"}' >"$tmp/identity.json"
printf '{"height":"10","round":"0","step":0,"block_id":null}\n' >"$tmp/current-state"
ssh() {
  local alias="${*: -2:1}" operation="${*: -1}"
  [[ "$alias" == fixture-validator ]] || exit 99
  case "$operation" in
    *'--remote bind'*) cat >/dev/null; cat "$RESTORE_TEST_DIR/reset.json" ;;
    *'sudo -n cat'*priv_validator_state.json*) cat "$RESTORE_TEST_DIR/current-state" ;;
    *'sudo -n tee'*priv_validator_state.json*) cat >"$RESTORE_TEST_DIR/current-state" ;;
    *'sudo -n bash -s -- '*priv_validator_key.softsign*) cat >/dev/null; printf 'fixture-key\n' ;;
    *) printf 'unexpected mock SSH: %s\n' "$operation" >&2; exit 99 ;;
  esac
}
export -f ssh
bash "$ROOT/scripts/same-host-restore.sh" bind fixture-validator "$tmp/identity.json" fixture-chain "$tmp/bound.json"
jq -e '.height=="42"' "$tmp/current-state" >/dev/null
printf '{"height":"50","round":"0","step":0,"block_id":null}\n' >"$tmp/current-state"
bash "$ROOT/scripts/same-host-restore.sh" bind fixture-validator "$tmp/identity.json" fixture-chain "$tmp/bound2.json"
jq -e '.height=="50"' "$tmp/current-state" >/dev/null
printf 'PASS reset binds machine/key/chain; restore preserves the highest signing minimum (SSH mocked)\n'
