#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
! grep -Eq 'gateway-key-pool|GDC_GATEWAY_PUBLIC_KEY_POOL_FILE|Telegram' "$ROOT/04-ops/gateway-health-probe.sh"
"$ROOT/04-ops/gateway-status-routable.sh" <<'EOF'
{"routable":true}
EOF
"$ROOT/04-ops/gateway-status-routable.sh" <<'EOF'
{"mode":"gateway","capacity":{"models":{"Qwen/Qwen3-0.6B":{"current_weight":1}}},"devshards":[{"active":true,"runtime":{"phase":"active","requests_blocked":false}}]}
EOF
if "$ROOT/04-ops/gateway-status-routable.sh" <<'EOF'
{"mode":"gateway","capacity":{"models":{"Qwen/Qwen3-0.6B":{"current_weight":0}}},"devshards":[{"active":true,"runtime":{"phase":"active","requests_blocked":false}}]}
EOF
then
  echo 'zero pooled capacity was routable' >&2; exit 1
fi
if "$ROOT/04-ops/gateway-status-routable.sh" <<'EOF'
{"mode":"gateway","capacity":{"models":{"Qwen/Qwen3-0.6B":{"current_weight":1}}},"devshards":[{"active":true,"phase":"active","requests_blocked":false,"confirmation_poc_phase":"CONFIRMATION_POC_GENERATION"}]}
EOF
then
  echo 'confirmation PoC was routable' >&2; exit 1
fi
tmp="$(mktemp -d)"
server_pid=''
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

printf '%s\n' \
  'DEVSHARD_API_KEYS=test-secret' \
  'DEVSHARD_MODEL=Qwen/Qwen3-0.6B' >"$tmp/gateway.env"

port=19887
node -e '
  const http=require("node:http"),fs=require("node:fs");
  http.createServer((request,response)=>{
    if(request.method==="GET"){
      const status=fs.existsSync(process.argv[2])
        ? {mode:"gateway",capacity:{models:{"Qwen/Qwen3-0.6B":{current_weight:1}}},devshards:[{active:true,runtime:{phase:"active",requests_blocked:false}}]}
        : {routable:true,capacity:{total_weight:1},devshards:[{active:true,phase:"active",requests_blocked:false}]};
      response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify(status));return}
    let body="";
    request.on("data",chunk=>body+=chunk);
    request.on("end",()=>{
      let payload={};try{payload=JSON.parse(body)}catch{}
      const valid=request.headers.authorization==="Bearer test-secret" && payload.model==="Qwen/Qwen3-0.6B" && payload.max_tokens===8;
      response.writeHead(valid?200:401,{"content-type":"application/json"});
      response.end(valid?JSON.stringify({choices:[{message:{content:"OK"}}]}):JSON.stringify({error:"unauthorized"}));
    });
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" "$tmp/pooled" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
printf '%s\n' '{"state":"READY","current_balance":200,"low_watermark":100}' >"$tmp/reserve.json"

GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/ready.json" \
GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "READY" and .http_status == 200 and .reason == "completion_succeeded" and (.latency_ms >= 0)' "$tmp/ready.json" >/dev/null

: >"$tmp/pooled"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/pooled-ready.json" \
GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "READY" and .reason == "completion_succeeded"' "$tmp/pooled-ready.json" >/dev/null

printf '%s\n' '{"state":"READY","current_balance":99,"low_watermark":100}' >"$tmp/low-reserve.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/low.json" GDC_GATEWAY_RESERVE_FILE="$tmp/low-reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "DEGRADED" and .reason == "escrow_reserve_low"' "$tmp/low.json" >/dev/null

GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/unavailable.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:1" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .http_status == 0 and .reason == "request_failed"' "$tmp/unavailable.json" >/dev/null
jq -e '.curl_exit > 0' "$tmp/unavailable.json" >/dev/null

printf '%s\n' '{"state":"FAILED","reason":"replacement_escrow_creation_failed","checked_at":"2026-08-10T08:00:15Z"}' >"$tmp/failed-reconciliation.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/failed.json" \
GDC_GATEWAY_RECONCILIATION_FILE="$tmp/failed-reconciliation.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:1" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .reason == "replacement_escrow_creation_failed" and (.recovery? == null)' "$tmp/failed.json" >/dev/null

printf '%s\n' '{"state":"RECOVERING","reason":"waiting_for_chain_confirmation","replacement_escrow":"123","entered_at":"2026-08-10T08:00:00Z","checked_at":"2026-08-10T08:00:15Z"}' >"$tmp/reconciliation.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/recovering.json" \
GDC_GATEWAY_RECONCILIATION_FILE="$tmp/reconciliation.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:1" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '
  .state == "RECOVERING"
  and .reason == "waiting_for_chain_confirmation"
  and .recovery.stage == "waiting_for_chain_confirmation"
  and .recovery.escrow_id == "123"
  and .recovery.started_at == "2026-08-10T08:00:00Z"
  and .recovery.next_check_seconds == 15
' "$tmp/recovering.json" >/dev/null
! grep -Eq 'test-secret|Qwen/Qwen3-0.6B|choices|content' "$tmp/ready.json" "$tmp/unavailable.json"

printf 'PASS gateway synthetic health probe contract\n'
