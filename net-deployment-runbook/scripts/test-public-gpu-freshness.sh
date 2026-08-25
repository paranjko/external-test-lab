#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="$ROOT/04-ops/render-ops.sh"
site="$ROOT/04-ops/site/src/app.js"

# The public route forwards only the freshness-qualified vector. Prometheus
# returns no matching series for stale inventory, which makes the site retain
# its explicit configured/unavailable fallback instead of presenting old GPU
# hardware as live.
route="$(sed -n '/handle \/status\/gpus {/,/^  }/p' "$renderer")"
grep -Fq 'gdc_nvidia_memory_total_bytes%20unless%20(time()%20-%20timestamp(gdc_nvidia_memory_total_bytes)%20%3E%20120)' <<<"$route"
grep -Fq 'inventory unavailable' "$site"
grep -Fq 'GPU inventory has not reported this Host yet' "$site"

stale_response='{"status":"success","data":{"result":[]}}'
fresh_response='{"status":"success","data":{"result":[{"metric":{"host":"node4-ml","gpu_name":"NVIDIA RTX PRO 2000 Blackwell"},"value":[0,"1"]}]}}'
jq -e '.data.result | length == 0' <<<"$stale_response" >/dev/null
jq -e '.data.result | length == 1 and .[0].metric.gpu_name == "NVIDIA RTX PRO 2000 Blackwell"' <<<"$fresh_response" >/dev/null
printf 'PASS stale public GPU fixture is empty and therefore renders only the fallback\n'
