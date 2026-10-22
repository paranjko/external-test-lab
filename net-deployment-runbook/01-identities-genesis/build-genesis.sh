#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ cat >&2 <<'EOF'
Usage: ./build-genesis.sh --inventory inventory.env --identities-dir DIR \
  --secrets-dir DIR --genesis-time 2026-08-01T12:00:00Z --output-dir DIR [--config-file PATH] [--candidate-only]
EOF
}
INVENTORY=""; IDENTITIES=""; SECRETS=""; GENESIS_TIME=""; OUTPUT=""; CONFIG_FILE=""; CANDIDATE_ONLY=false
while (($#)); do
 case "$1" in
  --inventory) INVENTORY="$2"; shift 2;; --identities-dir) IDENTITIES="$2"; shift 2;;
  --secrets-dir) SECRETS="$2"; shift 2;; --genesis-time) GENESIS_TIME="$2"; shift 2;;
  --output-dir) OUTPUT="$2"; shift 2;; --config-file) CONFIG_FILE="$2"; shift 2;; --candidate-only) CANDIDATE_ONLY=true; shift;; *) usage; exit 2;;
 esac
done
[[ -s "$INVENTORY" && -d "$IDENTITIES" && -d "$SECRETS" && -n "$GENESIS_TIME" && -n "$OUTPUT" ]] || { usage; exit 2; }
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -s "$CONFIG_FILE" ]] || { echo "Genesis config file is missing or empty: $CONFIG_FILE" >&2; exit 2; }
  jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null || { echo 'Genesis config must be a JSON object' >&2; exit 2; }
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFERENCED_CLI="${GDC_GENESIS_INFERENCED_CLI:-$ROOT/scripts/inferenced.sh}"
source "$ROOT/scripts/lib.sh"
# shellcheck disable=SC1090
source "$INVENTORY"
[[ "$GENESIS_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo 'genesis time must be UTC RFC3339 seconds' >&2; exit 2; }
GENESIS_EPOCH="$(date -u -d "$GENESIS_TIME" +%s)"
NOW_EPOCH="$(date -u +%s)"
(( GENESIS_EPOCH > NOW_EPOCH )) || {
  echo 'genesis time must be in the future' >&2
  exit 2
}
GENESIS_NODE="${GENESIS_NODE:?inventory must define GENESIS_NODE}"
GENESIS_PUBLIC_HOST="${GENESIS_PUBLIC_HOST:?inventory must define GENESIS_PUBLIC_HOST}"
GENESIS_P2P_PORT="${GENESIS_P2P_PORT:?inventory must define GENESIS_P2P_PORT}"
[[ -s "$IDENTITIES/$GENESIS_NODE.json" ]] || { echo "Missing identity $GENESIS_NODE.json" >&2; exit 1; }
GENESIS_ACCOUNT="$GDC_HOME/accounts/$GENESIS_NODE-cold.json"
GATEWAY_ACCOUNT="$GDC_HOME/accounts/gdc-gateway-cold.json"
FAUCET_ACCOUNT="$GDC_HOME/accounts/gdc-faucet-cold.json"
[[ -s "$GENESIS_ACCOUNT" && -s "$GATEWAY_ACCOUNT" && -s "$FAUCET_ACCOUNT" ]] || { echo 'Create cold accounts first' >&2; exit 1; }
GENESIS_ADDRESS="$(jq -r .address "$GENESIS_ACCOUNT")"
GATEWAY_ADDRESS="$(jq -r .address "$GATEWAY_ACCOUNT")"
FAUCET_ADDRESS="$(jq -r .address "$FAUCET_ACCOUNT")"
GENESIS_ID="$(jq -r .node_id "$IDENTITIES/$GENESIS_NODE.json")"
GENESIS_CONSENSUS="$(jq -r .consensus_pubkey "$IDENTITIES/$GENESIS_NODE.json")"
GENESIS_WARM="$(jq -r .warm_address "$IDENTITIES/$GENESIS_NODE.json")"
GENESIS_GUARDIAN_ENABLED="${GDC_GENESIS_GUARDIAN_ENABLED:-false}"
[[ "$GENESIS_GUARDIAN_ENABLED" =~ ^(true|false)$ ]] || { echo 'GDC_GENESIS_GUARDIAN_ENABLED must be true or false' >&2; exit 2; }
GENESIS_GUARDIAN_ADDRESS=''
GENESIS_GUARDIAN_ADDRESSES='[]'
PASSWORD_FILE="$SECRETS/operator.keyring"; [[ -s "$PASSWORD_FILE" ]] || exit 1; PASSWORD="$(<"$PASSWORD_FILE")"
if [[ "$CANDIDATE_ONLY" == true && -z "${INFERENCED_HOME:-}" ]]; then
  echo 'candidate-only genesis build requires an explicit isolated INFERENCED_HOME' >&2
  exit 2
fi
INFERENCED_HOME="${INFERENCED_HOME:-$STATE/operator-home}"
mkdir -p "$INFERENCED_HOME"
[[ "$CANDIDATE_ONLY" == true ]] || mkdir -p "$GDC_HOME/genesis"
LOG="$STATE/logs/genesis.log"
mkdir -p "$(dirname "$LOG")"
: >"$LOG"
run_logged() {
  "$@" >>"$LOG" 2>&1 || {
    echo "FAILED  Genesis build; details: $LOG" >&2
    return 1
  }
}
rm -rf "$INFERENCED_HOME/config" "$INFERENCED_HOME/data"

run_logged "$INFERENCED_CLI" init "$GENESIS_NODE" --chain-id "$CHAIN_ID" --default-denom "${BASE_DENOM:-ngonka}" --overwrite
GENESIS_GUARDIAN_ADDRESS="$(printf '%s\n' "$PASSWORD" | "$INFERENCED_CLI" keys show "${GENESIS_NODE}-cold" --bech val -a --keyring-backend file)"
[[ "$GENESIS_GUARDIAN_ADDRESS" =~ ^gonkavaloper1[0-9a-z]{20,90}$ ]] \
  || { echo 'failed to derive the Genesis guardian validator operator address' >&2; exit 1; }
if [[ "$GENESIS_GUARDIAN_ENABLED" == true ]]; then
  GENESIS_GUARDIAN_ADDRESSES="[\"$GENESIS_GUARDIAN_ADDRESS\"]"
fi
OVERLAY="$(mktemp)"; IMPORTED_CONFIG="$(mktemp)"; trap 'rm -f "$OVERLAY" "$IMPORTED_CONFIG"' EXIT
if [[ -n "$CONFIG_FILE" ]]; then
  jq 'if has("consensus_params") then .consensus = ((.consensus // {}) + {params:.consensus_params}) | del(.consensus_params) else . end
    | .app_state.inference.model_list |= map(.proposed_by = "genesis")' \
    "$CONFIG_FILE" > "$IMPORTED_CONFIG"
else
  printf '{}\n' > "$IMPORTED_CONFIG"
fi
RENDER_ARGS=(--gateway-account "$GATEWAY_ADDRESS" --genesis-guardian "$GENESIS_GUARDIAN_ADDRESS")
[[ -z "$CONFIG_FILE" ]] || RENDER_ARGS+=(--config-file "$CONFIG_FILE")
"$ROOT/01-identities-genesis/render-genesis-overrides.sh" "${RENDER_ARGS[@]}" --output "$OVERLAY" >/dev/null
OVERLAY_SHA256="$(sha256sum "$OVERLAY" | awk '{print $1}')"
"$ROOT/01-identities-genesis/deep-merge-json.sh" "$INFERENCED_HOME/config/genesis.json" "$OVERLAY" "$INFERENCED_HOME/config/genesis.merged.json"
mv "$INFERENCED_HOME/config/genesis.merged.json" "$INFERENCED_HOME/config/genesis.json"

# The faucet is a bounded public test-token reserve. It funds registered Hosts
# automatically; it is not an approval authority and never holds Host keys.
FAUCET_INITIAL_NGONKA="${GDC_FAUCET_INITIAL_NGONKA:-5000000000000}"
[[ "$FAUCET_INITIAL_NGONKA" =~ ^[1-9][0-9]*$ ]] || { echo 'GDC_FAUCET_INITIAL_NGONKA must be positive' >&2; exit 2; }
run_logged "$INFERENCED_CLI" genesis add-genesis-account "$GENESIS_ADDRESS" 1000000000000ngonka
run_logged "$INFERENCED_CLI" genesis add-genesis-account "$GATEWAY_ADDRESS" 100000000000ngonka
run_logged "$INFERENCED_CLI" genesis add-genesis-account "$FAUCET_ADDRESS" "${FAUCET_INITIAL_NGONKA}ngonka"

printf '%s\n' "$PASSWORD" | run_logged "$INFERENCED_CLI" genesis gentx \
  "${GENESIS_NODE}-cold" 1ngonka --keyring-backend file --moniker "$GENESIS_NODE" \
  --pubkey "$GENESIS_CONSENSUS" --ml-operational-address "$GENESIS_WARM" \
  --url "https://${GENESIS_PUBLIC_HOST}" --chain-id "$CHAIN_ID" --node-id "$GENESIS_ID"

run_logged "$INFERENCED_CLI" genesis collect-gentxs --gentx-dir "$INFERENCED_HOME/config/gentx"
run_logged "$INFERENCED_CLI" genesis patch-genesis --genparticipant-dir "$INFERENCED_HOME/config/genparticipant"

# patch-genesis rebuilds app_state from its source data and may discard
# allowlisted configuration fields. Reapply the reviewed overlay afterward;
# state fields remain owned by the CLI and the invariant check below.
POST_PATCH="$(mktemp)"
"$ROOT/01-identities-genesis/deep-merge-json.sh" \
  "$INFERENCED_HOME/config/genesis.json" "$OVERLAY" "$POST_PATCH"
mv "$POST_PATCH" "$INFERENCED_HOME/config/genesis.json"

UPDATED_GENESIS="$(mktemp)"
jq --arg chain "$CHAIN_ID" --arg time "$GENESIS_TIME" \
  '.chain_id = $chain | .genesis_time = $time' \
  "$INFERENCED_HOME/config/genesis.json" >"$UPDATED_GENESIS"
mv "$UPDATED_GENESIS" "$INFERENCED_HOME/config/genesis.json"
run_logged "$INFERENCED_CLI" genesis validate-genesis

jq -e --arg genesis "$GENESIS_ADDRESS" --arg gateway "$GATEWAY_ADDRESS" --arg faucet "$FAUCET_ADDRESS" --arg chain "$CHAIN_ID" \
  --arg time "$GENESIS_TIME" --arg faucet_amount "$FAUCET_INITIAL_NGONKA" \
  --argjson guardian_enabled "$GENESIS_GUARDIAN_ENABLED" --argjson guardian_addresses "$GENESIS_GUARDIAN_ADDRESSES" \
  --slurpfile imported "$IMPORTED_CONFIG" '
  def leaves_match($want; $got):
    if ($want|type) == "object" then
      all($want|keys[]; . as $key | ($want[$key] | leaves_match(.; $got[$key])))
    elif ($want|type) == "array" then $want == $got
    else $want == $got end;
  .chain_id == $chain
  and .genesis_time == $time
  and (.app_state.bank.balances | any(.address == $faucet and .coins == [{"denom":"ngonka","amount":$faucet_amount}]))
  and (.app_state.inference.participant_list | length) == 1
  and .app_state.inference.participant_list[0].address == $genesis
  and (if ($imported|length) == 0 then
    [.app_state.inference.model_list[].id] == ["Qwen/Qwen3-0.6B"]
    and .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses == []
    and .app_state.inference.params.devshard_escrow_params.approved_versions == []
    and .app_state.inference.devshard_approved_versions == []
    and .app_state.inference.params.poc_params.poc_v2_enabled == true
    and .app_state.inference.params.poc_params.confirmation_poc_v2_enabled == true
    and .app_state.inference.params.confirmation_poc_params.expected_confirmations_per_epoch == "1"
    and .app_state.inference.params.confirmation_poc_params.slash_fraction == {"value":"0","exponent":0}
    and .app_state.inference.params.confirmation_poc_params.upgrade_protection_window == "20"
    else leaves_match($imported[0]; .) end)
  and .app_state.inference.params.genesis_guardian_params.guardian_addresses == $guardian_addresses
  and .app_state.inference.genesis_only_params.genesis_guardian_enabled == $guardian_enabled
  and .app_state.inference.genesis_only_params.genesis_guardian_addresses == $guardian_addresses
  and (.app_state.genutil.gen_txs | length) == 1
' "$INFERENCED_HOME/config/genesis.json" >/dev/null
echo 'Genesis invariants: PASS'

mkdir -p "$OUTPUT"
printf '%s@%s:%s\n' "$GENESIS_ID" "$GENESIS_PUBLIC_HOST" "$GENESIS_P2P_PORT" >"$OUTPUT/genesis-seeds.txt"
install -m 0444 "$INFERENCED_HOME/config/genesis.json" "$OUTPUT/genesis.json"
sha256sum "$OUTPUT/genesis.json" | awk '{print $1"  genesis.json"}' > "$OUTPUT/genesis.sha256"

jq -n \
 --arg chain_id "$CHAIN_ID" --arg genesis_time "$GENESIS_TIME" \
 --arg genesis "$GENESIS_ADDRESS" --arg genesis_guardian "$GENESIS_GUARDIAN_ADDRESS" --arg gateway "$GATEWAY_ADDRESS" --arg faucet "$FAUCET_ADDRESS" \
 --arg hash "$(cut -d' ' -f1 "$OUTPUT/genesis.sha256")" \
 --arg overrides_hash "$OVERLAY_SHA256" \
 --arg config_hash "$(if [[ -n "$CONFIG_FILE" ]]; then sha256sum "$CONFIG_FILE" | awk '{print $1}'; else printf ''; fi)" \
 '{chain_id:$chain_id,genesis_time:$genesis_time,genesis_validator:$genesis,genesis_guardian_validator:$genesis_guardian,gateway_account:$gateway,faucet_account:$faucet,genesis_sha256:$hash,genesis_overrides_sha256:$overrides_hash,genesis_config_sha256:$config_hash}' \
 > "$OUTPUT/ceremony-record.json"
if [[ "$CANDIDATE_ONLY" != true && "$(readlink -f "$OUTPUT")" != "$(readlink -f "$GDC_HOME/genesis")" ]]; then
  cp -f "$OUTPUT"/* "$GDC_HOME/genesis/"
fi
printf '\nFINAL GENESIS SHA-256: '; cat "$OUTPUT/genesis.sha256"
printf 'GENESIS OVERRIDES SHA-256: %s\n' "$OVERLAY_SHA256"
printf 'Distribute genesis.json, genesis.sha256 and genesis-seeds.txt to all network hosts before genesis_time.\n'
