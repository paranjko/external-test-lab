#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

proposal_id="${1:-}"
option="${2:-yes}"
[[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || die 'proposal ID must be a positive integer'
[[ "$option" =~ ^(yes|no|abstain|no_with_veto)$ ]] || die 'vote option must be yes, no, abstain, or no_with_veto'
case "$option" in
  yes) option_constant=VOTE_OPTION_YES ;;
  no) option_constant=VOTE_OPTION_NO ;;
  abstain) option_constant=VOTE_OPTION_ABSTAIN ;;
  no_with_veto) option_constant=VOTE_OPTION_NO_WITH_VETO ;;
esac

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-vote-proposal-$proposal_id"
mkdir -p "$RUN"
install_evidence_exit_trap 'Governance vote'
record_phase_profile vote-proposal
rpc="${GDC_CHAIN_RPC_URL:-https://$PUBLIC_EDGE_HOST/chain-rpc/}"

step "Capture proposal $proposal_id and active participant voters"
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-before.json"
jq -e '.proposal.status == "PROPOSAL_STATUS_VOTING_PERIOD" or .proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/proposal-before.json" >/dev/null || die "proposal $proposal_id is not votable or passed"
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id/votes" >"$RUN/votes-before.json"

proposal_status="$(jq -er '.proposal.status' "$RUN/proposal-before.json")"
proposal_metadata="$(jq -er '.proposal.metadata // ""' "$RUN/proposal-before.json")"
devshard_update=false
if jq -e '
  any(.proposal.messages[]?;
    .["@type"] == "/inference.inference.MsgUpdateParams")
' "$RUN/proposal-before.json" >/dev/null; then
  devshard_update=true
fi
if [[ "$devshard_update" == true ]]; then
  [[ "$proposal_metadata" == gdc-devshard-v1:* ]] \
    || die "proposal $proposal_id changes DevShard parameters without state-binding metadata"
  metadata_pattern='^gdc-devshard-v1:mutable=(none|v5);before-sha256=([0-9a-f]{64});message-sha256=([0-9a-f]{64})$'
  [[ "$proposal_metadata" =~ $metadata_pattern ]] \
    || die "proposal $proposal_id has malformed DevShard state-binding metadata"
  metadata_before_hash="${BASH_REMATCH[2]}"
  mutable_protocol=none
  expected_v5_url=-
  expected_v5_sha256=-
  if [[ -n "${GDC_COMPOSITION:-}" && "${LAB_CANDIDATE:-false}" == true ]]; then
    [[ "${GDC_COMPOSITION_HASH:-}" =~ ^[0-9a-f]{64}$ \
      && "${CANDIDATE_DEVSHARD_PROTOCOL_VERSION:-}" == v5 \
      && "${DEVSHARD_PROTOCOL_VERSION:-}" == v5 ]] \
      || die 'DevShard tuple replacement vote requires a verified v5 candidate composition'
    mutable_protocol=v5
    expected_v5_url="$DEVSHARD_V5_URL"
    expected_v5_sha256="$DEVSHARD_V5_SHA256"
  fi
  params_url="${GDC_CHAIN_API_URL:-https://${PUBLIC_EDGE_HOST}/chain-api}"
  params_url="${params_url%/}/productscience/inference/inference/params"
  stderr_file="$RUN/params-pre-vote.curl.stderr"
  set +e
  http_status="$(curl -sS --connect-timeout 5 --max-time 30 -o "$RUN/params-pre-vote.json" \
    -w '%{http_code}' "$params_url" 2>"$stderr_file")"
  curl_exit=$?
  set -e
  if (( curl_exit != 0 )) || [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    error_detail="$(tr '\n' ' ' <"$stderr_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | cut -c1-240)"
    die "cannot verify DevShard proposal freshness before voting (url=$params_url http_status=${http_status:-000} curl_exit=$curl_exit curl_status=$(curl_exit_status "$curl_exit")${error_detail:+ detail=$error_detail})"
  fi
  if [[ "$proposal_status" == PROPOSAL_STATUS_PASSED ]]; then
    verification_mode=after
  else
    verification_mode=before
  fi
  "$ROOT/scripts/verify-devshard-governance-snapshot.sh" "$verification_mode" \
    "$RUN/proposal-before.json" "$RUN/params-pre-vote.json" "$mutable_protocol" \
    || die "proposal $proposal_id is stale or malformed and will not be accepted (evidence=$RUN/params-pre-vote.json)"
  creator="$(jq -er .address "$ACCOUNTS/gdc-gateway-cold.json")"
  poc_exchange_duration="${GDC_POC_EXCHANGE_DURATION:-8}"
  transition_params="$RUN/params-pre-vote.json"
  if [[ "$proposal_status" == PROPOSAL_STATUS_PASSED ]]; then
    trusted_prestate="$("$ROOT/scripts/find-devshard-governance-prestate.sh" \
      "$GDC_HOME/runs" "$proposal_id" "$RUN/proposal-before.json" "$metadata_before_hash")" \
      || die "passed DevShard proposal $proposal_id lacks trusted local pre-state evidence"
    cp "$trusted_prestate" "$RUN/params-trusted-before.json"
    "$ROOT/scripts/verify-devshard-governance-snapshot.sh" before \
      "$RUN/proposal-before.json" "$RUN/params-trusted-before.json" "$mutable_protocol" \
      || die "passed DevShard proposal $proposal_id has invalid trusted pre-state evidence"
    transition_params="$RUN/params-trusted-before.json"
  fi
  "$ROOT/scripts/verify-devshard-governance-transition.sh" before \
    "$transition_params" "$RUN/proposal-before.json" "$creator" "$mutable_protocol" \
    "$expected_v5_url" "$expected_v5_sha256" "$poc_exchange_duration" \
    || die "proposal $proposal_id is outside the verified DevShard transition and will not be accepted"
  if [[ "$proposal_status" == PROPOSAL_STATUS_PASSED ]]; then
    "$ROOT/scripts/verify-devshard-governance-transition.sh" after \
      "$RUN/params-pre-vote.json" "$RUN/proposal-before.json" "$creator" "$mutable_protocol" \
      "$expected_v5_url" "$expected_v5_sha256" "$poc_exchange_duration" \
      || die "proposal $proposal_id passed without the exact verified DevShard post-state"
  fi
