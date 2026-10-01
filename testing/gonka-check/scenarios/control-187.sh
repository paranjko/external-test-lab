#!/usr/bin/env bash
# Control run at group size 5 on gateway A: one escrow created and settled through the gateway admin API, then
# gcheck escrow record and verdict. Reads only unless --run; the gateway keys never leave the gateway host.
set -euo pipefail

GATEWAY_HOST=${GATEWAY_HOST:-gdc-node4}
GATEWAY_DIR=${GATEWAY_DIR:-/srv/dai/broker-tests/ds502-a}
GATEWAY_PORT=${GATEWAY_PORT:-18087}
CHAIN=${CHAIN:-https://api.gonka-dev.net}
GCHECK=${GCHECK:-$(cd "$(dirname "$0")/.." && pwd)/bin/gcheck}
RUN_ROOT=${RUN_ROOT:-$HOME/gonka-187-runs}
SSH=${SSH:-ssh}
REQUESTS=${REQUESTS:-2}
API=/chain-api/productscience/inference/inference
FIRST=20

mode=dry wait=0 yes=0 amount=""
usage() { echo "usage: $0 [--run] [--yes] [--wait] [--amount NGONKA]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --run) mode=run ;;
    --yes) yes=1 ;;
    --wait) wait=1 ;;
    --amount) [ $# -ge 2 ] || usage; amount=$2; shift ;;
    *) usage ;;
  esac
  shift
done

for tool in curl python3 base64 "$SSH"; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done
[ -x "$GCHECK" ] || { echo "gcheck not found: $GCHECK" >&2; exit 2; }

run_dir="$RUN_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-control-$mode"
mkdir -p "$run_dir"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$run_dir/control.log"; }
die() { log "STOP: $*"; exit 1; }
stop() { if [ "$mode" = dry ]; then log "would stop: $*"; else die "$*"; fi; }

# jget FILE PATH: one value from a JSON file by a dotted path, empty when absent.
jget() {
  python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    if isinstance(value, list) and part.isdigit() and int(part) < len(value):
        value = value[int(part)]
    elif isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
    if value is None:
        break
print("" if value is None else json.dumps(value) if isinstance(value, (dict, list)) else value)
PY
}

chain() { curl -fsS --max-time 20 "$CHAIN$1"; }

# cycle: "height epoch start length offset" from the chain's own PoC start, not height % length.
cycle() {
  chain "$API/epoch_info" > "$run_dir/epoch_info.json"
  python3 - "$run_dir/epoch_info.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
height, start = int(body["block_height"]), int(body["latest_epoch"]["poc_start_block_height"])
print(height, body["latest_epoch"]["index"], start, body["params"]["epoch_params"]["epoch_length"], height - start)
PY
}

# gw NAME METHOD PATH admin|client [BODY]: one call on the gateway host, key on curl's stdin; body to NAME.json.
gw() {
  local out=/dev/null
  [ "$1" = - ] || out="$run_dir/$1.json"
  "$SSH" -o BatchMode=yes "$GATEWAY_HOST" bash -s -- "$GATEWAY_DIR" "$GATEWAY_PORT" "$2" "$3" "$4" \
    "$(printf %s "${5:-}" | base64 | tr -d '\n')" > "$run_dir/gw.reply" <<'REMOTE' || true
set -eu
dir=$1 port=$2 method=$3 path=$4 auth=$5
body=$(printf %s "${6:-}" | base64 -d)
var=DEVSHARD_ADMIN_API_KEY
[ "$auth" = client ] && var=DEVSHARD_API_KEYS
key=$(sed -n -E "s/^(export[[:space:]]+)?$var=//p" "$dir/gateway.env" | head -n 1 | tr -d '"'"'"' \r')
key=${key%%,*}
out=$(mktemp)
set -- -sS --max-time 600 -o "$out" -w '%{http_code}' -X "$method" -H @- "http://127.0.0.1:$port$path"
[ -n "$body" ] && set -- "$@" -H 'Content-Type: application/json' --data-binary "$body"
code=$(printf 'Authorization: Bearer %s\n' "$key" | curl "$@") || code=000
printf '%s\n' "$code"
cat "$out"
rm -f "$out"
REMOTE
  tail -n +2 "$run_dir/gw.reply" > "$out"
  head -n 1 "$run_dir/gw.reply"
  rm -f "$run_dir/gw.reply"
}

