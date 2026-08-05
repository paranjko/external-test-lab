#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 JOIN_ACCOUNT_JSON inventory.env [amount-ngonka]" >&2; }
[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
ACCOUNT_JSON="$1"; INVENTORY="$2"; AMOUNT="${3:-100000000000}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$INVENTORY"
PASSWORD="$(<"$ROOT/state/secrets/operator.keyring")"
ADDRESS="$(jq -r .address "$ACCOUNT_JSON")"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]+$ && "$AMOUNT" =~ ^[0-9]+$ ]] || exit 2
# Registration must happen first. Funding before it creates the account and makes
# SubmitNewUnfundedParticipant reject with AccountAlreadyExists.
printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" tx bank send \
  gdc-node0-cold "$ADDRESS" "${AMOUNT}ngonka" \
  --from gdc-node0-cold --keyring-backend file --chain-id "$CHAIN_ID" \
  --node "https://${NODE0_PUBLIC_HOST}/chain-rpc/" \
  --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --yes
