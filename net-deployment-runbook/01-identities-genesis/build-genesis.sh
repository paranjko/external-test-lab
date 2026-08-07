#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ cat >&2 <<'EOF'
Usage: ./build-genesis.sh --inventory inventory.env --identities-dir DIR \
  --secrets-dir DIR --genesis-time 2026-08-01T12:00:00Z --output-dir DIR
EOF
}
INVENTORY=""; IDENTITIES=""; SECRETS=""; GENESIS_TIME=""; OUTPUT=""
while (($#)); do
 case "$1" in
  --inventory) INVENTORY="$2"; shift 2;; --identities-dir) IDENTITIES="$2"; shift 2;;
  --secrets-dir) SECRETS="$2"; shift 2;; --genesis-time) GENESIS_TIME="$2"; shift 2;;
  --output-dir) OUTPUT="$2"; shift 2;; *) usage; exit 2;;
 esac
done
[[ -s "$INVENTORY" && -d "$IDENTITIES" && -d "$SECRETS" && -n "$GENESIS_TIME" && -n "$OUTPUT" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$INVENTORY"
[[ "$GENESIS_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo 'genesis time must be UTC RFC3339 seconds' >&2; exit 2; }
GENESIS_EPOCH="$(date -u -d "$GENESIS_TIME" +%s)"
NOW_EPOCH="$(date -u +%s)"
(( GENESIS_EPOCH > NOW_EPOCH )) || {
  echo 'genesis time must be in the future' >&2
  exit 2
}
[[ -s "$IDENTITIES/gdc-node0.json" ]] || { echo 'Missing identity gdc-node0.json' >&2; exit 1; }
NODE0_ACCOUNT="$ROOT/artifacts/accounts/gdc-node0-cold.json"
GATEWAY_ACCOUNT="$ROOT/artifacts/accounts/gdc-gateway-cold.json"
[[ -s "$NODE0_ACCOUNT" && -s "$GATEWAY_ACCOUNT" ]] || { echo 'Create cold accounts first' >&2; exit 1; }
NODE0_ADDRESS="$(jq -r .address "$NODE0_ACCOUNT")"
GATEWAY_ADDRESS="$(jq -r .address "$GATEWAY_ACCOUNT")"
NODE0_ID="$(jq -r .node_id "$IDENTITIES/gdc-node0.json")"
NODE0_CONSENSUS="$(jq -r .consensus_pubkey "$IDENTITIES/gdc-node0.json")"
NODE0_WARM="$(jq -r .warm_address "$IDENTITIES/gdc-node0.json")"
GENESIS_GUARDIAN_ENABLED="${GDC_GENESIS_GUARDIAN_ENABLED:-false}"
[[ "$GENESIS_GUARDIAN_ENABLED" =~ ^(true|false)$ ]] || { echo 'GDC_GENESIS_GUARDIAN_ENABLED must be true or false' >&2; exit 2; }
GENESIS_GUARDIAN_ADDRESSES='[]'
[[ "$GENESIS_GUARDIAN_ENABLED" == true ]] && GENESIS_GUARDIAN_ADDRESSES="[\"$NODE0_ADDRESS\"]"
PASSWORD_FILE="$SECRETS/operator.keyring"; [[ -s "$PASSWORD_FILE" ]] || exit 1; PASSWORD="$(<"$PASSWORD_FILE")"
HOME_DIR="${GDC_OPERATOR_HOME:-$ROOT/state/operator-home}"
mkdir -p "$HOME_DIR" "$OUTPUT" "$ROOT/artifacts/genesis"
LOG="$ROOT/state/logs/genesis.log"
mkdir -p "$(dirname "$LOG")"
: >"$LOG"
run_logged() {
  "$@" >>"$LOG" 2>&1 || {
    echo "FAILED  Genesis build; details: $LOG" >&2
    return 1
  }
}
rm -rf "$HOME_DIR/config" "$HOME_DIR/data"

run_logged "$ROOT/scripts/inferenced.sh" init gdc-node0 --chain-id "$CHAIN_ID" --default-denom "${BASE_DENOM:-ngonka}" --overwrite
OVERLAY="$(mktemp)"; trap 'rm -f "$OVERLAY"' EXIT
"$ROOT/01-identities-genesis/render-genesis-overrides.sh" \
  --gateway-account "$GATEWAY_ADDRESS" --genesis-guardian "$NODE0_ADDRESS" --output "$OVERLAY" >/dev/null
OVERLAY_SHA256="$(sha256sum "$OVERLAY" | awk '{print $1}')"
"$ROOT/01-identities-genesis/deep-merge-json.sh" "$HOME_DIR/config/genesis.json" "$OVERLAY" "$HOME_DIR/config/genesis.merged.json"
mv "$HOME_DIR/config/genesis.merged.json" "$HOME_DIR/config/genesis.json"

# Only the sole genesis validator and the gateway are funded at genesis.
run_logged "$ROOT/scripts/inferenced.sh" genesis add-genesis-account "$NODE0_ADDRESS" 1000000000000ngonka
run_logged "$ROOT/scripts/inferenced.sh" genesis add-genesis-account "$GATEWAY_ADDRESS" 100000000000ngonka

printf '%s\n' "$PASSWORD" | run_logged "$ROOT/scripts/inferenced.sh" genesis gentx \
  gdc-node0-cold 1ngonka --keyring-backend file --moniker gdc-node0 \
  --pubkey "$NODE0_CONSENSUS" --ml-operational-address "$NODE0_WARM" \
  --url "https://${NODE0_PUBLIC_HOST}" --chain-id "$CHAIN_ID" --node-id "$NODE0_ID"

run_logged "$ROOT/scripts/inferenced.sh" genesis collect-gentxs --gentx-dir /home/gdc/.inference/config/gentx
run_logged "$ROOT/scripts/inferenced.sh" genesis patch-genesis --genparticipant-dir /home/gdc/.inference/config/genparticipant

UPDATED_GENESIS="$(mktemp)"
jq --arg chain "$CHAIN_ID" --arg time "$GENESIS_TIME" \
  '.chain_id = $chain | .genesis_time = $time' \
  "$HOME_DIR/config/genesis.json" >"$UPDATED_GENESIS"
mv "$UPDATED_GENESIS" "$HOME_DIR/config/genesis.json"
run_logged "$ROOT/scripts/inferenced.sh" genesis validate-genesis

printf '%s@%s:%s\n' "$NODE0_ID" "$NODE0_PUBLIC_HOST" "$NODE0_P2P_PORT" >"$OUTPUT/genesis-seeds.txt"
install -m 0444 "$HOME_DIR/config/genesis.json" "$OUTPUT/genesis.json"
sha256sum "$OUTPUT/genesis.json" | awk '{print $1"  genesis.json"}' > "$OUTPUT/genesis.sha256"

jq -e --arg node0 "$NODE0_ADDRESS" --arg gateway "$GATEWAY_ADDRESS" --arg chain "$CHAIN_ID" \
  --argjson guardian_enabled "$GENESIS_GUARDIAN_ENABLED" --argjson guardian_addresses "$GENESIS_GUARDIAN_ADDRESSES" '
  .chain_id == $chain
  and (.app_state.inference.participant_list | length) == 1
  and .app_state.inference.participant_list[0].address == $node0
  and [.app_state.inference.model_list[].id] == ["Qwen/Qwen3-0.6B"]
  and .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses == []
  and .app_state.inference.params.devshard_escrow_params.approved_versions == []
  and .app_state.inference.params.poc_params.poc_v2_enabled == true
  and .app_state.inference.params.genesis_guardian_params.guardian_addresses == $guardian_addresses
  and .app_state.inference.genesis_only_params.genesis_guardian_enabled == $guardian_enabled
  and .app_state.inference.genesis_only_params.genesis_guardian_addresses == $guardian_addresses
  and (.app_state.genutil.gen_txs | length) == 1
' "$OUTPUT/genesis.json" >/dev/null
echo 'Genesis invariants: PASS'

jq -n \
 --arg chain_id "$CHAIN_ID" --arg genesis_time "$GENESIS_TIME" \
 --arg node0 "$NODE0_ADDRESS" --arg gateway "$GATEWAY_ADDRESS" \
 --arg hash "$(cut -d' ' -f1 "$OUTPUT/genesis.sha256")" \
 --arg overrides_hash "$OVERLAY_SHA256" \
 '{chain_id:$chain_id,genesis_time:$genesis_time,genesis_validator:$node0,gateway_account:$gateway,genesis_sha256:$hash,genesis_overrides_sha256:$overrides_hash}' \
 > "$OUTPUT/ceremony-record.json"
if [[ "$(readlink -f "$OUTPUT")" != "$(readlink -f "$ROOT/artifacts/genesis")" ]]; then
  cp -f "$OUTPUT"/* "$ROOT/artifacts/genesis/"
fi
printf '\nFINAL GENESIS SHA-256: '; cat "$OUTPUT/genesis.sha256"
printf 'GENESIS OVERRIDES SHA-256: %s\n' "$OVERLAY_SHA256"
printf 'Distribute genesis.json, genesis.sha256 and genesis-seeds.txt to all network hosts before genesis_time.\n'
