#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-governance-devshard"
mkdir -p "$RUN"
install_evidence_exit_trap 'DevShard governance'
record_phase_profile governance-devshard
creator="$(jq -er .address "$ACCOUNTS/gdc-gateway-cold.json")"
poc_exchange_duration="${GDC_POC_EXCHANGE_DURATION:-8}"
[[ "$poc_exchange_duration" =~ ^[1-9][0-9]*$ ]] || die 'GDC_POC_EXCHANGE_DURATION must be positive'
governance_candidates="${DEVSHARD_GOVERNANCE_PROTOCOLS:-${DEVSHARD_SUPPORTED_PROTOCOLS:-$DEVSHARD_PROTOCOL_VERSION}}"
supported_protocols="${GDC_GOVERNANCE_DEVSHARD_PROTOCOLS:-$governance_candidates}"
supported_protocols="$("$ROOT/scripts/validate-devshard-governance-protocols.sh" \
  "$supported_protocols" "$governance_candidates")"
read -r -a supported_protocols_array <<<"$supported_protocols"
approved_versions='[]'
artifact_cache="$GDC_HOME/cache/devshard"
for protocol in "${supported_protocols_array[@]}"; do
  jq -e --arg protocol "$protocol" 'all(.[]; .name != $protocol)' <<<"$approved_versions" >/dev/null \
    || die "duplicate DevShard protocol in requested governance set: $protocol"
  case "$protocol" in
    v3) approved_versions="$(jq --arg url "$DEVSHARD_V3_URL" --arg sha "$DEVSHARD_V3_SHA256" '. + [{name:"v3",binary:$url,sha256:$sha}]' <<<"$approved_versions")" ;;
    v4) approved_versions="$(jq --arg url "$DEVSHARD_V4_URL" --arg sha "$DEVSHARD_V4_SHA256" '. + [{name:"v4",binary:$url,sha256:$sha}]' <<<"$approved_versions")" ;;
    v5) approved_versions="$(jq --arg url "$DEVSHARD_V5_URL" --arg sha "$DEVSHARD_V5_SHA256" '. + [{name:"v5",binary:$url,sha256:$sha}]' <<<"$approved_versions")" ;;
    *) die "unsupported DevShard governance candidate: $protocol" ;;
  esac
done
printf 'PROFILE phase=governance-devshard approved_protocols=%s\n' "$supported_protocols"

step 'Verify requested DevShard archives before governance'
while IFS=$'\t' read -r protocol url sha; do
  "$ROOT/scripts/verify-devshard-archive.sh" "$protocol" "$url" "$sha" "$artifact_cache"
done < <(jq -r '.[] | [.name,.binary,.sha256] | @tsv' <<<"$approved_versions")
# Public chain RPC terminates on the configured public edge after the distributed topology is
# available. bootstrap-access overrides this with the sole Genesis participant.
rpc="${GDC_CHAIN_RPC_URL:-https://$PUBLIC_EDGE_HOST/chain-rpc/}"
authority="${GDC_INFERENCE_GOV_AUTHORITY:-gonka10d07y265gmmuvt4z0w9aw880jnsr700j2h5m33}"
[[ "$authority" =~ ^gonka1[0-9a-z]{20,90}$ ]] || die 'GDC_INFERENCE_GOV_AUTHORITY is invalid'

step 'Capture live inference and governance parameters before proposal'
# Use the same protobuf JSON REST representation that governance proposal
# readback uses, through the current public chain boundary used by the
# transition. The CLI query omits unpopulated fields and a lagging local Host
# could preserve stale unrelated parameters.
params_url="${GDC_CHAIN_API_URL:-https://${PUBLIC_EDGE_HOST}/chain-api}"
params_url="${params_url%/}/productscience/inference/inference/params"
params_curl_stderr="$RUN/params-before.curl.stderr"
set +e
params_http_status="$(curl -sS --connect-timeout 5 --max-time 30 -o "$RUN/params-before.json" \
  -w '%{http_code}' "$params_url" 2>"$params_curl_stderr")"
params_curl_exit=$?
set -e
if (( params_curl_exit != 0 )) || [[ ! "$params_http_status" =~ ^2[0-9][0-9]$ ]]; then
  params_error_detail="$(tr '\n' ' ' <"$params_curl_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | cut -c1-240)"
  die "cannot capture current public inference parameters (url=$params_url http_status=${params_http_status:-000} curl_exit=$params_curl_exit curl_status=$(curl_exit_status "$params_curl_exit")${params_error_detail:+ detail=$params_error_detail})"
