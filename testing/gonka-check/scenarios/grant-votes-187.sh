#!/usr/bin/env bash
# Vote grants for the live run of a group size change, run by the holder of the genesis guardian cold keys: lets
# the run account send MsgVote for each guardian (nothing else), funds its two proposal deposits, shows or revokes.
set -euo pipefail

GRANTEE=${GRANTEE:-gonka1ceu72ff6llfg2yxfxh8yvfza9yzfkq2t07k2cd}
NODES=${NODES:-gdc-node0 gdc-node1 gdc-node4 gdc-node7}
GDC_DATA_ROOT=${GDC_DATA_ROOT:-$HOME/.gdc-data}
INFERENCED=${INFERENCED:-inferenced}
CHAIN=${CHAIN:-https://api.gonka-dev.net}
CHAIN_ID=${CHAIN_ID:-gonka-devnet-community}
DAYS=${DAYS:-7}
FUND=${FUND:-10000000ngonka}
MSG=/cosmos.gov.v1.MsgVote

usage() { echo "usage: $0 show|grant|revoke [--yes]" >&2; exit 2; }
action=${1:-show}
yes=${2:-}
case $action in show|grant|revoke) ;; *) usage ;; esac

# guardians: account address of each genesis guardian, from the live parameters.
guardians() {
  curl -fsS --max-time 20 "$CHAIN/chain-api/productscience/inference/inference/params" | python3 -c '
import json, sys
CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(v):
    g, c = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3], 1
    for x in v:
        b, c = c >> 25, (c & 0x1ffffff) << 5 ^ x
        for i in range(5):
            c ^= g[i] if (b >> i) & 1 else 0
    return c
for valoper in json.load(sys.stdin)["params"]["genesis_guardian_params"]["guardian_addresses"]:
    data = [CH.find(x) for x in valoper.rsplit("1", 1)[1]][:-6]
    hrp = [ord(x) >> 5 for x in "gonka"] + [0] + [ord(x) & 31 for x in "gonka"]
    p = polymod(hrp + data + [0] * 6) ^ 1
    print("gonka1" + "".join(CH[x] for x in data + [(p >> 5 * (5 - i)) & 31 for i in range(6)]))'
}

show() {
  local g
  for g in $(guardians); do
    curl -fsS --max-time 20 "$CHAIN/chain-api/cosmos/authz/v1beta1/grants?granter=$g&grantee=$GRANTEE&msg_type_url=$MSG" \
      | python3 -c 'import json,sys; g=json.load(sys.stdin).get("grants") or []; print(sys.argv[1], "vote grant until", g[0]["expiration"] if g else "none")' "$g"
  done
  curl -fsS --max-time 20 "$CHAIN/chain-api/cosmos/bank/v1beta1/balances/$GRANTEE" \
    | python3 -c 'import json,sys; print(sys.argv[1], "balance", [c["amount"] + c["denom"] for c in json.load(sys.stdin)["balances"]] or "0")' "$GRANTEE"
}

if [ "$action" = show ]; then show; exit 0; fi

command -v "$INFERENCED" >/dev/null || { echo "inferenced not found: set INFERENCED" >&2; exit 2; }
known=$(guardians)
expiration=$(python3 -c "import time; print(int(time.time()) + $DAYS * 86400)")
echo "$action vote grants to $GRANTEE from: $NODES"
[ "$action" = grant ] && echo "grants end in $DAYS days; $FUND to $GRANTEE for the proposal deposits"
if [ "$yes" != --yes ]; then
  printf 'Type yes: '
  read -r answer
  [ "$answer" = yes ] || { echo "not confirmed" >&2; exit 1; }
fi

funded=0
for node in $NODES; do
  home=$GDC_DATA_ROOT/$node
  address=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"])' "$home/accounts/$node-cold.json")
  if ! grep -qx "$address" <<<"$known"; then
    echo "$node: $address is not a genesis guardian, skipped"
    continue
  fi
  sign() {
    printf '%s\n' "$(<"$home/state/secrets/operator.keyring")" \
      | "$INFERENCED" "$@" --from "$node-cold" --keyring-backend file --home "$home/state/operator-home" \
        --chain-id "$CHAIN_ID" --node "$CHAIN/chain-rpc/" --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka \
        --broadcast-mode sync --output json --yes \
      | python3 -c 'import json,sys; r=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(sys.argv[1], "code", r.get("code"), "tx", r.get("txhash"), r.get("raw_log") or "")' "$node"
  }
  if [ "$action" = grant ]; then
    sign tx authz grant "$GRANTEE" generic --msg-type="$MSG" --expiration "$expiration"
    if [ "$funded" = 0 ]; then
      sleep 7
      sign tx bank send "$node-cold" "$GRANTEE" "$FUND"
      funded=1
    fi
  else
    sign tx authz revoke "$GRANTEE" "$MSG"
  fi
  sleep 7
done
sleep 7
show
