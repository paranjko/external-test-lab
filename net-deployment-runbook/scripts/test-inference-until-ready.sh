#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -Fq 'X-Request-Deadline-Ms: $completion_deadline_ms' "$ROOT/04-ops/test-inference-until-ready.sh"
tmp="$(mktemp -d)"
server_pid=''
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

port=19888
node -e '
  const http=require("node:http");
  http.createServer((request,response)=>{
    if(request.url==="/v1/status"){response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify({routable:true,devshards:[]}));return}
    request.resume();
    request.on("end",()=>setTimeout(()=>response.end(),3000));
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port/v1/status" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

set +e
GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS=1 "$ROOT/04-ops/test-inference-until-ready.sh" \
  "http://127.0.0.1:$port" test-key "$tmp/evidence" "$tmp/completion.json" 1 >"$tmp/stdout" 2>"$tmp/stderr"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -Fq 'curl_exit=28 curl_status=timeout' "$tmp/stderr"
! grep -Fq 'curl: (28)' "$tmp/stderr"
jq -e '.reason == "curl_timeout"' "$tmp/evidence/inference-verdict.json" >/dev/null
jq -e '.completion_curl_exit == 28 and .completion_curl_status == "timeout" and .admission == "not_observed" and .completion_error_code == "not_observed" and .reason == "curl_timeout"' "$tmp/evidence/inference-attempts.jsonl" >/dev/null

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=''
port=19889
node -e '
  const http=require("node:http");
  http.createServer((request,response)=>{
    if(request.url==="/v1/status"){response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify({routable:true,devshards:[]}));return}
    request.resume();
    request.on("end",()=>{response.writeHead(503,{"content-type":"application/json","X-GDC-Admission":"pre_dispatch_rejected"});response.end(JSON.stringify({error:{code:"admission_state_unavailable"}}));});
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port/v1/status" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
set +e
GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS=1 "$ROOT/04-ops/test-inference-until-ready.sh" \
  "http://127.0.0.1:$port" test-key "$tmp/proxy-evidence" "$tmp/proxy-completion.json" 1 >"$tmp/proxy.stdout" 2>"$tmp/proxy.stderr"
rc=$?
set -e
[[ "$rc" == 1 ]]
jq -e '.completion_http == 503 and .admission == "pre_dispatch_rejected" and .completion_error_code == "admission_state_unavailable" and .reason == "http_503"' "$tmp/proxy-evidence/inference-attempts.jsonl" >/dev/null

printf 'PASS inference retry diagnostics contract\n'
