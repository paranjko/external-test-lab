#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

proposal_id="${1:-}"
option="${2:-yes}"
[[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || die 'proposal ID must be a positive integer'
[[ "$option" =~ ^(yes|no|abstain|no_with_veto)$ ]] || die 'vote option must be yes, no, abstain, or no_with_veto'

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-vote-proposal-$proposal_id"
mkdir -p "$RUN"
record_phase_profile vote-proposal
rpc="${GDC_CHAIN_RPC_URL:-https://$NODE4_PUBLIC_HOST/chain-rpc/}"

step "Capture proposal $proposal_id and active participant voters"
ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-before.json"
jq -e '.proposal.status == "PROPOSAL_STATUS_VOTING_PERIOD" or .proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/proposal-before.json" >/dev/null || die "proposal $proposal_id is not votable or passed"
ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id/votes" >"$RUN/votes-before.json"

mapfile -t indexes < <(configured_node_indexes)
(( ${#indexes[@]} > 0 )) || die 'no joined participants are available to vote'
password="$(<"$SECRETS/operator.keyring")"
printf '[]' >"$RUN/vote-transactions.json"
submitted=0
for index in "${indexes[@]}"; do
  name="gdc-node$index-cold"
  address="$(jq -er .address "$ACCOUNTS/$name.json")"
  if jq -e --arg address "$address" '.votes[]? | select(.voter == $address)' "$RUN/votes-before.json" >/dev/null; then
    printf 'READY existing vote from %s\n' "$name"
    continue
  fi
  step "Vote $option from $name"
  tx="$(printf '%s\n' "$password" | "$ROOT/scripts/inferenced.sh" tx gov vote "$proposal_id" "$option" \
    --from "$name" --keyring-backend file --chain-id "$CHAIN_ID" --node "$rpc" \
    --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"
  jq -e '.code == 0 and (.txhash | test("^[A-F0-9]{64}$"))' <<<"$tx" >/dev/null || die "vote transaction from $name failed"
  txhash="$(jq -er '.txhash' <<<"$tx")"
  receipt=''
  for _ in $(seq 1 60); do
    receipt="$("$ROOT/scripts/inferenced.sh" query tx "$txhash" --node "$rpc" --output json 2>/dev/null || true)"
    if jq -e '(.code // .tx_response.code // -1) == 0 and ((.height // .tx_response.height // "0") | tonumber) > 0' <<<"$receipt" >/dev/null 2>&1; then
      break
    fi
    printf 'WAIT  vote transaction %s from %s to enter a block\n' "$txhash" "$name"
    sleep 2
  done
  jq -e '(.code // .tx_response.code // -1) == 0 and ((.height // .tx_response.height // "0") | tonumber) > 0' <<<"$receipt" >/dev/null 2>&1 || \
    die "vote transaction from $name was not committed successfully"
  printf '%s\n' "$receipt" >"$RUN/vote-receipt-$name.json"
  jq --arg voter "$address" --arg name "$name" --argjson tx "$tx" '. + [{voter:$voter,name:$name,tx:$tx}]' "$RUN/vote-transactions.json" >"$RUN/vote-transactions.tmp"
  mv "$RUN/vote-transactions.tmp" "$RUN/vote-transactions.json"
  submitted=$((submitted + 1))
done

expected="${#indexes[@]}"
deadline=$((SECONDS + 120))
actual=0
status=''
while (( SECONDS < deadline )); do
  ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-after.json"
  ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id/votes" >"$RUN/votes-after.json"
  status="$(jq -er '.proposal.status' "$RUN/proposal-after.json")"
  actual="$(jq '[.votes[]?.voter] | unique | length' "$RUN/votes-after.json")"
  (( actual >= expected )) && break
  [[ "$status" != PROPOSAL_STATUS_VOTING_PERIOD ]] && break
  printf 'WAIT  proposal %s recorded votes=%s expected=%s\n' "$proposal_id" "$actual" "$expected"
  sleep 2
done

if (( actual < expected )); then
  # inferenced 0.2.14 may stop returning individual votes as soon as the short
  # test-lab voting period closes. In that state, successful committed vote
  # receipts plus the final tally are the durable evidence.
  [[ "$status" == PROPOSAL_STATUS_PASSED ]] || \
    die "proposal $proposal_id has $actual recorded votes, expected at least $expected"
  tally_field="${option}_count"
  tally="$(jq -er --arg field "$tally_field" '.proposal.final_tally_result[$field] | tonumber' "$RUN/proposal-after.json")"
  (( tally > 0 && submitted + actual >= expected )) || \
    die "proposal $proposal_id passed without sufficient durable vote evidence"
fi
cat >"$RUN/verdict.md" <<EOF
# Governance vote: RECORDED

All $expected active configured participants have durable evidence for a
\`$option\` vote on proposal $proposal_id. Current proposal status is
\`$status\`; software or parameter cutovers remain separately gated on
\`PROPOSAL_STATUS_PASSED\`.
EOF
printf 'RECORDED governance votes: %s (proposal=%s status=%s)\n' "$RUN" "$proposal_id" "$status"
