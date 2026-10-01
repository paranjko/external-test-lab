# Shared parts of the group size scenarios: chain reads, calls made on the gateway host, escrow steps.
# shellcheck shell=bash disable=SC2034,SC2154

GATEWAY_HOST=${GATEWAY_HOST:-gdc-node4}
GATEWAY_DIR=${GATEWAY_DIR:-/srv/dai/broker-tests/ds502-a}
GATEWAY_PORT=${GATEWAY_PORT:-18087}
CHAIN=${CHAIN:-https://api.gonka-dev.net}
GCHECK=${GCHECK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/gcheck}
RUN_ROOT=${RUN_ROOT:-$HOME/gonka-187-runs}
SSH=${SSH:-ssh}
REQUESTS=${REQUESTS:-2}
API=/chain-api/productscience/inference/inference
FIRST=20

# start_run NAME MODE: tools, gcheck and the run directory.
start_run() {
  local tool
  for tool in curl python3 base64 "$SSH"; do
    command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
  done
  [ -x "$GCHECK" ] || { echo "gcheck not found: $GCHECK" >&2; exit 2; }
  run_name=$1
  run_dir="$RUN_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$1-$2"
  mkdir -p "$run_dir"
}

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$run_dir/$run_name.log"; }
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

# chain_params: group_size and the escrow limit from the live parameters.
chain_params() {
  chain "$API/params" > "$run_dir/params.json" || die "chain params are unreachable"
  group_size=$(jget "$run_dir/params.json" params.devshard_escrow_params.group_size)
  max_escrows=$(jget "$run_dir/params.json" params.devshard_escrow_params.max_escrows_per_epoch)
}

# gateway_settings: the admin API answers; the rotation gives the model and its escrow amount.
gateway_settings() {
  local code
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
}

# wait_window NEED: start at P+FIRST..P+(rotation - NEED), so NEED blocks fit before the gateway rotation window;
# a real run with --wait waits for the next window.
wait_window() {
  local left
  read -r height epoch start length offset < <(cycle)
  rotate_at=$((length + 19 - pre_poc))
  latest=$((rotate_at - $1))
  log "height $height, epoch $epoch, PoC start $start, P+$offset of $length; gateway rotation from P+$rotate_at"
  [ "$offset" -ge "$FIRST" ] && [ "$offset" -le "$latest" ] && return 0
  if [ "$offset" -lt "$FIRST" ]; then left=$((FIRST - offset)); else left=$((length - offset + FIRST)); fi
  if [ "$mode" != run ] || [ "$wait" != 1 ]; then
    log "outside the start window P+$FIRST..P+$latest; the next one opens in about $left blocks"
    [ "$mode" = dry ] && return 0
    exit 3
  fi
  log "waiting about $left blocks for P+$FIRST"
  for _ in $(seq 1 240); do
    sleep 15
    read -r height epoch start length offset < <(cycle)
    [ "$offset" -ge "$FIRST" ] && [ "$offset" -le "$latest" ] && { log "height $height, epoch $epoch, P+$offset"; return 0; }
  done
  die "the window did not open in an hour"
}

# free_places NEED: enough escrow places left in the current epoch.
free_places() {
  local created
  created=$(chain "/chain-rpc/tx_search?query=%22devshard_escrow_created.epoch_index=%27$epoch%27%22&per_page=1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["total_count"])') || die "escrow count is unreadable"
  log "epoch $epoch has $created of $max_escrows escrows"
  [ $((max_escrows - created)) -ge "$1" ] || stop "fewer than $1 free escrow places in epoch $epoch"
}

# create_escrow ROLE: escrow, id and create_tx of a new escrow of gateway A.
create_escrow() {
  local role=$1 code
  code=$(gw "create-$role" POST /v1/admin/escrows admin "$(printf '{"amount":%s,"model_id":"%s"}' "$amount" "$model")")
  [ "$code" = 200 ] || die "create $role: HTTP $code $(head -c 300 "$run_dir/create-$role.json")"
  escrow=$(jget "$run_dir/create-$role.json" escrow_id) || die "create $role: unexpected reply"
  id=$(jget "$run_dir/create-$role.json" id)
  create_tx=$(jget "$run_dir/create-$role.json" tx_hash)
  log "escrow $role = $escrow by $(jget "$run_dir/create-$role.json" creator), tx $create_tx"
  [ -n "$id" ] || die "the gateway did not register escrow $escrow"
}

# escrow_on_chain ROLE ESCROW SLOTS: the escrow is on chain in the current epoch with SLOTS slots.
escrow_on_chain() {
  local role=$1 slots escrow_epoch
  for _ in $(seq 1 12); do
    chain "$API/devshard_escrow/$2" > "$run_dir/escrow-$role.json" 2>/dev/null && break
    sleep 5
  done
  slots=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["escrow"]["slots"]))' \
    "$run_dir/escrow-$role.json") || die "escrow $2 is not on chain"
  escrow_epoch=$(jget "$run_dir/escrow-$role.json" escrow.epoch_index)
  log "escrow $2: $slots slots, epoch $escrow_epoch"
  [ "$escrow_epoch" = "$epoch" ] || die "escrow epoch $escrow_epoch, expected $epoch"
  [ "$slots" = "$3" ] || log "WARN: escrow $2 has $slots slots, expected $3"
}

