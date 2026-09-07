#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=''
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

port=19892
node -e '
  const fs=require("node:fs"),http=require("node:http");
  http.createServer((request,response)=>{
    const auth=request.headers.authorization || "";
    request.resume();
    request.on("end",()=>{
      if(auth==="Bearer timeout-key") return setTimeout(()=>response.end(),3000);
      fs.writeFileSync(process.argv[2],JSON.stringify({deadline:request.headers["x-request-deadline-ms"],auth}));
      if(auth==="Bearer failure-key"){
        response.writeHead(503,{"content-type":"application/json"});
        response.end(JSON.stringify({error:{code:"runtime_unavailable"}}));
        return;
      }
      response.writeHead(200,{"content-type":"application/json"});
      response.end(JSON.stringify({choices:[{message:{content:"GDC_OK"}}]}));
    });
  }).listen(Number(process.argv[1]),"127.0.0.1");
' "$port" "$tmp/request.json" &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -sS --max-time 1 "http://127.0.0.1:$port/ready" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

started_ms="$(date +%s%3N)"
GDC_INFERENCE_DEADLINE_SECONDS=15 GDC_INFERENCE_HTTP_TIMEOUT_SECONDS=20 \
  "$ROOT/04-ops/test-inference.sh" "http://127.0.0.1:$port" success-key >"$tmp/completion.json"
jq -e '.choices[0].message.content == "GDC_OK"' "$tmp/completion.json" >/dev/null
jq -e '.auth == "Bearer success-key"' "$tmp/request.json" >/dev/null
observed_deadline="$(jq -er '.deadline | tonumber' "$tmp/request.json")"
(( observed_deadline >= started_ms + 14000 && observed_deadline <= started_ms + 17000 ))

set +e
GDC_INFERENCE_DEADLINE_SECONDS=15 GDC_INFERENCE_HTTP_TIMEOUT_SECONDS=20 \
  "$ROOT/04-ops/test-inference.sh" "http://127.0.0.1:$port" failure-key \
  >"$tmp/failure.stdout" 2>"$tmp/failure.stderr"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -Fq 'http_status=503 error_code=runtime_unavailable' "$tmp/failure.stderr"
! grep -Fq 'failure-key' "$tmp/failure.stderr"

set +e
GDC_INFERENCE_DEADLINE_SECONDS=1 GDC_INFERENCE_HTTP_TIMEOUT_SECONDS=1 \
  "$ROOT/04-ops/test-inference.sh" "http://127.0.0.1:$port" timeout-key \
  >"$tmp/timeout.stdout" 2>"$tmp/timeout.stderr"
rc=$?
set -e
[[ "$rc" == 28 ]]
grep -Fq 'curl_exit=28 curl_status=timeout' "$tmp/timeout.stderr"
! grep -Fq 'timeout-key' "$tmp/timeout.stderr"

set +e
GDC_INFERENCE_DEADLINE_SECONDS=0 "$ROOT/04-ops/test-inference.sh" \
  "http://127.0.0.1:$port" invalid-key >"$tmp/invalid.stdout" 2>"$tmp/invalid.stderr"
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -Fq 'GDC_INFERENCE_DEADLINE_SECONDS must be an integer from 1 through 900' "$tmp/invalid.stderr"

set +e
GDC_INFERENCE_DEADLINE_SECONDS=20 GDC_INFERENCE_HTTP_TIMEOUT_SECONDS=15 \
  "$ROOT/04-ops/test-inference.sh" "http://127.0.0.1:$port" invalid-key \
  >"$tmp/invalid-order.stdout" 2>"$tmp/invalid-order.stderr"
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -Fq 'GDC_INFERENCE_HTTP_TIMEOUT_SECONDS must not be shorter than GDC_INFERENCE_DEADLINE_SECONDS' \
  "$tmp/invalid-order.stderr"

printf 'PASS authenticated inference request deadline and diagnostics\n'