log "run $run_dir, mode $mode"
log "1/8 chain checks; gcheck preflight reads gateway A through the public edge and is kept for the record only"
set +e
"$GCHECK" escrow preflight --source devnet --gateway a --from 5 --need 1 2>&1 | tee -a "$run_dir/control.log"
log "gcheck preflight exit ${PIPESTATUS[0]}; the run does not depend on it"
set -e
chain "$API/params" > "$run_dir/params.json" || die "chain params are unreachable"
group_size=$(jget "$run_dir/params.json" params.devshard_escrow_params.group_size)
max_escrows=$(jget "$run_dir/params.json" params.devshard_escrow_params.max_escrows_per_epoch)
log "group_size $group_size, max_escrows_per_epoch $max_escrows"
[ "$group_size" = 5 ] || stop "group_size is $group_size, the control runs at 5"

log "2/8 gateway A admin API on $GATEWAY_HOST:127.0.0.1:$GATEWAY_PORT"
code=$(gw - GET /v1/admin/state admin)
[ "$code" = 200 ] || die "admin API answered $code, expected 200"
code=$(gw rotation GET /v1/debug/rotation admin)
[ "$code" = 200 ] || die "rotation settings: HTTP $code"
read -r rot_enabled rot_settle pre_poc model rot_amount < <(python3 - "$run_dir/rotation.json" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))["settings"]
models = settings.get("models") or [{}]
print(settings["enabled"], settings["settlement_enabled"], settings["pre_poc_blocks"],
      models[0].get("model_id") or "-", models[0].get("amount") or 0)
PY
)
printf 'enabled %s\nsettlement_enabled %s\npre_poc_blocks %s\nmodel %s\namount %s\n' \
  "$rot_enabled" "$rot_settle" "$pre_poc" "$model" "$rot_amount" > "$run_dir/rotation.txt"
rm -f "$run_dir/rotation.json"
log "rotation enabled $rot_enabled, settlement_enabled $rot_settle, pre_poc_blocks $pre_poc, model $model, amount $rot_amount"
[ -n "$model" ] && [ "$model" != - ] || die "the gateway rotation has no model"
amount=${amount:-$rot_amount}
[[ $amount =~ ^[1-9][0-9]*$ ]] || die "escrow amount '$amount' is not a positive integer; pass --amount"

log "3/8 window"
read -r height epoch start length offset < <(cycle)
rotate_at=$((length + 19 - pre_poc))
latest=$((rotate_at - 60))
log "height $height, epoch $epoch, PoC start $start, P+$offset of $length; gateway rotation from P+$rotate_at"
if [ "$offset" -lt "$FIRST" ] || [ "$offset" -gt "$latest" ]; then
  if [ "$offset" -lt "$FIRST" ]; then left=$((FIRST - offset)); else left=$((length - offset + FIRST)); fi
  [ "$mode" = run ] && [ "$wait" = 1 ] || {
    log "outside the start window P+$FIRST..P+$latest; the next one opens in about $left blocks"
    [ "$mode" = dry ] || exit 3
  }
  if [ "$mode" = run ]; then
    log "waiting about $left blocks for P+$FIRST"
    for _ in $(seq 1 240); do
      sleep 15
      read -r height epoch start length offset < <(cycle)
      [ "$offset" -ge "$FIRST" ] && [ "$offset" -le "$latest" ] && break
    done
    [ "$offset" -ge "$FIRST" ] && [ "$offset" -le "$latest" ] || die "the window did not open in an hour"
    log "height $height, epoch $epoch, P+$offset"
  fi
fi

created=$(chain "/chain-rpc/tx_search?query=%22devshard_escrow_created.epoch_index=%27$epoch%27%22&per_page=1" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["total_count"])') || die "escrow count is unreadable"
log "epoch $epoch has $created of $max_escrows escrows"
[ $((max_escrows - created)) -ge 1 ] || stop "no free escrow place in epoch $epoch"

if [ "$mode" = dry ]; then
  log "plan: create an escrow of $amount ngonka for $model on gateway A, send $REQUESTS requests to /devshard/<id>,"
  log "      settle it before P+$rotate_at, then gcheck escrow record --a <id> --attempt a=<tx> and verdict"
  log "dry run: nothing sent; run with --run, add --wait to wait for the window"
  exit 0
