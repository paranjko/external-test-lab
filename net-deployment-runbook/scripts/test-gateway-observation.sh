#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
render="$ROOT/04-ops/render-gateway-observation.sh"
targets='[{"id":"A_V41","node":"node-a","port":18141},{"id":"A_V6","node":"node-a","port":18146},{"id":"B_V6","node":"node-b","port":18146}]'
result="$(bash "$render" "$targets" node-a 192.0.2.4/32)"
[[ "$(grep -c 'remote_ip 192.0.2.4/32' <<<"$result")" == 4 ]]
[[ "$result" == *'/ops-gateways/A_V41/metrics'* && "$result" == *'/ops-gateways/A_V6/status'* ]]
[[ "$result" != *B_V6* && "$result" != *'/gateway/v6/'* ]]
[[ "$(bash "$render" "$targets" monitor 192.0.2.4/32)" == '' ]]
for invalid in '[]' '[{"id":"A","node":"a","port":80}]' '[{"id":"A","node":"a","port":18146},{"id":"A","node":"b","port":18146}]'; do
  if bash "$render" "$invalid" node-a 192.0.2.4/32 >/dev/null 2>&1; then exit 1; fi
done
if bash "$render" "$targets" node-a 999.0.0.4/32 >/dev/null 2>&1; then exit 1; fi
printf 'PASS gateway observation version separation, source restriction and validation\n'
