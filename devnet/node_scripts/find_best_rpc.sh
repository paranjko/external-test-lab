#!/bin/bash

set -e

SEED_RPC=(
"http://node1.gonka.ai:8000"
"http://node2.gonka.ai:8000"
"http://node3.gonka.ai:8000"
"http://gonka.spv.re:8000"
)

TMP_DISCOVER=$(mktemp)
TMP_RPC=$(mktemp)

echo "Discovering RPC nodes..."

discover(){

RPC=$1

PEERS=$(curl -s "$RPC/chain-rpc/net_info" | jq -r '.result.peers[].remote_ip' 2>/dev/null || true)

for IP in $PEERS
do
 echo "http://$IP:8000" >> "$TMP_DISCOVER"
done

}

for RPC in "${SEED_RPC[@]}"
do
 discover "$RPC" &
done

wait

RPC_CANDIDATES=($(printf "%s\n" "${SEED_RPC[@]}" $(sort -u "$TMP_DISCOVER")))

echo "Found ${#RPC_CANDIDATES[@]} RPC candidates"
echo

check_rpc(){

RPC=$1

START=$(date +%s%3N)

STATUS=$(curl -s --max-time 4 "$RPC/chain-rpc/status")

echo "$STATUS" | grep -q '"result"' || return

CATCH=$(echo "$STATUS" | jq -r '.result.sync_info.catching_up')
HEIGHT=$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_height')

[ "$CATCH" != "false" ] && return
[ "$HEIGHT" -le 0 ] && return

NET=$(curl -s "$RPC/chain-rpc/net_info")
PEERS=$(echo "$NET" | jq -r '.result.n_peers')

[ "$PEERS" -lt 5 ] && return

VALIDATORS=$(curl -s "$RPC/chain-rpc/validators" | jq '.result.validators | length')

[ "$VALIDATORS" -le 0 ] && return

BLOCK_TIME=$(curl -s "$RPC/chain-rpc/block" | jq -r '.result.block.header.time')

NOW=$(date -u +%s)
BLOCK_TS=$(date -d "$BLOCK_TIME" +%s)

AGE=$((NOW - BLOCK_TS))

[ "$AGE" -gt 25 ] && return

END=$(date +%s%3N)

LATENCY=$((END-START))

echo "$HEIGHT $LATENCY $AGE $RPC" >> "$TMP_RPC"

}

echo "Checking RPC..."

for RPC in "${RPC_CANDIDATES[@]}"
do
 check_rpc "$RPC" &
done

wait

if [ ! -s "$TMP_RPC" ]; then
 echo "No healthy RPC found"
 exit 1
fi

MAX_HEIGHT=$(awk '{print $1}' "$TMP_RPC" | sort -nr | head -n1)

echo
echo "RPC status:"
echo

printf "%-30s %-10s %-10s %-10s\n" "RPC" "HEIGHT" "AGE(s)" "LAT(ms)"

awk -v max="$MAX_HEIGHT" '
{
 lag=max-$1
 if(lag<=3)
 printf "%-30s %-10s %-10s %-10s\n",$4,$1,$3,$2
}' "$TMP_RPC" | sort -k4 -n

echo
echo "Best RPC:"

BEST=$(awk -v max="$MAX_HEIGHT" '
{
 lag=max-$1
 if(lag<=3)
 print $2,$4
}' "$TMP_RPC" | sort -n)

RPC1=$(echo "$BEST" | head -n1 | awk '{print $2}')
RPC2=$(echo "$BEST" | head -n2 | tail -n1 | awk '{print $2}')

echo
echo "RPC_SERVER_URL_1=$RPC1/chain-rpc/"
echo "RPC_SERVER_URL_2=$RPC2/chain-rpc/"