fi

# Cosmos may discard the individual vote list when the short test-lab voting
# period closes. A rerun must not try to vote on an inactive proposal or claim
# that every configured account voted. Record only the final chain outcome.
if [[ "$proposal_status" == PROPOSAL_STATUS_PASSED ]]; then
  tally_field="${option}_count"
  tally="$(jq -er --arg field "$tally_field" '.proposal.final_tally_result[$field] | tonumber' "$RUN/proposal-before.json")"
  (( tally > 0 )) || die "passed proposal $proposal_id has no $option voting power in its final tally"
  cp "$RUN/proposal-before.json" "$RUN/proposal-after.json"
  cp "$RUN/votes-before.json" "$RUN/votes-after.json"
  cat >"$RUN/verdict.md" <<EOF
# Governance vote: PASSED OUTCOME

Proposal $proposal_id had already closed with status
\`PROPOSAL_STATUS_PASSED\` and final \`$option\` voting power $tally. The
individual post-period vote list is not treated as participant-level evidence.
EOF
  printf 'RECORDED passed governance outcome: %s (proposal=%s tally=%s)\n' "$RUN" "$proposal_id" "$tally"
  exit 0
fi

mapfile -t nodes < <(configured_nodes)
(( ${#nodes[@]} > 0 )) || die 'no joined participants are available to vote'
voting_nodes=()
printf '[]' >"$RUN/expected-voters.json"
for node in "${nodes[@]}"; do
  node_home="$GDC_DATA_ROOT/$node"
  account_file="$node_home/accounts/$node-cold.json"
  password_file="$node_home/state/secrets/operator.keyring"
  operator_home="$node_home/state/operator-home"
  if [[ ! -s "$account_file" || ! -s "$password_file" || ! -d "$operator_home/keyring-file" ]]; then
    die "joined Host $node has incomplete local governance signing state; repair or restore it before voting"
  fi
  name="$node-cold"
  expected_address="$(jq -er .address "$account_file")"
  password="$(<"$password_file")"
  signing_address="$(printf '%s\n' "$password" | GDC_OPERATOR_HOME="$operator_home" \
    "$ROOT/scripts/inferenced.sh" keys show "$name" --keyring-backend file -a | tail -n1 | tr -d '\r')"
  [[ "$signing_address" == "$expected_address" ]] || \
    die "local governance signing identity for $node does not match its recorded account"
  jq --arg node "$node" --arg name "$name" --arg address "$expected_address" --arg option "$option_constant" \
    '. + [{node:$node,name:$name,address:$address,option:$option}]' \
    "$RUN/expected-voters.json" >"$RUN/expected-voters.tmp"
  mv "$RUN/expected-voters.tmp" "$RUN/expected-voters.json"
  voting_nodes+=("$node")
done
(( ${#voting_nodes[@]} > 0 )) || die 'no locally managed participant has complete governance signing state'
"$ROOT/scripts/governance-vote-evidence.sh" validate "$RUN/expected-voters.json" || \
  die 'locally managed Hosts do not have unique governance signer addresses'
printf '[]' >"$RUN/vote-transactions.json"
submitted=0
pending_names=()
pending_hashes=()
pending_addresses=()
for node in "${voting_nodes[@]}"; do
  name="$node-cold"
  node_home="$GDC_DATA_ROOT/$node"
  account_file="$node_home/accounts/$name.json"
  password_file="$node_home/state/secrets/operator.keyring"
  operator_home="$node_home/state/operator-home"
  address="$(jq -er .address "$account_file")"
  # A vote visible before this run is mutable until the period closes. Submit
  # the requested option again so every claimed participant has an immutable
  # committed receipt from this exact run.
  step "Vote $option from $name"
  password="$(<"$password_file")"
  tx="$(printf '%s\n' "$password" | GDC_OPERATOR_HOME="$operator_home" "$ROOT/scripts/inferenced.sh" tx gov vote "$proposal_id" "$option" \
    --from "$name" --keyring-backend file --chain-id "$CHAIN_ID" --node "$rpc" \
    --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"
  jq -e '.code == 0 and (.txhash | test("^[A-F0-9]{64}$"))' <<<"$tx" >/dev/null || die "vote transaction from $name failed"
  txhash="$(jq -er '.txhash' <<<"$tx")"
  jq --arg voter "$address" --arg name "$name" --argjson tx "$tx" '. + [{voter:$voter,name:$name,tx:$tx}]' "$RUN/vote-transactions.json" >"$RUN/vote-transactions.tmp"
  mv "$RUN/vote-transactions.tmp" "$RUN/vote-transactions.json"
  pending_names+=("$name")
  pending_hashes+=("$txhash")
  pending_addresses+=("$address")
  submitted=$((submitted + 1))
done

# Broadcast every configured account first. Waiting for one receipt before
# submitting the next vote consumed most of the 30-second rehearsal period.
for position in "${!pending_hashes[@]}"; do
  name="${pending_names[$position]}"
  txhash="${pending_hashes[$position]}"
  address="${pending_addresses[$position]}"
  receipt=''
  for _ in $(seq 1 60); do
    receipt="$("$ROOT/scripts/inferenced.sh" query tx "$txhash" --node "$rpc" --output json 2>/dev/null || true)"
    if jq -e '(.code // .tx_response.code // -1) == 0 and ((.height // .tx_response.height // "0") | tonumber) > 0' <<<"$receipt" >/dev/null 2>&1; then
      break
    fi
    printf 'WAIT  vote transaction %s from %s to enter a block\n' "$txhash" "$name"
    sleep 2
  done
  printf '%s\n' "$receipt" >"$RUN/vote-receipt-$name.json"
  "$ROOT/scripts/governance-vote-evidence.sh" receipt \
    "$address" "$proposal_id" "$option_constant" "$txhash" "$RUN/vote-receipt-$name.json" || \
    die "vote transaction from $name was not committed with the expected hash, voter, and option"
done

expected="${#voting_nodes[@]}"
deadline=$((SECONDS + 120))
actual=0
status=''
while (( SECONDS < deadline )); do
  ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-after.json"
  ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id/votes" >"$RUN/votes-after.json"
  status="$(jq -er '.proposal.status' "$RUN/proposal-after.json")"
  actual="$("$ROOT/scripts/governance-vote-evidence.sh" count \
    "$RUN/expected-voters.json" "$RUN/votes-after.json")"
  (( actual >= expected )) && break
  [[ "$status" != PROPOSAL_STATUS_VOTING_PERIOD ]] && break
  printf 'WAIT  proposal %s recorded votes=%s expected=%s\n' "$proposal_id" "$actual" "$expected"
  sleep 2
done

if (( actual < expected )); then
  # inferenced 0.2.14 may stop returning individual votes as soon as the short
  # test-lab voting period closes. In that state, this run's committed exact
  # vote receipts plus the final tally are the durable evidence.
  [[ "$status" == PROPOSAL_STATUS_PASSED ]] || \
    die "proposal $proposal_id has $actual recorded votes, expected at least $expected"
  tally_field="${option}_count"
  tally="$(jq -er --arg field "$tally_field" '.proposal.final_tally_result[$field] | tonumber' "$RUN/proposal-after.json")"
  (( tally > 0 && submitted == expected )) || \
    die "proposal $proposal_id passed without sufficient durable vote evidence"
fi
cat >"$RUN/verdict.md" <<EOF
# Governance vote: RECORDED

All $expected locally managed participants with complete signing state have durable evidence for a
\`$option\` vote on proposal $proposal_id. Current proposal status is
\`$status\`; software or parameter cutovers remain separately gated on
\`PROPOSAL_STATUS_PASSED\`.
EOF
printf 'RECORDED governance votes: %s (proposal=%s status=%s)\n' "$RUN" "$proposal_id" "$status"
