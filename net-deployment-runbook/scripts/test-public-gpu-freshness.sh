#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="$ROOT/04-ops/render-ops.sh"
site="$ROOT/04-ops/site/src/app.js"

# The public route retains the latest observation for one bounded day. A
# temporary exporter failure must not erase known GPU or software inventory
# from a Host card, while an indefinitely old series remains excluded.
route="$(sed -n '/handle \/status\/gpus {/,/^  }/p' "$renderer")"
grep -Fq 'last_over_time(gdc_nvidia_memory_total_bytes%5B24h%5D)' <<<"$route"
software_route="$(sed -n '/handle \/status\/software {/,/^  }/p' "$renderer")"
grep -Fq 'max_over_time(timestamp(gdc_component_info)%5B24h%3A15s%5D)' <<<"$software_route"
grep -Fq 'inventory unavailable' "$site"
grep -Fq 'GPU inventory has not reported this Host yet' "$site"

stale_response='{"status":"success","data":{"result":[]}}'
fresh_response='{"status":"success","data":{"result":[{"metric":{"host":"node4-ml","gpu_name":"NVIDIA RTX PRO 2000 Blackwell"},"value":[0,"1"]}]}}'
jq -e '.data.result | length == 0' <<<"$stale_response" >/dev/null
jq -e '.data.result | length == 1 and .[0].metric.gpu_name == "NVIDIA RTX PRO 2000 Blackwell"' <<<"$fresh_response" >/dev/null
printf 'PASS public GPU and software inventory retain the latest bounded observation\n'
