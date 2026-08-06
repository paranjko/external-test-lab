#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile bootstrap-access

[[ -e "$STATE/joined/gdc-node0" ]] || die 'Genesis is not active; run ./gdc.sh --release testnet-0.2.14 genesis first'
ssh_ready gdc-node0 || die 'gdc-node0 is unreachable'
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && "$TELEGRAM_BOT_TOKEN" != replace-with-BotFather-token ]] \
  || die "TELEGRAM_BOT_TOKEN must be configured in $ENV_FILE"

# During one-participant bootstrap node4 has not joined the chain yet. Use the
# live Genesis endpoint and node0's dedicated gateway route explicitly. The
# ordinary distributed lifecycle switches public access to node4 later.
export GDC_CHAIN_RPC_URL="https://${NODE0_PUBLIC_HOST}/chain-rpc/"
export GDC_GATEWAY_PUBLIC_URL="https://${NODE0_PUBLIC_HOST}/gateway"

step 'Verify the sole Genesis participant is active'
node0_address="$(jq -er .address "$ACCOUNTS/gdc-node0-cold.json")"
ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant/$node0_address" \
  | jq -e '.participant.status == "ACTIVE" or .participant.status == "PARTICIPANT_STATUS_ACTIVE" or .participant.status == 1' >/dev/null \
  || die 'gdc-node0 is not ACTIVE; wait for its ML activation before bootstrapping access'

pool_created=false
if [[ ! -s "$SECRETS/gateway-key-pool.json" ]]; then
  step 'Create the finite Telegram key pool before rendering gateway credentials'
  "$ROOT/scripts/create-telegram-key-pool.sh" --secrets-dir "$SECRETS"
  pool_created=true
fi

step 'Approve pinned DevShard v3/v4 and the gateway creator through one-validator governance'
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

if [[ "$gateway_active" != true || "$pool_created" == true ]]; then
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

step 'Install the current authorised pool beside the preserved BotFather configuration'
bot_dir=/srv/dai/gonka-devnet-bot
remote_pool="/tmp/gdc-gateway-key-pool-$$.json"
scp -q "$SECRETS/gateway-key-pool.json" "gdc-node0:$remote_pool"
ssh gdc-node0 "set -Eeuo pipefail
  sudo install -d -m 0750 '$bot_dir' '$bot_dir/data'
  sudo install -o root -g root -m 0600 '$remote_pool' '$bot_dir/gateway-key-pool.json'
  rm -f '$remote_pool'"

step 'Deploy the Telegram issuer only after a key passes real chat completion'
GDC_TELEGRAM_BOT_HOST=gdc-node0 \
GDC_TELEGRAM_BOT_API_BASE_URL="$GDC_GATEWAY_PUBLIC_URL/v1" \
  "$ROOT/scripts/deploy-telegram-bot.sh"

step 'Verify final authenticated inference access'
"$ROOT/04-ops/test-inference.sh" "$GDC_GATEWAY_PUBLIC_URL" "$client_key" >/dev/null
printf 'PASS phase-local bootstrap access on gdc-node0: governed DevShard, active gateway, verified key pool and Telegram issuer\n'
printf 'READY run ./gdc.sh --release testnet-0.2.14 gateway-continuity after independent operators add eligible non-guardian model capacity\n'