# send_requests ROLE ID: REQUESTS completions into that escrow only.
send_requests() {
  local n code
  for n in $(seq 1 "$REQUESTS"); do
    code=$(gw "request-$1-$n" POST "/devshard/$2/v1/chat/completions" client \
      "$(printf '{"model":"%s","messages":[{"role":"user","content":"What is 7 + 5? Answer with one number."}],"max_tokens":64}' "$model")")
    log "request $1/$n: HTTP $code, finish $(jget "$run_dir/request-$1-$n.json" choices.0.finish_reason 2>/dev/null), tokens $(jget "$run_dir/request-$1-$n.json" usage.total_tokens 2>/dev/null)"
    sleep 3
  done
}

# settle_escrow ROLE ID: manual settlement; settle_tx, settle_height and settle_code.
settle_escrow() {
  local role=$1 code try now_epoch
  read -r height now_epoch start length offset < <(cycle)
  [ "$now_epoch" = "$epoch" ] || die "epoch moved to $now_epoch before the settlement of $role"
  [ "$offset" -lt "$rotate_at" ] || log "WARN: P+$offset is inside the gateway rotation window"
  for try in $(seq 1 12); do
    code=$(gw "settle-$role" POST "/v1/admin/devshards/$2/settle" admin '{}')
    [ "$code" = 409 ] || break
    log "settle $role: active requests, retry $try in 10 s"
    sleep 10
  done
  [ "$code" = 200 ] || die "settle $role: HTTP $code $(head -c 300 "$run_dir/settle-$role.json")"
  settle_tx=$(jget "$run_dir/settle-$role.json" tx_hash)
  for _ in $(seq 1 24); do
    chain "/chain-api/cosmos/tx/v1beta1/txs/$settle_tx" > "$run_dir/settle-$role-tx.json" 2>/dev/null && break
    sleep 5
  done
  settle_height=$(jget "$run_dir/settle-$role-tx.json" tx_response.height 2>/dev/null || true)
  settle_code=$(jget "$run_dir/settle-$role-tx.json" tx_response.code 2>/dev/null || true)
  log "settle $role: tx $settle_tx at height ${settle_height:-?} (P+$(( ${settle_height:-$start} - start ))), code ${settle_code:-0}"
}

# record_and_verdict ARGS...: gcheck escrow record with ARGS, then verdict on its run; returns the verdict exit code.
record_and_verdict() {
  local verdict
  set +e
  "$GCHECK" escrow record --source devnet "$@" 2>&1 | tee "$run_dir/record.txt"
  "$GCHECK" escrow verdict "$(sed -n 's/^records  //p' "$run_dir/record.txt" | tail -n 1)" 2>&1 | tee "$run_dir/verdict.txt"
  verdict=${PIPESTATUS[0]}
  set -e
  cat "$run_dir/record.txt" "$run_dir/verdict.txt" >> "$run_dir/$run_name.log"
  return "$verdict"
}