fi
jq -e '(.params // .)' "$RUN/params-before.json" >"$RUN/params-before.normalized.json" \
  || die "current public inference parameters are malformed (url=$params_url evidence=$RUN/params-before.json)"
ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/params/deposit' >"$RUN/gov-params.json"
min_deposit="$(jq -er '(.params.min_deposit // .deposit_params.min_deposit)[0] | .amount + .denom' "$RUN/gov-params.json")"
deposit="${GDC_GOVERNANCE_DEPOSIT:-$min_deposit}"
[[ "$deposit" =~ ^[1-9][0-9]*ngonka$ ]] || die 'GDC_GOVERNANCE_DEPOSIT must be a positive ngonka amount'
(( ${deposit%ngonka} >= ${min_deposit%ngonka} )) || die "governance deposit $deposit is below live minimum $min_deposit"

step 'Render the full, state-preserving DevShard params proposal'
jq --arg authority "$authority" --arg creator "$creator" --argjson approved_versions "$approved_versions" \
  --arg poc_exchange_duration "$poc_exchange_duration" --arg poc_validation_delay "10" \
  --arg deposit "$deposit" '
  (.params // .) as $params
  | $params
  | .devshard_escrow_params.allowed_creator_addresses = [$creator]
  | .devshard_escrow_params.approved_versions = $approved_versions
  | .devshard_escrow_params.devshard_requests_enabled = true
  | .epoch_params.poc_exchange_duration = $poc_exchange_duration
  | .epoch_params.poc_validation_delay = $poc_validation_delay
  | .epoch_params.poc_slot_allocation = {value:"5", exponent:-1}
  | {messages:[{"@type":"/inference.inference.MsgUpdateParams",authority:$authority,params:.}],
     metadata:"",title:"GDC: DevShard access and protocol PoC allocation",deposit:$deposit,
     summary:"Registers immutable supported DevShard archives, allows the dedicated gateway creator, keeps the 0.2.14 PoC distribution retry window open, and preserves the protocol default 50 percent PoC slot allocation."}
' "$RUN/params-before.json" >"$RUN/proposal.json"
message_hash="$(jq -cS '.messages' "$RUN/proposal.json" | sha256sum | awk '{print $1}')"
proposal_metadata="gdc-message-sha256:$message_hash"
jq --arg metadata "$proposal_metadata" '.metadata = $metadata' "$RUN/proposal.json" >"$RUN/proposal.with-metadata.json"
mv "$RUN/proposal.with-metadata.json" "$RUN/proposal.json"
jq -e --arg creator "$creator" --argjson approved_versions "$approved_versions" '
  .messages[0].params.devshard_escrow_params as $p
  | $p.allowed_creator_addresses == [$creator]
  and $p.approved_versions == $approved_versions
  and ($p.approved_versions[] | .sha256 | test("^[0-9a-f]{64}$"))
  and ($p.max_nonce | tonumber > 0)
  and (.messages[0].params.epoch_params.poc_slot_allocation == {value:"5", exponent:-1})
' "$RUN/proposal.json" >/dev/null

if jq -e --arg creator "$creator" --argjson approved_versions "$approved_versions" --arg exchange "$poc_exchange_duration" '
  (.params // .).devshard_escrow_params as $p
  | ($p.allowed_creator_addresses | index($creator) != null)
  and ($p.devshard_requests_enabled == true)
  and $p.approved_versions == $approved_versions
  and (((.params // .).epoch_params.poc_exchange_duration | tonumber) == ($exchange | tonumber))
  and (((.params // .).epoch_params.poc_validation_delay | tonumber) >= 10)
  and ((((.params // .).epoch_params.poc_slot_allocation.value // "0") | tonumber) == 5)
  and ((((.params // .).epoch_params.poc_slot_allocation.exponent // 0) | tonumber) == -1)
' "$RUN/params-before.json" >/dev/null; then
  cp "$RUN/params-before.json" "$RUN/params-after.json"
  cat >"$RUN/verdict.md" <<EOF
# DevShard governance: PASS

The effective chain parameters already authorize the configured DevShard binaries and
the dedicated gateway creator. No duplicate proposal was submitted.
EOF
  printf 'PASS governance already effective: %s\n' "$RUN"
  exit 0
fi

proposal_id="${GDC_GOVERNANCE_PROPOSAL_ID:-}"
if [[ -z "$proposal_id" ]]; then
  "$ROOT/scripts/fetch-governance-proposals.sh" "$GENESIS_NODE" "$RUN/proposals.json"
  proposal_id="$("$ROOT/scripts/select-devshard-governance-proposal.sh" "$RUN/proposal.json" "$RUN/proposals.json")"
  [[ -z "$proposal_id" ]] || printf 'READY reuse DevShard governance proposal %s\n' "$proposal_id"
fi
if [[ -z "$proposal_id" && "${GDC_GOVERNANCE_SUBMIT:-false}" == true ]]; then
  step 'Submit governance proposal from the dedicated operator account'
  password="$(<"$SECRETS/operator.keyring")"
  tx="$(printf '%s\n' "$password" | "$ROOT/scripts/inferenced.sh" tx gov submit-proposal "$RUN/proposal.json" \
    --from "$GENESIS_NODE-cold" --keyring-backend file --chain-id "$CHAIN_ID" --node "$rpc" \
    --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"
  printf '%s\n' "$tx" >"$RUN/submit-tx.json"
  txhash="$(jq -er '.txhash // .tx_response.txhash' "$RUN/submit-tx.json")"
  for _ in $(seq 1 60); do
    result="$("$ROOT/scripts/inferenced.sh" query tx "$txhash" --node "$rpc" --output json 2>/dev/null || true)"
    proposal_id="$(jq -r '[..|objects|select(.key? == "proposal_id")|.value][0] // empty' <<<"$result")"
    [[ "$proposal_id" =~ ^[0-9]+$ ]] && break
    printf 'WAIT  proposal id from tx %s\n' "$txhash"
    sleep 2
  done
fi

if [[ "$proposal_id" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "$proposal_id" >"$RUN/proposal-id.txt"
fi

if [[ ! "$proposal_id" =~ ^[0-9]+$ ]]; then
  cat >"$RUN/verdict.md" <<EOF
# DevShard governance: BLOCKED

The complete state-preserving proposal is rendered at \`proposal.json\`. Submit
it with \`GDC_GOVERNANCE_SUBMIT=true\` or rerun with its passed proposal ID in
\`GDC_GOVERNANCE_PROPOSAL_ID\`; gateway deployment remains intentionally gated.
EOF
  printf 'BLOCKED governance evidence: %s\n' "$RUN"
  exit 3
fi

step "Verify passed governance proposal $proposal_id"
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-status.json"
jq '{proposals:[.proposal]}' "$RUN/proposal-status.json" >"$RUN/proposal-selected-list.json"
matched_proposal_id="$("$ROOT/scripts/select-devshard-governance-proposal.sh" \
  "$RUN/proposal.json" "$RUN/proposal-selected-list.json" verify)"
if [[ "$matched_proposal_id" != "$proposal_id" ]]; then
  cat >"$RUN/verdict.md" <<EOF
# DevShard governance: BLOCKED

Proposal $proposal_id does not carry the exact DevShard transition rendered by
this run. It is not reused, voted, or accepted as evidence for this transition.
EOF
  printf 'BLOCKED proposal %s does not match desired DevShard transition metadata and parameters\n' "$proposal_id"
  exit 3
fi
proposal_status="$(jq -er '.proposal.status' "$RUN/proposal-status.json")"
if [[ "$proposal_status" == PROPOSAL_STATUS_VOTING_PERIOD && "${GDC_GOVERNANCE_AUTO_VOTE:-false}" == true ]]; then
  "$ROOT/scripts/phase-vote-proposal.sh" "$proposal_id" yes
  deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-status.json"
    proposal_status="$(jq -er '.proposal.status' "$RUN/proposal-status.json")"
    [[ "$proposal_status" == PROPOSAL_STATUS_PASSED ]] && break
    [[ "$proposal_status" == PROPOSAL_STATUS_REJECTED || "$proposal_status" == PROPOSAL_STATUS_FAILED ]] && break
    printf 'WAIT  DevShard proposal %s status=%s\n' "$proposal_id" "$proposal_status"
    sleep 2
  done
fi
jq -e '.proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/proposal-status.json" >/dev/null || {
  cat >"$RUN/verdict.md" <<EOF
# DevShard governance: BLOCKED

Proposal $proposal_id has not passed. Gateway deployment is gated on its passed
status; the proposal and current status are preserved in this evidence bundle.
EOF
  exit 3
}

step 'Verify effective versions, creator allowlist, and live escrow limits'
"$ROOT/scripts/inferenced.sh" query inference params --node "$rpc" --chain-id "$CHAIN_ID" --output json >"$RUN/params-after.json"
jq -e --arg creator "$creator" --argjson approved_versions "$approved_versions" --arg exchange "$poc_exchange_duration" '
  (.params // .).devshard_escrow_params as $p
  | ($p.allowed_creator_addresses | index($creator) != null)
  and ($p.approved_versions == $approved_versions)
  and ($p.min_amount | tonumber > 0)
  and ($p.max_nonce | tonumber > 0)
  and (((.params // .).epoch_params.poc_exchange_duration | tonumber) == ($exchange | tonumber))
  and (((.params // .).epoch_params.poc_validation_delay | tonumber) >= 10)
  and ((((.params // .).epoch_params.poc_slot_allocation.value // "0") | tonumber) == 5)
  and ((((.params // .).epoch_params.poc_slot_allocation.exponent // 0) | tonumber) == -1)
' "$RUN/params-after.json" >/dev/null
cat >"$RUN/verdict.md" <<EOF
# DevShard governance: PASS

Proposal $proposal_id passed. The chain now authorizes the configured DevShard
protocols with recorded SHA-256 values, allows the dedicated gateway creator
$creator, and preserves the protocol default 50 percent PoC slot allocation.
EOF
printf 'PASS governance evidence: %s\n' "$RUN"
