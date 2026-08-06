#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 inventory.env secrets-dir output-gateway.env [escrow-amount-ngonka]" >&2; }
[[ $# -ge 3 && $# -le 4 ]] || { usage; exit 2; }
INVENTORY="$1"; SECRETS="$2"; OUT="$3"; AMOUNT="${4:-${GDC_GATEWAY_ESCROW_AMOUNT_NGONKA:-}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$INVENTORY"
source "$ROOT/scripts/profile.sh"
load_profiles
GATEWAY_VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
[[ "$GATEWAY_VERSION" =~ ^v[34]$ ]] || { echo 'GDC_GATEWAY_VERSION must be v3 or v4' >&2; exit 2; }
[[ -z "$AMOUNT" || "$AMOUNT" =~ ^[0-9]+$ ]] || exit 2
PASSWORD="$(<"$SECRETS/operator.keyring")"; ADMIN_KEY="$(<"$SECRETS/gateway.admin-key")"; CLIENT_KEYS="$(<"$SECRETS/gateway.client-keys")"
MAX_CONCURRENT_REQUESTS="${GDC_GATEWAY_MAX_CONCURRENT_REQUESTS:-0}"
MAX_INPUT_TOKENS_IN_FLIGHT="${GDC_GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT:-0}"
[[ "$MAX_CONCURRENT_REQUESTS" =~ ^[0-9]+$ ]] || { echo 'GDC_GATEWAY_MAX_CONCURRENT_REQUESTS must be a non-negative integer' >&2; exit 2; }
[[ "$MAX_INPUT_TOKENS_IN_FLIGHT" =~ ^[0-9]+$ ]] || { echo 'GDC_GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT must be a non-negative integer' >&2; exit 2; }
CREATOR="$(jq -er .address "$ROOT/artifacts/accounts/gdc-gateway.json")"
# node4 owns public chain RPC after the distributed topology is available;
# bootstrap-access overrides this with the sole live Genesis participant.
RPC="${GDC_CHAIN_RPC_URL:-https://${NODE4_PUBLIC_HOST}/chain-rpc/}"

# The later settlement evidence must demonstrate the whole economic path, not
# only its final state.  Capture the creator balance before the escrow funding
# transaction and persist the receipt beside the rendered gateway environment.
BALANCE_BEFORE="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$CREATOR")"

# v3/v4 and the creator are intentionally a governance gate, never Genesis
# convenience state or a local versiond configuration substitute.
PARAMS="$("$ROOT/scripts/inferenced.sh" query inference params --node "$RPC" --chain-id "$CHAIN_ID" --output json)"
MIN_AMOUNT="$(jq -er '(.params // .).devshard_escrow_params.min_amount' <<<"$PARAMS")"
[[ "$MIN_AMOUNT" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid live escrow min_amount' >&2; exit 1; }
# The governance account pays proposal deposits before access is bootstrapped.
# Therefore its original Genesis allocation is not a safe escrow default.  Use
# the live governance minimum unless the operator deliberately requests more.
AMOUNT="${AMOUNT:-$MIN_AMOUNT}"
[[ "$AMOUNT" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid escrow amount' >&2; exit 1; }
(( AMOUNT >= MIN_AMOUNT )) || { echo "escrow amount $AMOUNT is below live governance minimum $MIN_AMOUNT" >&2; exit 1; }
SPENDABLE_AMOUNT="$(jq -r '[.balances[]? | select(.denom == "ngonka") | .amount][0] // "0"' <<<"$BALANCE_BEFORE")"
[[ "$SPENDABLE_AMOUNT" =~ ^[0-9]+$ ]] || { echo 'invalid spendable ngonka balance' >&2; exit 1; }
(( AMOUNT <= SPENDABLE_AMOUNT )) || {
  echo "escrow amount $AMOUNT exceeds spendable balance $SPENDABLE_AMOUNT; omit GDC_GATEWAY_ESCROW_AMOUNT_NGONKA to use the live minimum $MIN_AMOUNT" >&2
  exit 1
}
jq -e --arg creator "$CREATOR" '
  (.params // .).devshard_escrow_params as $p
  | ($p.allowed_creator_addresses | index($creator) != null)
  and ([ $p.approved_versions[].name ] | sort) == ["v3", "v4"]
  and ($p.approved_versions[] | .sha256 | test("^[0-9a-f]{64}$"))
' <<<"$PARAMS" >/dev/null || {
  echo 'v3/v4 approval and gateway creator allowlist must pass through governance before gateway deployment' >&2
  exit 1
}

# The devshard group can only be sampled after the model has active validation weights.
mapfile -t markers < <(find "$ROOT/state/joined" -maxdepth 1 -type f -name 'gdc-node[0-4]' -print | LC_ALL=C sort)
(( ${#markers[@]} > 0 )) || { echo 'No joined participants found' >&2; exit 1; }
for marker in "${markers[@]}"; do
  node="$(basename "$marker")"
  account="$ROOT/artifacts/accounts/$node-cold.json"
  [[ -s "$account" ]] || { echo "Missing account artifact for $node" >&2; exit 1; }
  address="$(jq -r .address "$account")"
  # Participant state is chain data.  The decentralized API exposes the
  # model catalog at /v1/models, not the obsolete public /v2 aggregate.
  status="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant/$address" | jq -r '.participant.status // empty')"
  case "$status" in ACTIVE|PARTICIPANT_STATUS_ACTIVE|1) ;; *) echo "$node is not ACTIVE: $status" >&2; exit 1;; esac
done

EXISTING_ESCROW_ID="${GDC_ESCROW_ID:-}"
if [[ -n "$EXISTING_ESCROW_ID" ]]; then
  [[ "$EXISTING_ESCROW_ID" =~ ^[1-9][0-9]*$ ]] || { echo 'GDC_ESCROW_ID must be a positive integer' >&2; exit 2; }
  EXISTING_ESCROW="$("$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$EXISTING_ESCROW_ID" --node "$RPC" --chain-id "$CHAIN_ID" --output json)"
  jq -e --arg creator "$CREATOR" --arg model "$MODEL_ID" '.found == true and .escrow.creator == $creator and .escrow.model_id == $model' <<<"$EXISTING_ESCROW" >/dev/null || {
    echo "existing escrow $EXISTING_ESCROW_ID is not the configured gateway escrow" >&2; exit 1;
  }
  ESCROW_ID="$EXISTING_ESCROW_ID"
  TX=''
  BALANCE_AFTER_FUNDING="$BALANCE_BEFORE"
else
TX="$(printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" tx inference create-devshard-escrow \
  "$AMOUNT" "$MODEL_ID" --from gdc-gateway --keyring-backend file --chain-id "$CHAIN_ID" \
  --node "$RPC" --gas auto --gas-adjustment 1.5 \
  --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"
HASH="$(jq -r '.txhash // .tx_response.txhash // empty' <<<"$TX")"
[[ "$HASH" =~ ^[0-9A-Fa-f]{64}$ ]] || { echo "$TX" | jq . >&2; echo 'Cannot obtain tx hash' >&2; exit 1; }
for _ in $(seq 1 60); do
  RESULT="$("$ROOT/scripts/inferenced.sh" query tx "$HASH" --node "$RPC" --output json 2>/dev/null || true)"
  [[ -n "$RESULT" ]] && break
  sleep 2
done
[[ -n "${RESULT:-}" ]] || { echo 'Transaction was not found' >&2; exit 1; }
CODE="$(jq -r '.code // .tx_response.code // 0' <<<"$RESULT")"; [[ "$CODE" == 0 ]] || { echo "$RESULT" | jq . >&2; exit 1; }
ESCROW_ID="$(jq -r '[..|objects|select(.key?=="escrow_id")|.value][0] // empty' <<<"$RESULT")"
[[ "$ESCROW_ID" =~ ^[0-9]+$ ]] || { echo "$RESULT" | jq . >&2; echo 'Cannot parse escrow_id' >&2; exit 1; }
# A successful transaction response only proves DeliverTx accepted the
# message.  Do not render a gateway environment until the committed chain
# state exposes this exact escrow.  Otherwise the gateway can retain a local
# "active" runtime which every DevShard host correctly rejects as missing.
ESCROW_ON_CHAIN="$("$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$ESCROW_ID" --node "$RPC" --chain-id "$CHAIN_ID" --output json)"
jq -e --arg id "$ESCROW_ID" --arg creator "$CREATOR" --arg model "$MODEL_ID" '
  .found == true
  and (.escrow.id | tostring) == $id
  and .escrow.creator == $creator
  and .escrow.model_id == $model
' <<<"$ESCROW_ON_CHAIN" >/dev/null || {
  echo "new escrow $ESCROW_ID was not found in committed chain state" >&2
  exit 1
}
BALANCE_AFTER_FUNDING="$(ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$CREATOR")"
fi
PRIVATE="$(printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" keys export gdc-gateway --keyring-backend file --unarmored-hex --unsafe --yes | grep -Eo '[0-9a-fA-F]{64}' | tail -n1)"
[[ "$PRIVATE" =~ ^[0-9a-fA-F]{64}$ ]] || { echo 'Cannot export gateway private key' >&2; exit 1; }
umask 077; mkdir -p "$(dirname "$OUT")"
cat >"$OUT" <<EOF
DEVSHARD_CHAIN_GRPC=127.0.0.1:9090
DEVSHARD_CHAIN_RPC=http://127.0.0.1:26657
DEVSHARD_CHAIN_ID=${CHAIN_ID}
DEVSHARD_PUBLIC_API=http://127.0.0.1:9000
DEVSHARD_PORT=18080
DEVSHARD_STORAGE_DIR=/root/.devshardctl
DEVSHARD_API_KEYS=${CLIENT_KEYS}
DEVSHARD_ADMIN_API_KEY=${ADMIN_KEY}
DEVSHARD_PRIVATE_KEY=${PRIVATE}
DEVSHARD_ESCROW_ID=${ESCROW_ID}
DEVSHARD_MODEL=${MODEL_ID}
DEVSHARD_ROUTE_PREFIX=/devshard/${GATEWAY_VERSION}
DEVSHARD_GATEWAY_DATA_VOLUME=gateway-data-${GATEWAY_VERSION}
# Escrows are pruned by the chain after their retention window.  Persist the
# funding amount so phase-ops can configure the gateway's next-epoch bridge
# and replacement escrows instead of treating this deployment as one-shot.
DEVSHARD_ROTATION_ESCROW_AMOUNT=${AMOUNT}
DEVSHARD_POC_REQUEST_MODE=relaxed
DEVSHARD_CAPACITY_AWARE_LIMITS=on
GATEWAY_MAX_CONCURRENT_REQUESTS=${MAX_CONCURRENT_REQUESTS}
GATEWAY_MAX_CONCURRENT_REQUESTS_PER_10000_WEIGHT=${GDC_GATEWAY_MAX_CONCURRENT_PER_10000_WEIGHT:-1000000000}
GATEWAY_POC_MAX_CONCURRENT_REQUESTS_PER_10000_WEIGHT=${GDC_GATEWAY_MAX_CONCURRENT_PER_10000_WEIGHT:-1000000000}
GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT=${MAX_INPUT_TOKENS_IN_FLIGHT}
# The Qwen profile has a 2048-token context window.  A default equal to the
# whole window makes every non-empty OpenAI-compatible request invalid when a
# client omits max_tokens.  Keep room for the prompt by default.
GATEWAY_DEFAULT_MAX_TOKENS=1024
EOF
chmod 600 "$OUT"
umask 077
if [[ -n "$TX" ]]; then
  jq -n \
    --arg creator "$CREATOR" --arg escrow_id "$ESCROW_ID" --arg amount "$AMOUNT" \
    --arg min_amount "$MIN_AMOUNT" --arg txhash "$HASH" \
    --argjson balance_before "$BALANCE_BEFORE" \
    --argjson balance_after_funding "$BALANCE_AFTER_FUNDING" \
    '{creator:$creator,escrowId:$escrow_id,amountNgonka:$amount,minAmountNgonka:$min_amount,txHash:$txhash,balanceBeforeFunding:$balance_before,balanceAfterFunding:$balance_after_funding}' \
    >"${OUT%.env}.escrow-create.json"
  chmod 600 "${OUT%.env}.escrow-create.json"
fi
printf 'READY gateway escrow=%s\n' "$ESCROW_ID"
