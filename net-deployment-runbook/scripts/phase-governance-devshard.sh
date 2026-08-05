#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-governance-devshard"
mkdir -p "$RUN"
record_phase_profile governance-devshard
creator="$(jq -er .address "$ACCOUNTS/gdc-gateway.json")"
# Public chain RPC terminates on the physical node4/one-net edge.  node0 is an
# internal application backend and no longer owns public TLS.
rpc="https://$NODE4_PUBLIC_HOST/chain-rpc/"
authority="${GDC_INFERENCE_GOV_AUTHORITY:-gonka10d07y265gmmuvt4z0w9aw880jnsr700j2h5m33}"
[[ "$authority" =~ ^gonka1[0-9a-z]{20,90}$ ]] || die 'GDC_INFERENCE_GOV_AUTHORITY is invalid'

step 'Capture live inference and governance parameters before proposal'
"$ROOT/scripts/inferenced.sh" query inference params --node "$rpc" --chain-id "$CHAIN_ID" --output json >"$RUN/params-before.json"
jq -e '(.params // .)' "$RUN/params-before.json" >"$RUN/params-before.normalized.json"
ssh gdc-node0 'curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/params/deposit' >"$RUN/gov-params.json"
min_deposit="$(jq -er '(.params.min_deposit // .deposit_params.min_deposit)[0] | .amount + .denom' "$RUN/gov-params.json")"
deposit="${GDC_GOVERNANCE_DEPOSIT:-$min_deposit}"
[[ "$deposit" =~ ^[1-9][0-9]*ngonka$ ]] || die 'GDC_GOVERNANCE_DEPOSIT must be a positive ngonka amount'
(( ${deposit%ngonka} >= ${min_deposit%ngonka} )) || die "governance deposit $deposit is below live minimum $min_deposit"

step 'Render the full, state-preserving DevShard params proposal'
jq --arg authority "$authority" --arg creator "$creator" \
  --arg v3_url "$DEVSHARD_V3_URL" --arg v3_sha "$DEVSHARD_V3_SHA256" \
  --arg v4_url "$DEVSHARD_V4_URL" --arg v4_sha "$DEVSHARD_V4_SHA256" --arg deposit "$deposit" '
  (.params // .) as $params
  | $params
  | .devshard_escrow_params.allowed_creator_addresses = [$creator]
  | .devshard_escrow_params.approved_versions = [
      {name:"v3", binary:$v3_url, sha256:$v3_sha},
      {name:"v4", binary:$v4_url, sha256:$v4_sha}
    ]
  | .devshard_escrow_params.devshard_requests_enabled = true
  | {messages:[{"@type":"/inference.inference.MsgUpdateParams",authority:$authority,params:.}],
     metadata:"",title:"GDC: approve DevShard v3 and v4 plus gateway creator",deposit:$deposit,
     summary:"Registers immutable DevShard v3/v4 archives and allows the dedicated GDC gateway creator."}
' "$RUN/params-before.json" >"$RUN/proposal.json"
jq -e --arg creator "$creator" '
  .messages[0].params.devshard_escrow_params as $p
  | $p.allowed_creator_addresses == [$creator]
  and ([ $p.approved_versions[].name ] | sort) == ["v3", "v4"]
  and ($p.approved_versions[] | .sha256 | test("^[0-9a-f]{64}$"))
  and ($p.max_nonce | tonumber > 0)
' "$RUN/proposal.json" >/dev/null

proposal_id="${GDC_GOVERNANCE_PROPOSAL_ID:-}"
if [[ -z "$proposal_id" && "${GDC_GOVERNANCE_SUBMIT:-false}" == true ]]; then
  step 'Submit governance proposal from the dedicated operator account'
  password="$(<"$SECRETS/operator.keyring")"
  proposal_in_container="/kit/${RUN#"$ROOT/"}/proposal.json"
  tx="$(printf '%s\n' "$password" | "$ROOT/scripts/inferenced.sh" tx gov submit-proposal "$proposal_in_container" \
    --from gdc-node0-cold --keyring-backend file --chain-id "$CHAIN_ID" --node "$rpc" \
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
ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/proposal-status.json"
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
jq -e --arg creator "$creator" --arg v3 "$DEVSHARD_V3_SHA256" --arg v4 "$DEVSHARD_V4_SHA256" '
  (.params // .).devshard_escrow_params as $p
  | ($p.allowed_creator_addresses | index($creator) != null)
  and ($p.approved_versions | length == 2)
  and ($p.approved_versions[] | select(.name == "v3").sha256 == $v3)
  and ($p.approved_versions[] | select(.name == "v4").sha256 == $v4)
  and ($p.min_amount | tonumber > 0)
  and ($p.max_nonce | tonumber > 0)
' "$RUN/params-after.json" >/dev/null
cat >"$RUN/verdict.md" <<EOF
# DevShard governance: PASS

Proposal $proposal_id passed. The chain now authorizes only v3 and v4 with
recorded SHA-256 values and allows the dedicated gateway creator $creator.
EOF
printf 'PASS governance evidence: %s\n' "$RUN"
