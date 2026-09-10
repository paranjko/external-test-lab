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
if "$ROOT/04-ops/gateway-status-routable.sh" <<'EOF'
{"mode":"gateway","capacity":{"models":{"Qwen/Qwen3-0.6B":{"current_weight":1}}},"devshards":[{"active":true,"phase":"active","chain_phase":"PoCGenerateWindDown","requests_blocked":false}]}
EOF
then
  echo 'non-Inference lifecycle was routable' >&2; exit 1
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
  const cached=new Map();
  http.createServer((request,response)=>{
    if(request.method==="GET"){
      if(fs.existsSync(process.argv[3])){response.writeHead(200,{"content-type":"application/json"});response.end(fs.readFileSync(process.argv[3]));return}
      const status=fs.existsSync(process.argv[2])
        ? {mode:"gateway",capacity:{models:{"Qwen/Qwen3-0.6B":{current_weight:1}}},devshards:[{active:true,runtime:{phase:"active",requests_blocked:false,chain_phase:"Inference"}}]}
        : {routable:true,capacity:{total_weight:1},devshards:[{active:true,phase:"active",requests_blocked:false,chain_phase:"Inference"}]};
      response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify(status));return}
    let body="";
    request.on("data",chunk=>body+=chunk);
    request.on("end",()=>{
      let payload={};try{payload=JSON.parse(body)}catch{}
      if(fs.existsSync(process.argv[4]) && !cached.has(body)){response.writeHead(503);response.end(JSON.stringify({error:"backend unavailable"}));return}
      const allowed=new Set(["model","messages","max_tokens"]);
      const prompt=payload.messages?.[0]?.content;
      const valid=request.headers.authorization==="Bearer test-secret" && payload.model==="Qwen/Qwen3-0.6B" && payload.max_tokens===8 && Object.keys(payload).every(key=>allowed.has(key)) && Array.isArray(payload.messages) && payload.messages.length===1 && payload.messages[0]?.role==="user" && typeof prompt==="string" && /^Reply with OK \[readiness-canary:[0-9]+-[0-9]+-[0-9]+\]$/.test(prompt);
      const safeGeneration="sha256:"+"a".repeat(64);
      const unordered=fs.existsSync(process.argv[5]);
      response.writeHead(valid?200:400,{"content-type":"application/json","X-GDC-Admission":"dispatched_once","X-GDC-Admission-ID":"0123456789abcdef0123456789abcdef","X-GDC-Arrival-Height":"100","X-GDC-Permit-Height":unordered?"99":"101","X-GDC-Dispatch-Height":"101","X-GDC-Response-Height":"102","X-GDC-Safe-Generation":safeGeneration});
      const result=valid?JSON.stringify({choices:[{message:{content:"OK"}}]}):JSON.stringify({error:"unsupported request parameter"});
      if(valid) cached.set(body,result);
      response.end(result);
    });
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" "$tmp/pooled" "$tmp/malformed-status" "$tmp/backend-unavailable" "$tmp/unordered-heights" &
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
jq -e '.state == "READY" and .readiness == "TRAFFIC_READY" and .http_status == 200 and .reason == "completion_succeeded" and (.latency_ms >= 0) and .admission == "dispatched_once" and .admission_id == "0123456789abcdef0123456789abcdef" and .arrival_height == 100 and .permit_height == 101 and .dispatch_height == 101 and .response_height == 102 and (.safe_generation | test("^sha256:[a-f0-9]{64}$"))' "$tmp/ready.json" >/dev/null
grep -Fxq 'gdc_gateway_readiness_state{state="TRAFFIC_READY"} 1' "$tmp/ready.prom"

: >"$tmp/unordered-heights"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/unordered.json" GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "UNAVAILABLE" and .reason == "completion_identity_unavailable"' "$tmp/unordered.json" >/dev/null
rm -f "$tmp/unordered-heights"

: >"$tmp/pooled"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/pooled-ready.json" \
GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "READY" and .readiness == "TRAFFIC_READY" and .reason == "completion_succeeded"' "$tmp/pooled-ready.json" >/dev/null

: >"$tmp/backend-unavailable"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/backend-unavailable.json" GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "UNAVAILABLE" and .reason == "http_503"' "$tmp/backend-unavailable.json" >/dev/null
rm -f "$tmp/backend-unavailable"

printf '%s\n' '{"routable":true,"mode":"gateway","capacity":{"models":{"Qwen/Qwen3-0.6B":{"current_weight":1}}},"devshards":[{"active":true,"runtime":{"phase":"active","requests_blocked":null,"chain_phase":"Inference"}}]}' >"$tmp/malformed-status"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/malformed.json" GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "UNAVAILABLE" and .reason == "status_unusable"' "$tmp/malformed.json" >/dev/null

printf '%s\n' '{"routable":true,"mode":"gateway","capacity":{"models":{"Qwen/Qwen3-0.6B":{"current_weight":1}}},"devshards":[{"active":true,"runtime":{"phase":"active"}}]}' >"$tmp/malformed-status"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/missing-lifecycle.json" GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "UNAVAILABLE" and .reason == "status_unusable"' "$tmp/missing-lifecycle.json" >/dev/null

rm -f "$tmp/malformed-status"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/bounded-generation.json" GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "READY" and (.safe_generation | test("^sha256:[a-f0-9]{64}$"))' "$tmp/bounded-generation.json" >/dev/null

printf '%s\n' '{"state":"READY","current_balance":99,"low_watermark":100}' >"$tmp/low-reserve.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/low.json" GDC_GATEWAY_RESERVE_FILE="$tmp/low-reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "DEGRADED" and .readiness == "ROUTING_READY" and .reason == "escrow_reserve_low"' "$tmp/low.json" >/dev/null

GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/unavailable.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:1" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "UNAVAILABLE" and .http_status == 0 and .reason == "request_failed"' "$tmp/unavailable.json" >/dev/null
jq -e '.curl_exit > 0' "$tmp/unavailable.json" >/dev/null
jq -e '.admission == "not_observed" and .admission_id == "" and .arrival_height == 0 and .permit_height == 0 and .dispatch_height == 0 and .response_height == 0 and .safe_generation == ""' "$tmp/unavailable.json" >/dev/null

printf '%s\n' '{"state":"FAILED","reason":"replacement_escrow_creation_failed","checked_at":"2026-08-10T08:00:15Z"}' >"$tmp/failed-reconciliation.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/failed.json" \
GDC_GATEWAY_RECONCILIATION_FILE="$tmp/failed-reconciliation.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:1" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "UNAVAILABLE" and .reason == "replacement_escrow_creation_failed" and (.recovery? == null)' "$tmp/failed.json" >/dev/null

printf '%s\n' '{"state":"PENDING","reason":"devshard_protocol_not_approved","replacement_escrow":"123","checked_at":"2026-08-10T08:00:15Z"}' >"$tmp/pending-reconciliation.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/pending.json" \
GDC_GATEWAY_RECONCILIATION_FILE="$tmp/pending-reconciliation.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "RECOVERING" and .readiness == "RECOVERING" and .reason == "devshard_protocol_not_approved" and .http_status == 0' "$tmp/pending.json" >/dev/null

printf '%s\n' '{"state":"DEGRADED","reason":"devshard_protocol_approval_unavailable","replacement_escrow":"123","checked_at":"2026-08-10T08:00:15Z"}' >"$tmp/degraded-reconciliation.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/degraded.json" \
GDC_GATEWAY_RECONCILIATION_FILE="$tmp/degraded-reconciliation.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "DEGRADED" and .readiness == "UNAVAILABLE" and .reason == "devshard_protocol_approval_unavailable" and .http_status == 0' "$tmp/degraded.json" >/dev/null

printf '%s\n' '{"state":"RECOVERING","reason":"waiting_for_chain_confirmation","replacement_escrow":"123","entered_at":"2026-08-10T08:00:00Z","checked_at":"2026-08-10T08:00:15Z"}' >"$tmp/reconciliation.json"
GDC_GATEWAY_ENV="$tmp/gateway.env" \
GDC_GATEWAY_HEALTH_FILE="$tmp/recovering.json" \
GDC_GATEWAY_RECONCILIATION_FILE="$tmp/reconciliation.json" \
GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:1" \
  "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '
  .state == "RECOVERING"
  and .readiness == "RECOVERING"
  and .reason == "waiting_for_chain_confirmation"
  and .recovery.stage == "waiting_for_chain_confirmation"
  and .recovery.escrow_id == "123"
  and .recovery.started_at == "2026-08-10T08:00:00Z"
  and .recovery.next_check_seconds == 15
' "$tmp/recovering.json" >/dev/null
! grep -Eq 'test-secret|Qwen/Qwen3-0.6B|choices|content' "$tmp/ready.json" "$tmp/unavailable.json"

# A 200 completion without the proxy's exact-once receipt is never traffic
# readiness. This prevents an upstream look-alike from turning the public
# dashboard green.
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=''
node -e '
  const fs=require("node:fs"),http=require("node:http");
  http.createServer((request,response)=>{
    if(request.method==="GET"){response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify({routable:true}));return}
    if(fs.existsSync(process.argv[2])){response.writeHead(429,{"content-type":"application/json"});response.end(JSON.stringify({error:"saturated"}));return}
    response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify({choices:[{message:{content:"OK"}}]}));
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" "$tmp/saturated" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/unidentified.json" GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "UNAVAILABLE" and .reason == "completion_identity_unavailable"' "$tmp/unidentified.json" >/dev/null
: >"$tmp/saturated"
GDC_GATEWAY_ENV="$tmp/gateway.env" GDC_GATEWAY_HEALTH_FILE="$tmp/saturated.json" GDC_GATEWAY_RESERVE_FILE="$tmp/reserve.json" GDC_GATEWAY_HEALTH_URL="http://127.0.0.1:$port" "$ROOT/04-ops/gateway-health-probe.sh"
jq -e '.state == "UNAVAILABLE" and .readiness == "SATURATED" and .reason == "http_429"' "$tmp/saturated.json" >/dev/null

printf 'PASS gateway synthetic health probe contract\n'
