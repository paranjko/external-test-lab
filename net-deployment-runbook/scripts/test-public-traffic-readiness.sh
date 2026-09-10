#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
port="$((20000 + RANDOM % 10000))"

node -e '
  const http=require("node:http"),fs=require("node:fs");
  let calls=0;
  http.createServer((_request,response)=>{
    calls+=1;
    const stale=calls===1;
    const oldCompletion=calls<=2;
    const unordered=calls===3;
    const checked=stale ? new Date(Date.now()-60000) : new Date();
    checked.setMilliseconds(0);
    const body={
      state:"READY",readiness:"TRAFFIC_READY",checked_at:checked.toISOString(),
      admission:"dispatched_once",admission_id:"0123456789abcdef0123456789abcdef",
      safe_generation:"sha256:"+"a".repeat(64),arrival_height:100,
      permit_height:unordered?99:101,dispatch_height:101,response_height:102,
      // The second sample is fresh as a file, but its completion predates the
      // verification. The third has unordered lifecycle heights; only the
      // fourth sample proves a newly executed, causally ordered canary.
      completion_finished_ms:oldCompletion ? Date.now()-60000 : Date.now()
    };
    response.writeHead(200,{"content-type":"application/json"});
    response.end(JSON.stringify(body));
    if(calls>=4) fs.writeFileSync(process.argv[2],String(calls));
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" "$tmp/calls" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in $(seq 1 30); do
  curl -fsS --max-time 1 "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
  sleep 0.1
done

started_ms="$(date +%s%3N)"
"$ROOT/04-ops/wait-public-traffic-readiness.sh" \
  "http://127.0.0.1:$port" "$tmp/receipt.json" "$started_ms" 30 10 0.1
jq -e '.readiness == "TRAFFIC_READY" and (.checked_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= (($started / 1000) | floor)' \
  --argjson started "$started_ms" "$tmp/receipt.json" >/dev/null
[[ "$(cat "$tmp/calls")" -ge 4 ]]

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=''
delayed_port="$((port + 1))"
node -e '
  const http=require("node:http");
  http.createServer((request,response)=>{
    if(request.url==="/ready"){response.writeHead(204);response.end();return}
    setTimeout(()=>{
    response.writeHead(200,{"content-type":"application/json"});
    response.end(JSON.stringify({state:"READY",readiness:"TRAFFIC_READY",checked_at:new Date().toISOString(),admission:"dispatched_once",admission_id:"0123456789abcdef0123456789abcdef",safe_generation:"sha256:"+"a".repeat(64),arrival_height:100,permit_height:101,dispatch_height:101,response_height:102,completion_finished_ms:Date.now()}));
    },2000)
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$delayed_port" &
server_pid=$!
for _ in $(seq 1 30); do
  curl -sS --max-time 1 "http://127.0.0.1:$delayed_port/ready" >/dev/null 2>&1 && break
  sleep 0.1
done
delayed_started_ms="$(date +%s%3N)"
if "$ROOT/04-ops/wait-public-traffic-readiness.sh" \
  "http://127.0.0.1:$delayed_port" "$tmp/delayed.json" "$delayed_started_ms" 30 1 0.1; then
  echo 'delayed readiness response exceeded configured deadline' >&2
  exit 1
fi
printf 'PASS public readiness polling rejects stale or pre-verification receipts then accepts fresh traffic receipt\n'
