#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile bootstrap-access

[[ -e "$STATE/joined/$GENESIS_NODE" ]] || die 'Genesis is not active; run ./gdc.sh --release v2026.07.23 genesis first'
ssh_ready "$GENESIS_NODE" || die "$GENESIS_NODE is unreachable"

# A non-guardian singleton has no validation counterpart and cannot acquire a
# positive chain-computed model weight. `genesis <alias>` enables its guardian
# specifically for one-node access bootstrap.
guardian_addresses="$(ssh -T "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/params | jq -c ".params.genesis_guardian_params.guardian_addresses // []"')"
participant_count="$(ssh -T "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant | jq ".participant | length"')"
if [[ "$guardian_addresses" == '[]' && "$participant_count" =~ ^[0-9]+$ ]] && (( participant_count < 2 )); then
  die 'single-node bootstrap requires GDC_GENESIS_GUARDIAN_ENABLED=true; otherwise join one eligible model participant first'
fi

# The configured public edge may differ from the Genesis participant. Use that
# stable public route for operator RPC and the canonical API hostname for
# gateway access; do not hairpin through a participant hostname.
export GDC_CHAIN_RPC_URL="https://${PUBLIC_EDGE_HOST}/chain-rpc/"
export GDC_GATEWAY_PUBLIC_URL="https://${API_HOST}"

step 'Verify the sole Genesis participant is active'
genesis_address="$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")"
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant/$genesis_address" \
  | jq -e '.participant.status == "ACTIVE" or .participant.status == "PARTICIPANT_STATUS_ACTIVE" or .participant.status == 1' >/dev/null \
  || die "$GENESIS_NODE is not ACTIVE; wait for its ML activation before bootstrapping access"

step 'Approve configured DevShard protocols and the gateway creator through one-validator governance'
GDC_GOVERNANCE_SUBMIT=true GDC_GOVERNANCE_AUTO_VOTE=true \
  "$ROOT/scripts/phase-governance-devshard.sh"

GDC_CHAIN_RPC_URL="$GDC_CHAIN_RPC_URL" \
  "$ROOT/scripts/ensure-genesis-validation-weight.sh"

client_key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
gateway_active=false
active_escrow=''
gateway_status="$(curl -fsS "$GDC_GATEWAY_PUBLIC_URL/v1/status" -H "Authorization: Bearer $client_key" 2>/dev/null || true)"
active_escrow="$(jq -r '
  ([.devshards[]?
    | select(.active == true and .phase == "active" and (.requests_blocked // false) == false)
    | .id]
   + [if .phase == "active" and (.requests_blocked // false) == false then .escrow_id? else empty end])
  | map(select(. != null and (tostring | test("^[1-9][0-9]*$"))))
  | first // empty | tostring
' <<<"$gateway_status" 2>/dev/null || true)"
if [[ "$active_escrow" =~ ^[1-9][0-9]*$ ]]; then
  chain_escrow="$("$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$active_escrow" \
    --node "$GDC_CHAIN_RPC_URL" --chain-id "$CHAIN_ID" --output json 2>/dev/null || true)"
  jq -e --arg id "$active_escrow" '.found == true and (.escrow.id | tostring) == $id' <<<"$chain_escrow" >/dev/null 2>&1 \
    && gateway_active=true
fi

if [[ "$gateway_active" != true ]]; then
  existing_escrow=''
  gateway_env="$GENERATED/ops/gateway.env"
  if [[ -s "$gateway_env" ]]; then
    existing_escrow="$(awk -F= '$1 == "DEVSHARD_ESCROW_ID" {print $2}' "$gateway_env")"
    [[ "$existing_escrow" =~ ^[1-9][0-9]*$ ]] || existing_escrow=''
    if [[ -n "$existing_escrow" ]]; then
      chain_escrow="$("$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$existing_escrow" \
        --node "$GDC_CHAIN_RPC_URL" --chain-id "$CHAIN_ID" --output json 2>/dev/null || true)"
      jq -e --arg id "$existing_escrow" '.found == true and (.escrow.id | tostring) == $id' <<<"$chain_escrow" >/dev/null 2>&1 \
        || existing_escrow=''
    fi
  fi
  step 'Start authenticated chain-accounted inference on the Genesis participant'
  if [[ -n "$existing_escrow" ]]; then
    GDC_ESCROW_ID="$existing_escrow" "$ROOT/scripts/phase-ops.sh" gateway
  else
    "$ROOT/scripts/phase-ops.sh" gateway
  fi
else
  # Reconcile persisted limits and authentication even when an active runtime
  # survived. A status-only check cannot prove that requests are admissible.
  step 'Reconcile authenticated gateway settings on the active Genesis escrow'
  GDC_ESCROW_ID="$active_escrow" "$ROOT/scripts/phase-ops.sh" gateway
fi

step 'Verify final authenticated inference access'
"$ROOT/04-ops/test-inference.sh" "$GDC_GATEWAY_PUBLIC_URL" "$client_key" >/dev/null
printf 'PASS bootstrap access: governed DevShard and active authenticated gateway\n'
printf 'INFO OPS Telegram inference consumer is optional and is not a Genesis or Host-join prerequisite\n'
printf 'READY run ./gdc.sh --release v2026.07.23 gateway-continuity after independent operators add eligible non-guardian model capacity\n'
