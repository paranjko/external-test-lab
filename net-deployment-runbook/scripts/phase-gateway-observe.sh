#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
[[ "$action" =~ ^(status|verify)$ ]] || die 'expected gateway status or verify'
shift
# A verification that starts inside the PoC fence may need to cross the rest
# of the current 70-block epoch before admission can dispatch safely.  Keep the
# public command bounded, but make its default long enough to observe one full
# lifecycle instead of reporting a false timeout before the next safe window.
sla="${1:-300s}"
[[ $# -le 1 && "$sla" =~ ^[1-9][0-9]*s$ ]] || die 'gateway verification SLA must be a positive number of seconds'

key_file="$SECRETS/gateway.client-keys"
[[ -s "$key_file" ]] || die 'gateway assurance credential is unavailable'
client_key="$(cut -d, -f1 "$key_file")"
gateway_url="${GDC_GATEWAY_PUBLIC_URL:-https://$API_HOST}"

step 'Read the public gateway runtime state'
status="$(curl -fsS --connect-timeout 5 --max-time 20 "${gateway_url%/}/v1/status" \
  -H "Authorization: Bearer $client_key")"
status_routable=false
if printf '%s\n' "$status" | "$ROOT/04-ops/gateway-status-routable.sh" >/dev/null 2>&1; then
  status_routable=true
fi

if [[ "$action" == status ]]; then
  jq --arg state "$([[ "$status_routable" == true ]] && printf READY || printf TRANSITION)" \
    --arg reason "$([[ "$status_routable" == true ]] && printf runtime_routable || printf runtime_not_routable)" \
    '{state:$state,reason:$reason,runtimes:(([.devshards[]? | select(.active == true and .phase == "active" and (.requests_blocked // false) == false)] | length) + (if .phase == "active" and (.requests_blocked // false) == false then 1 else 0 end)),model:(.model // ([.devshards[]?.model] | first))}' <<<"$status"
  exit 0
fi

step 'Prove authenticated chain-accounted inference'
verify_evidence="${GDC_GATEWAY_VERIFY_EVIDENCE_DIR:-$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}-gateway-verify}"
mkdir -p "$verify_evidence"
timeout "${sla%s}" "$ROOT/04-ops/test-inference-until-ready.sh" \
  "$gateway_url" "$client_key" "$verify_evidence" "$verify_evidence/completion.json" "${sla%s}" >/dev/null
printf 'PASS gateway completed authenticated inference within %s\n' "$sla"
