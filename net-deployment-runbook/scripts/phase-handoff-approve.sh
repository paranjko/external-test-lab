#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
NODE="$(node_name "${1:-}")"
REQUEST="${2:-}"
[[ -s "$REQUEST" ]] || die "missing activation request: $REQUEST"
[[ -s "$SECRETS/operator.keyring" ]] || die 'coordinator operator key is required for activation'
jq -e --arg node "$NODE" --arg chain "$CHAIN_ID" \
  '.schema == "gonka-devnet-community-node-handoff-v2"
   and .node == $node
   and .chain_id == $chain
   and (.cold_address | test("^gonka1[0-9a-z]+$"))
   and .identity.node_name == $node
   and (.identity.consensus_pubkey | type == "string" and length > 0)
   and (.identity.warm_address | test("^gonka1[0-9a-z]+$"))' \
  "$REQUEST" >/dev/null || die 'activation request has an unexpected schema, node or chain ID'
ADDRESS="$(jq -r .cold_address "$REQUEST")"
step "Confirm $NODE registration on chain"
"$ROOT/03-join/wait-registered.sh" "https://$NODE0_PUBLIC_HOST" "$ADDRESS"
participant="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant/$ADDRESS")"
jq -e --arg address "$ADDRESS" --arg validator_key "$(jq -r .identity.consensus_pubkey "$REQUEST")" \
  '.participant.address == $address and .participant.validator_key == $validator_key' \
  <<<"$participant" >/dev/null || die 'registered participant does not match the activation request address and consensus key'

spendable="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/spendable_balances/$ADDRESS")"
spendable_ngonka="$(jq -r '[.balances[]? | select(.denom == "ngonka") | (.amount | tonumber)] | add // 0' <<<"$spendable")"
[[ "$spendable_ngonka" =~ ^[0-9]+$ ]] || die 'cannot determine participant spendable balance'
if (( spendable_ngonka == 0 )); then
  account_tmp="$(mktemp)"
  trap 'rm -f "$account_tmp"' EXIT
  jq -n --arg address "$ADDRESS" '{address:$address}' >"$account_tmp"
  step "Fund the registered $NODE address"
  "$ROOT/03-join/fund-account.sh" "$account_tmp" "$INVENTORY"
else
  printf 'READY %s already has %sngonka spendable; skip duplicate funding\n' "$NODE" "$spendable_ngonka"
fi

APPROVAL_DIR="$ROOT/artifacts/operator-approvals"
APPROVAL="$APPROVAL_DIR/$NODE.json"
install -d -m 0700 "$APPROVAL_DIR"
jq -n --arg schema gonka-devnet-community-node-approval-v2 \
  --arg node "$NODE" --arg chain_id "$CHAIN_ID" --arg address "$ADDRESS" \
  --arg approved_at "$(date -u +%FT%TZ)" \
  '{schema:$schema,node:$node,chain_id:$chain_id,cold_address:$address,approved_at:$approved_at}' >"$APPROVAL"
chmod 600 "$APPROVAL"
printf '\nREADY %s funded. The operator now reruns the same join command and signs the ML permission with the operator-owned cold key.\nApproval receipt: %s\n' "$NODE" "$APPROVAL"