fi

if [ "$yes" != 1 ]; then
  printf 'Create an escrow of %s ngonka for %s on gateway A in epoch %s and settle it? Type yes: ' \
    "$amount" "$model" "$epoch"
  read -r answer
  [ "$answer" = yes ] || die "not confirmed"
fi

log "4/8 create"
code=$(gw create POST /v1/admin/escrows admin "$(printf '{"amount":%s,"model_id":"%s"}' "$amount" "$model")")
[ "$code" = 200 ] || die "create: HTTP $code $(head -c 300 "$run_dir/create.json")"
escrow=$(jget "$run_dir/create.json" escrow_id) || die "create: unexpected reply $(head -c 300 "$run_dir/create.json")"
id=$(jget "$run_dir/create.json" id)
create_tx=$(jget "$run_dir/create.json" tx_hash)
log "escrow $escrow by $(jget "$run_dir/create.json" creator), tx $create_tx"
[ -n "$id" ] || die "the gateway did not register escrow $escrow"

log "5/8 escrow on chain"
for _ in $(seq 1 12); do
  chain "$API/devshard_escrow/$escrow" > "$run_dir/escrow.json" 2>/dev/null && break
  sleep 5
done
slots=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["escrow"]["slots"]))' "$run_dir/escrow.json") \
  || die "escrow $escrow is not on chain"
escrow_epoch=$(jget "$run_dir/escrow.json" escrow.epoch_index)
log "escrow $escrow: $slots slots, epoch $escrow_epoch"
[ "$escrow_epoch" = "$epoch" ] || die "escrow epoch $escrow_epoch, expected $epoch"

log "6/8 $REQUESTS requests into escrow $escrow"
for n in $(seq 1 "$REQUESTS"); do
  code=$(gw "request$n" POST "/devshard/$id/v1/chat/completions" client \
    "$(printf '{"model":"%s","messages":[{"role":"user","content":"What is 7 + 5? Answer with one number."}],"max_tokens":64}' "$model")")
  log "request $n: HTTP $code, finish $(jget "$run_dir/request$n.json" choices.0.finish_reason 2>/dev/null), tokens $(jget "$run_dir/request$n.json" usage.total_tokens 2>/dev/null)"
  sleep 3
done

log "7/8 settle"
read -r height now_epoch start length offset < <(cycle)
[ "$now_epoch" = "$epoch" ] || die "epoch moved to $now_epoch before the settlement"
[ "$offset" -lt "$rotate_at" ] || log "WARN: P+$offset is inside the gateway rotation window"
for try in $(seq 1 12); do
  code=$(gw settle POST "/v1/admin/devshards/$id/settle" admin '{}')
  [ "$code" = 409 ] || break
  log "settle: active requests, retry $try in 10 s"
  sleep 10
done
[ "$code" = 200 ] || die "settle: HTTP $code $(head -c 300 "$run_dir/settle.json")"
settle_tx=$(jget "$run_dir/settle.json" tx_hash)
log "settlement tx $settle_tx by $(jget "$run_dir/settle.json" settler)"
for _ in $(seq 1 24); do
  chain "/chain-api/cosmos/tx/v1beta1/txs/$settle_tx" > "$run_dir/settle_tx.json" 2>/dev/null && break
  sleep 5
done
tx_height=$(jget "$run_dir/settle_tx.json" tx_response.height 2>/dev/null || true)
tx_code=$(jget "$run_dir/settle_tx.json" tx_response.code 2>/dev/null || true)
log "settlement at height ${tx_height:-?} (P+$(( ${tx_height:-$start} - start ))), code ${tx_code:-0}"

log "8/8 gcheck escrow record and verdict"
set +e
"$GCHECK" escrow record --source devnet --a "$escrow" --attempt "a=$settle_tx" 2>&1 | tee "$run_dir/record.txt"
"$GCHECK" escrow verdict "$(sed -n 's/^records  //p' "$run_dir/record.txt" | tail -n 1)" 2>&1 | tee "$run_dir/verdict.txt"
verdict=${PIPESTATUS[0]}
set -e
cat "$run_dir/record.txt" "$run_dir/verdict.txt" >> "$run_dir/control.log"
log "done: escrow $escrow, create $create_tx, settle $settle_tx, verdict exit $verdict"
exit "$verdict"
