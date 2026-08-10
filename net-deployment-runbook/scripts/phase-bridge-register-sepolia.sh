#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-bridge-register-sepolia"
mkdir -p "$RUN"
install_evidence_exit_trap 'Sepolia bridge governance registration'
record_phase_profile bridge-register-sepolia

contract="${GDC_SEPOLIA_CONTRACT:-}"
[[ "$contract" =~ ^0x[[:xdigit:]]{40}$ ]] || die 'GDC_SEPOLIA_CONTRACT must be a 20-byte Ethereum address'
rpc="${GDC_CHAIN_RPC_URL:-https://$PUBLIC_EDGE_HOST/chain-rpc/}"
authority="${GDC_INFERENCE_GOV_AUTHORITY:-gonka10d07y265gmmuvt4z0w9aw880jnsr700j2h5m33}"
[[ "$authority" =~ ^gonka1[0-9a-z]{20,90}$ ]] || die 'GDC_INFERENCE_GOV_AUTHORITY is invalid'
chain_name="${GDC_SEPOLIA_CHAIN_NAME:-sepolia}"
[[ "$chain_name" == sepolia ]] || die 'GDC_SEPOLIA_CHAIN_NAME must be sepolia'

step 'Verify the contract is the current deployment candidate'
printf '%s\n' "$contract" >"$RUN/contract-address.txt"
curl -fsS "https://$GENESIS_PUBLIC_HOST/v1/bridge/addresses?chain=sepolia" >"$RUN/bridge-addresses-before.json" || true
if jq -e --arg address "$contract" '[.. | objects | .address? // empty] | index($address) != null' "$RUN/bridge-addresses-before.json" >/dev/null 2>&1; then
  cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge governance registration: PASS

Contract $contract is already present in the live bridge address state for
chain name $chain_name. No duplicate proposal was submitted.
EOF
  printf 'PASS bridge registration already effective: %s\n' "$RUN"
  exit 0
fi

step 'Read the live governance deposit minimum'
ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/params/deposit' >"$RUN/gov-params.json"
min_deposit="$(jq -er '(.params.min_deposit // .deposit_params.min_deposit)[0] | .amount + .denom' "$RUN/gov-params.json")"
deposit="${GDC_BRIDGE_GOVERNANCE_DEPOSIT:-$min_deposit}"
[[ "$deposit" =~ ^[1-9][0-9]*ngonka$ ]] || die 'GDC_BRIDGE_GOVERNANCE_DEPOSIT must be a positive ngonka amount'
(( ${deposit%ngonka} >= ${min_deposit%ngonka} )) || die "bridge governance deposit $deposit is below live minimum $min_deposit"

step 'Render the Genesis-specific bridge registration proposal'
jq -n --arg authority "$authority" --arg chain "$chain_name" --arg address "$contract" --arg deposit "$deposit" \
  '{messages:[{"@type":"/inference.inference.MsgRegisterBridgeAddresses",authority:$authority,chainName:$chain,addresses:[$address]}],metadata:"",title:"GDC: Register Sepolia bridge",deposit:$deposit,summary:"Register the Genesis-specific Sepolia BridgeContract for the Community DevNet."}' \
  >"$RUN/proposal.json"
jq -e --arg address "$contract" --arg authority "$authority" \
  '.messages | length == 1 and .[0].authority == $authority and .[0].chainName == "sepolia" and .[0].addresses == [$address]' \
  "$RUN/proposal.json" >/dev/null

proposal_id="${GDC_BRIDGE_GOVERNANCE_PROPOSAL_ID:-}"
if [[ -z "$proposal_id" && "${GDC_BRIDGE_GOVERNANCE_SUBMIT:-false}" == true ]]; then
  password="$(<"$SECRETS/operator.keyring")"
  proposal_in_container="$(inferenced_runs_path "$RUN/proposal.json")"
  tx="$(printf '%s\n' "$password" | "$ROOT/scripts/inferenced.sh" tx gov submit-proposal "$proposal_in_container" \
    --from "$GENESIS_NODE-cold" --keyring-backend file --chain-id "$CHAIN_ID" --node "$rpc" \
    --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"
  printf '%s\n' "$tx" >"$RUN/submit-tx.json"
  txhash="$(jq -er '.txhash // .tx_response.txhash' "$RUN/submit-tx.json")"
  for _ in $(seq 1 60); do
    result="$("$ROOT/scripts/inferenced.sh" query tx "$txhash" --node "$rpc" --output json 2>/dev/null || true)"
    proposal_id="$(jq -r '[..|objects|select(.key? == "proposal_id")|.value][0] // empty' <<<"$result")"
    [[ "$proposal_id" =~ ^[0-9]+$ ]] && break
    sleep 2
  done
fi

if [[ ! "$proposal_id" =~ ^[0-9]+$ ]]; then
  cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge governance registration: BLOCKED

The secret-safe proposal is rendered at proposal.json. Set
GDC_BRIDGE_GOVERNANCE_SUBMIT=true to submit it, or provide
GDC_BRIDGE_GOVERNANCE_PROPOSAL_ID to verify an existing proposal.
EOF
  printf 'BLOCKED bridge registration evidence: %s\n' "$RUN"
  exit 3
fi

printf '%s\n' "$proposal_id" >"$RUN/proposal-id.txt"
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-status.json"
status="$(jq -er '.proposal.status' "$RUN/proposal-status.json")"
if [[ "$status" != PROPOSAL_STATUS_PASSED ]]; then
  cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge governance registration: BLOCKED

Proposal $proposal_id is $status. The bridge runtime remains gated.
EOF
  exit 3
fi

curl -fsS "https://$GENESIS_PUBLIC_HOST/v1/bridge/addresses?chain=sepolia" >"$RUN/bridge-addresses-after.json"
jq -e --arg address "$contract" '[.. | objects | .address? // empty] | index($address) != null' "$RUN/bridge-addresses-after.json" >/dev/null || die 'passed proposal did not expose the contract in live bridge state'
cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge governance registration: PASS

Proposal $proposal_id passed and live bridge state contains $contract for
chain name $chain_name.
EOF
printf 'PASS bridge registration evidence: %s\n' "$RUN"
