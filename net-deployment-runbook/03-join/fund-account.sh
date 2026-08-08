#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 JOIN_ACCOUNT_JSON inventory.env [amount-ngonka]" >&2; }
[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
ACCOUNT_JSON="$1"; INVENTORY="$2"; AMOUNT="${3:-100000000000}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
PASSWORD="$(<"$ROOT/state/secrets/operator.keyring")"
ADDRESS="$(jq -r .address "$ACCOUNT_JSON")"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]+$ && "$AMOUNT" =~ ^[0-9]+$ ]] || exit 2
# Registration must happen first. Funding before it creates the account and makes
# SubmitNewUnfundedParticipant reject with AccountAlreadyExists.
TX="$(printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" tx bank send \
  "$GENESIS_NODE-cold" "$ADDRESS" "${AMOUNT}ngonka" \
  --from "$GENESIS_NODE-cold" --keyring-backend file --chain-id "$CHAIN_ID" \
  --node "https://${GENESIS_PUBLIC_HOST}/chain-rpc/" \
  --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka \
  --broadcast-mode sync --output json --yes)"
HASH="$(jq -r '.txhash // .tx_response.txhash // empty' <<<"$TX")"
[[ "$HASH" =~ ^[0-9A-Fa-f]{64}$ ]] || { jq . <<<"$TX" >&2; echo 'Cannot obtain funding transaction hash' >&2; exit 1; }
RESULT=''
for _ in $(seq 1 60); do
  RESULT="$("$ROOT/scripts/inferenced.sh" query tx "$HASH" \
    --node "https://${GENESIS_PUBLIC_HOST}/chain-rpc/" --output json 2>/dev/null || true)"
  [[ -n "$RESULT" ]] && break
  sleep 2
done
[[ -n "$RESULT" ]] || { echo "Funding transaction $HASH was not committed" >&2; exit 1; }
CODE="$(jq -r '.code // .tx_response.code // 0' <<<"$RESULT")"
[[ "$CODE" == 0 ]] || { jq . <<<"$RESULT" >&2; exit 1; }
printf 'PASS funded %s with %sngonka tx=%s\n' "$ADDRESS" "$AMOUNT" "$HASH"
