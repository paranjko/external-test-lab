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
jq -e '.admission == "not_observed" and .attempts == 1' "$tmp/evidence/inference-verdict.json" >/dev/null
[[ "$(wc -l <"$tmp/evidence/inference-attempts.jsonl")" == 1 ]]
jq -e '.completion_curl_exit == 28 and .completion_curl_status == "timeout" and .admission == "not_observed" and .completion_error_code == "not_observed" and .reason == "curl_timeout"' "$tmp/evidence/inference-attempts.jsonl" >/dev/null

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=''
port=19889
node -e '
  const http=require("node:http");
  let completions=0;
  http.createServer((request,response)=>{
    if(request.url==="/v1/status"){response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify({routable:true,devshards:[]}));return}
    request.resume();
    request.on("end",()=>{
      completions++;
      if(completions===1){response.writeHead(503,{"content-type":"application/json","X-GDC-Admission":"pre_dispatch_rejected"});response.end(JSON.stringify({error:{code:"admission_state_unavailable"}}));return}
      response.writeHead(200,{"content-type":"application/json","X-GDC-Admission":"dispatched_once"});response.end(JSON.stringify({choices:[{message:{content:"GDC_OK"}}]}));
    });
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port/v1/status" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS=1 "$ROOT/04-ops/test-inference-until-ready.sh" \
  "http://127.0.0.1:$port" test-key "$tmp/proxy-evidence" "$tmp/proxy-completion.json" 10 >"$tmp/proxy.stdout" 2>"$tmp/proxy.stderr"
[[ "$(wc -l <"$tmp/proxy-evidence/inference-attempts.jsonl")" == 2 ]]
jq -e 'select(.attempt == 1 and .completion_http == 503 and .admission == "pre_dispatch_rejected" and .completion_error_code == "admission_state_unavailable" and .reason == "http_503")' "$tmp/proxy-evidence/inference-attempts.jsonl" >/dev/null
jq -e 'select(.attempt == 2 and .completion_http == 200 and .admission == "dispatched_once" and .reason == "completion_succeeded")' "$tmp/proxy-evidence/inference-attempts.jsonl" >/dev/null
jq -e '.choices[0].message.content == "GDC_OK"' "$tmp/proxy-completion.json" >/dev/null

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=''
port=19891
node -e '
  const http=require("node:http");
  http.createServer((request,response)=>{
    if(request.url==="/v1/status"){response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify({routable:true,devshards:[]}));return}
    request.resume();
    request.on("end",()=>{response.writeHead(503,{"content-type":"application/json","X-GDC-Admission":"dispatched_once"});response.end(JSON.stringify({error:{code:"upstream_unavailable"}}));});
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port/v1/status" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
set +e
GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS=1 "$ROOT/04-ops/test-inference-until-ready.sh" \
  "http://127.0.0.1:$port" test-key "$tmp/dispatched-evidence" "$tmp/dispatched-completion.json" 10 >"$tmp/dispatched.stdout" 2>"$tmp/dispatched.stderr"
rc=$?
set -e
[[ "$rc" == 1 ]]
[[ "$(wc -l <"$tmp/dispatched-evidence/inference-attempts.jsonl")" == 1 ]]
jq -e '.reason == "http_503" and .admission == "dispatched_once" and .attempts == 1' "$tmp/dispatched-evidence/inference-verdict.json" >/dev/null

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=''
port=19890
node -e '
  const fs=require("node:fs"),http=require("node:http");
  http.createServer((request,response)=>{
    if(request.url==="/v1/status"){
      const status={mode:"gateway",capacity:{models:{"Qwen/Qwen3-0.6B":{current_weight:1}}},devshards:[{active:true,phase:"active",chain_phase:"PoCGenerateWindDown",requests_blocked:false}]};
      response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify(status));return;
    }
    fs.writeFileSync(process.argv[2],"unexpected POST");
    request.resume();response.writeHead(200,{"content-type":"application/json"});response.end(JSON.stringify({choices:[{message:{content:"unexpected"}}]}));
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" "$tmp/non-inference-post" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port/v1/status" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
set +e
GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS=1 "$ROOT/04-ops/test-inference-until-ready.sh" \
  "http://127.0.0.1:$port" test-key "$tmp/non-inference-evidence" "$tmp/non-inference-completion.json" 1 >"$tmp/non-inference.stdout" 2>"$tmp/non-inference.stderr"
rc=$?
set -e
[[ "$rc" == 1 ]]
[[ ! -e "$tmp/non-inference-post" ]]
jq -e '.reason == "runtime_not_routable"' "$tmp/non-inference-evidence/inference-verdict.json" >/dev/null
jq -e '.status_ready == false and .completion_http == 0 and .completion_curl_exit == 0 and .admission == "not_sent_runtime_not_routable" and .reason == "runtime_not_routable"' "$tmp/non-inference-evidence/inference-attempts.jsonl" >/dev/null

printf 'PASS inference retry diagnostics contract\n'
