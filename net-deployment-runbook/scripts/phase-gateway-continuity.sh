#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
record_phase_profile gateway-continuity
step 'Initialize bounded continuity transport'

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-gateway-continuity"
mkdir -p "$RUN"
install_evidence_exit_trap 'Gateway continuity'
declare -a observability_pids=()

topology_ssh() {
  timeout --foreground --kill-after=2 10 \
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 "$@"
}

gateway_url="${GDC_GATEWAY_PUBLIC_URL:-https://$API_HOST}"
gateway_url="${gateway_url%/}"
chain_base="${GDC_CONTINUITY_CHAIN_BASE_URL:-https://$GENESIS_PUBLIC_HOST}"
chain_base="${chain_base%/}"
step 'Resolve bounded continuity transports'
chain_transport_ip="$(topology_ssh -G "$GENESIS_NODE" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
edge_transport_ip="$(topology_ssh -G "$PUBLIC_EDGE_NODE" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
[[ "$chain_transport_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die 'canonical chain transport IP is unavailable from topology'
[[ "$edge_transport_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die 'public edge transport IP is unavailable from topology'
declare -a continuity_resolve=(
  --resolve "$GENESIS_PUBLIC_HOST:443:$chain_transport_ip"
  --resolve "$API_HOST:443:$edge_transport_ip"
  --resolve "$SITE_HOST:443:$edge_transport_ip"
)
step 'Begin strict recovery-readiness preflight'
continuity_curl() {
  curl "${continuity_resolve[@]}" "$@"
}
continuity_ssh() {
  # Preflight and post-dispatch evidence must not wait indefinitely for a
  # broken control-plane transport. Keep SSH non-interactive and bounded so a
  # missing Host sample becomes a recorded failed predicate rather than an
  # observer hang that can consume the rotation horizon.
  timeout --foreground --kill-after=2 15 \
    ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=1 "$@"
}
# A full post-boundary replacement can take more than one 70-block epoch to
# regain routability and five-Host voting power. Keep the observer bounded,
# but allow enough time to distinguish delayed recovery from non-recovery.
timeout_seconds="${GDC_GATEWAY_CONTINUITY_TIMEOUT_SECONDS:-1800}"
preflight_timeout="${GDC_GATEWAY_PREFLIGHT_TIMEOUT_SECONDS:-300}"
pre_blocks="${GDC_GATEWAY_CONTINUITY_PRE_BLOCKS:-3}"
post_success_target="${GDC_GATEWAY_CONTINUITY_POST_SUCCESSES:-2}"
minimum_lead_blocks="${GDC_GATEWAY_CONTINUITY_MIN_LEAD_BLOCKS:-10}"
# Three exact-boundary arrivals share one serialized upstream permit. Their
# absolute deadline must cover post-PoC recovery plus earlier one-shot
# dispatches; curl keeps a response margin beyond the admission cap.
request_timeout="${GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS:-930}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_TIMEOUT_SECONDS must be positive'
[[ "$preflight_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_PREFLIGHT_TIMEOUT_SECONDS must be positive'
[[ "$pre_blocks" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_PRE_BLOCKS must be positive'
[[ "$post_success_target" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_POST_SUCCESSES must be positive'
[[ "$minimum_lead_blocks" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_MIN_LEAD_BLOCKS must be positive'
[[ "$request_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS must be positive'

# Continuity proves the gateway lifecycle with its dedicated assurance
# credential. Telegram is a consumer of that gateway, never the source of
# readiness credentials or a prerequisite for protocol assurance.
key_source=assurance
key_file="$SECRETS/gateway.client-keys"
[[ -s "$key_file" ]] || die 'gateway client keys are absent; run bootstrap-access or gateway install first'
client_key="$(cut -d, -f1 "$key_file")"
[[ -n "$client_key" ]] || die 'gateway assurance key is empty'

capture_recovery_readiness() {
  local participants='{}' validators='{}' epoch_group='{}' public_health='{}' reserve='{}' reconciliation='{}'
  local participants_ok=false validators_ok=false epoch_group_ok=false gateway_status_ok=false
  local public_health_ok=false reserve_ok=false reconciliation_ok=false expected_hosts evaluation

  if participants="$(continuity_ssh "$GATEWAY_NODE" 'curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:1317/productscience/inference/inference/participant' 2>/dev/null)" \
    && jq -e . <<<"$participants" >/dev/null 2>&1; then participants_ok=true; else participants='{}'; fi
  if validators="$(continuity_ssh "$GATEWAY_NODE" 'curl -fsS --connect-timeout 3 --max-time 10 "http://127.0.0.1:26657/validators?per_page=100"' 2>/dev/null)" \
    && jq -e . <<<"$validators" >/dev/null 2>&1; then validators_ok=true; else validators='{}'; fi
  if epoch_group="$(continuity_ssh "$GATEWAY_NODE" 'curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data' 2>/dev/null)" \
    && jq -e . <<<"$epoch_group" >/dev/null 2>&1; then epoch_group_ok=true; else epoch_group='{}'; fi
  if jq -e . <<<"$gateway_status" >/dev/null 2>&1; then gateway_status_ok=true; else gateway_status='{}'; fi
  expected_hosts="$(printf '%s\n' "${GDC_NODES[@]}" | while IFS= read -r node; do node_public_host "$node"; done | jq -Rsc 'split("\n") | map(select(length > 0))')"
  if public_health="$(continuity_curl -fsS --connect-timeout 3 --max-time 10 "https://$SITE_HOST/status/gateway-health" 2>/dev/null)" \
    && jq -e . <<<"$public_health" >/dev/null 2>&1; then public_health_ok=true; else public_health='{}'; fi
  if reserve="$(continuity_ssh "$GATEWAY_NODE" 'sudo cat /srv/dai/ops/status/gateway-reserve.json' 2>/dev/null)" \
    && jq -e . <<<"$reserve" >/dev/null 2>&1; then reserve_ok=true; else reserve='{}'; fi
  if reconciliation="$(continuity_ssh "$GATEWAY_NODE" 'sudo cat /srv/dai/ops/status/gateway-reconciliation.json' 2>/dev/null)" \
    && jq -e . <<<"$reconciliation" >/dev/null 2>&1; then reconciliation_ok=true; else reconciliation='{}'; fi

  evaluation="$(jq -nc \
    --arg observed_at "$(date -u +%FT%TZ)" --argjson height "$height" \
    --argjson participants_ok "$participants_ok" --argjson validators_ok "$validators_ok" \
    --argjson epoch_group_ok "$epoch_group_ok" --argjson gateway_status_ok "$gateway_status_ok" \
    --argjson public_health_ok "$public_health_ok" --argjson reserve_ok "$reserve_ok" \
    --argjson reconciliation_ok "$reconciliation_ok" --argjson expected_hosts "$expected_hosts" \
    --argjson participants "$participants" --argjson validators "$validators" --argjson epoch_group "$epoch_group" \
    --argjson gateway_status "$gateway_status" --argjson public_health "$public_health" \
    --argjson reserve "$reserve" --argjson reconciliation "$reconciliation" \
    '{observed_at:$observed_at,height:$height,
      sources:{participants:$participants_ok,validators:$validators_ok,epoch_group:$epoch_group_ok,
        gateway_status:$gateway_status_ok,public_health:$public_health_ok,reserve:$reserve_ok,reconciliation:$reconciliation_ok},
      expected_hosts:$expected_hosts,participants:$participants,validators:$validators,epoch_group:$epoch_group,
      gateway_status:$gateway_status,public_health:$public_health,reserve:$reserve,reconciliation:$reconciliation}' \
    | "$ROOT/scripts/evaluate-recovery-readiness.sh" "$MODEL_ID")"
  printf '%s\n' "$evaluation" >>"$RUN/recovery-readiness.jsonl"
  jq -e '.overall_ready == true' <<<"$evaluation" >/dev/null
}

: >"$RUN/recovery-readiness.jsonl"
preflight_deadline=$((SECONDS + preflight_timeout))
preflight_ready_samples=0
last_preflight_height=0
while (( SECONDS < preflight_deadline && preflight_ready_samples < 3 )); do
  height="$(continuity_curl -fsS --connect-timeout 3 --max-time 10 "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
  if (( height <= last_preflight_height )); then sleep 1; continue; fi
  last_preflight_height="$height"
  gateway_status="$(continuity_curl -sS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" || true)"
  if capture_recovery_readiness; then
    preflight_ready_samples=$((preflight_ready_samples + 1))
  else
    preflight_ready_samples=0
  fi
done
(( preflight_ready_samples == 3 )) || die 'three consecutive full-fleet recovery readiness samples were not observed'

step 'Capture the live topology and calculate the next PoC boundary'
continuity_curl -fsS "$chain_base/chain-api/productscience/inference/inference/params" >"$RUN/params.json"
continuity_curl -fsS "$chain_base/chain-api/productscience/inference/inference/participant" >"$RUN/participants.json"
continuity_curl -fsS "$chain_base/chain-api/productscience/inference/inference/current_epoch_group_data" >"$RUN/epoch-group-before.json"
continuity_curl -fsS "$chain_base/chain-rpc/status" >"$RUN/chain-status-before.json"
continuity_curl -fsS "$chain_base/chain-rpc/genesis" | jq -eS '.result.genesis' >"$RUN/genesis.json"
genesis_sha256="$(genesis_sha256 "$RUN/genesis.json")"
read -r epoch_length epoch_shift < <(
  jq -er '(.params // .).epoch_params | [(.epoch_length|tonumber),(.epoch_shift|tonumber)] | @tsv' "$RUN/params.json"
)
height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/chain-status-before.json")"
(( epoch_length > 0 )) || die 'live epoch length must be positive'
position=$(((height - epoch_shift) % epoch_length))
(( position < 0 )) && position=$((position + epoch_length))
target_anchor=$((height + epoch_length - position))
current_height="$(continuity_curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
# The topology and evidence preflight can consume several short block
# intervals.  Starting an exact-height observer with too little lead time
# makes a missed anchor likely before it has even begun polling.  Move to the
# next canonical boundary instead; never relabel a later height as this one.
if (( target_anchor - current_height < minimum_lead_blocks )); then
  target_anchor=$((target_anchor + epoch_length))
fi
start_height=$((target_anchor - pre_blocks))
{
  profile_summary
  printf 'profile_hash=%s\n' "$(profile_hash)"
  printf 'chain_id=%s\n' "$CHAIN_ID"
  printf 'genesis_sha256=%s\n' "$genesis_sha256"
  printf 'gateway_url=%s\n' "$gateway_url"
  printf 'credential_source=%s\n' "$key_source"
  printf 'chain_base=%s\n' "$chain_base"
  printf 'initial_height=%s\n' "$height"
  printf 'target_poc_anchor=%s\n' "$target_anchor"
  printf 'epoch_length=%s\n' "$epoch_length"
  printf 'epoch_shift=%s\n' "$epoch_shift"
  printf 'continuity_timeout_seconds=%s\n' "$timeout_seconds"
  printf 'request_timeout_seconds=%s\n' "$request_timeout"
  printf 'post_success_target=%s\n' "$post_success_target"
} >"$RUN/context.env"

deadline=$((SECONDS + timeout_seconds))
while (( height < start_height && SECONDS < deadline )); do
  printf 'WAIT  continuity window height=%s start=%s PoC=%s\n' "$height" "$start_height" "$target_anchor"
  sleep 5
  height="$(continuity_curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
done
(( height >= start_height )) || die "chain did not reach continuity start height $start_height"

step "Send authenticated requests across PoC anchor $target_anchor"
: >"$RUN/requests.jsonl"

request_observation() {
  local observation_height="$1"
  local window="$2"
  local coverage="$3"
  local sequence="$4"
  local request response http_code payload error response_id headers admission deadline_ms admission_id audit
  local arrival_height permit_height dispatch_height response_height safe_generation
  local arrival_at_ms permit_at_ms dispatch_at_ms response_at_ms upstream_http_status error_class

  request="$(jq -nc --arg prompt "continuity probe anchor $target_anchor sequence $sequence" \
    --arg model "$MODEL_ID" '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:1}')"
  headers="$RUN/request-${coverage}.headers"
  deadline_ms="$(( $(date +%s%3N) + request_timeout * 1000 ))"
  response="$(continuity_curl -sS --connect-timeout 10 --max-time "$request_timeout" -D "$headers" -w $'\n%{http_code}' \
    "$gateway_url/v1/chat/completions" -H "Authorization: Bearer $client_key" \
    -H "X-Request-Deadline-Ms: $deadline_ms" -H 'Content-Type: application/json' --data-binary "$request" || true)"
  http_code="${response##*$'\n'}"
  payload="${response%$'\n'*}"
  [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code=000
  admission="$(awk 'tolower($0) ~ /^x-gdc-admission:/ { value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/\r$/, "", value); print value; exit }' "$headers")"
  admission="${admission:-not_observed}"
  header_value() {
    local name="$1"
    awk -v name="$name" 'tolower($0) ~ "^" tolower(name) ":" { value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/\r$/, "", value); print value; exit }' "$headers"
  }
  admission_id="$(header_value X-GDC-Admission-ID)"
  arrival_height="$(header_value X-GDC-Arrival-Height)"
  permit_height="$(header_value X-GDC-Permit-Height)"
  dispatch_height="$(header_value X-GDC-Dispatch-Height)"
  response_height="$(header_value X-GDC-Response-Height)"
  safe_generation="$(header_value X-GDC-Safe-Generation)"
  error=''
  if [[ "$admission" == pre_dispatch_rejected || "$admission" == dispatch_attempt_failed ]]; then
    error="$(jq -r '.error.code? | select(type == "string" and test("^[a-z0-9_]{1,64}$"))' <<<"$payload" 2>/dev/null || true)"
  fi
  audit='{}'
  if [[ "$admission_id" =~ ^[a-f0-9]{32}$ ]]; then
    audit="$(continuity_ssh "$PUBLIC_EDGE_NODE" "sudo jq -c --arg id '$admission_id' 'select(.admission_id == \$id)' /srv/dai/edge/status/gateway-admission.jsonl 2>/dev/null | tail -n1" 2>/dev/null || true)"
    [[ -n "$audit" ]] || audit='{}'
  fi
  arrival_at_ms="$(jq -r '.arrival_at_ms // 0' <<<"$audit" 2>/dev/null || printf 0)"
  permit_at_ms="$(jq -r '.permit_at_ms // 0' <<<"$audit" 2>/dev/null || printf 0)"
  dispatch_at_ms="$(jq -r '.dispatch_at_ms // 0' <<<"$audit" 2>/dev/null || printf 0)"
  response_at_ms="$(jq -r '.response_at_ms // 0' <<<"$audit" 2>/dev/null || printf 0)"
  upstream_http_status="$(jq -r '.upstream_http_status // 0' <<<"$audit" 2>/dev/null || printf 0)"
  error_class="$(jq -r '.error_class // ""' <<<"$audit" 2>/dev/null || true)"
  rm -f "$headers"
  response_id="$(jq -r '.id // empty' <<<"$payload" 2>/dev/null || true)"
  jq -nc --arg timestamp "$(date -u +%FT%TZ)" --argjson height "$observation_height" \
    --arg window "$window" --arg coverage "$coverage" --arg phase "$chain_phase" --arg admission_id "$admission_id" \
    --arg code "$http_code" --arg error "$error" --arg admission "$admission" --arg response_id "$response_id" \
    --arg safe_generation "$safe_generation" --argjson target_anchor "$target_anchor" \
    --argjson arrival_height "${arrival_height:-0}" --argjson permit_height "${permit_height:-0}" \
    --argjson dispatch_height "${dispatch_height:-0}" --argjson response_height "${response_height:-0}" \
    --argjson arrival_at_ms "${arrival_at_ms:-0}" --argjson permit_at_ms "${permit_at_ms:-0}" \
    --argjson dispatch_at_ms "${dispatch_at_ms:-0}" --argjson response_at_ms "${response_at_ms:-0}" \
    --argjson upstream_http_status "${upstream_http_status:-0}" --arg error_class "$error_class" \
    --argjson admission_record "$audit" \
    '{timestamp:$timestamp,height:$height,target_anchor:$target_anchor,window:$window,coverage:$coverage,chain_phase:$phase,http_code:($code|tonumber),admission:$admission,error:$error,response_id:$response_id,admission_id:$admission_id,safe_generation:$safe_generation,arrival_height:$arrival_height,permit_height:$permit_height,dispatch_height:$dispatch_height,response_height:$response_height,arrival_at_ms:$arrival_at_ms,permit_at_ms:$permit_at_ms,dispatch_at_ms:$dispatch_at_ms,response_at_ms:$response_at_ms,upstream_http_status:$upstream_http_status,error_class:$error_class,admission_record:$admission_record}'
}

capture_targeted_observation() {
  local observation_target="$1"
  local window="$2"
  local coverage="$3"
  local observation_height observability_pid observation

  while (( SECONDS < deadline )); do
    observation_height="$(continuity_curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
    if (( observation_height == observation_target )); then
      mkdir -p "$RUN/observability/$coverage"
      "$ROOT/scripts/capture-gateway-observability.sh" "$RUN/observability/$coverage" \
        "$chain_base" "$gateway_url" "$observation_height" "$coverage" \
        >"$RUN/observability/$coverage/capture.log" 2>&1 &
      observability_pid=$!
      gateway_status="$(continuity_curl -sS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" || true)"
      chain_phase="$(jq -r '
        ([.devshards[]? | select(.active == true) | .chain_phase]
          + [if .chain_phase? then .chain_phase else empty end])
        | map(select(. != null and . != "")) | first // "UNKNOWN"
      ' <<<"$gateway_status" 2>/dev/null || printf UNKNOWN)"
      observation="$(request_observation "$observation_height" "$window" "$coverage" "$coverage")"
      printf '%s\n' "$observation"
      wait "$observability_pid"
      return $?
    fi
    if (( observation_height > observation_target )); then
      jq -nc --arg timestamp "$(date -u +%FT%TZ)" --argjson height "$observation_height" \
        --arg window "$window" --arg coverage "$coverage" --argjson target_anchor "$target_anchor" \
        '{timestamp:$timestamp,height:$height,target_anchor:$target_anchor,window:$window,coverage:($coverage + "-missed"),chain_phase:"UNKNOWN",http_code:0,error:"target height was missed before a request could start",response_id:""}'
      return 2
    fi
    sleep 1
  done

  jq -nc --arg timestamp "$(date -u +%FT%TZ)" --arg window "$window" \
    --arg coverage "$coverage" --argjson target_anchor "$target_anchor" \
    '{timestamp:$timestamp,height:0,target_anchor:$target_anchor,window:$window,coverage:($coverage + "-missed"),chain_phase:"UNKNOWN",http_code:0,error:"continuity deadline elapsed before target height",response_id:""}'
  return 2
}

# Slow non-streaming inference must not make the observer skip the exact block
# boundaries. These one-shot background probes use only chain-height state;
# they never retry a request and write separate files to avoid concurrent
# appends to requests.jsonl.
capture_targeted_observation "$((target_anchor - 1))" before immediate-before >"$RUN/immediate-before-request.json" &
immediate_before_pid=$!
capture_targeted_observation "$target_anchor" anchor at-anchor >"$RUN/anchor-request.json" &
anchor_pid=$!
capture_targeted_observation "$((target_anchor + 1))" poc immediate-after-anchor >"$RUN/poc-request.json" &
poc_pid=$!
snapshot_timeout=$((deadline - SECONDS))
(( snapshot_timeout > 0 )) || die 'continuity deadline elapsed before PoC snapshot capture started'
"$ROOT/scripts/capture-poc-snapshot.sh" "$chain_base" "$target_anchor" "$epoch_length" "$snapshot_timeout" "$RUN/preserved-snapshot.json" &
snapshot_pid=$!

poc_active_seen=false
after_seen=false
post_successes=0
snapshot_captured=false
sequence=0
# Boundary probes below are one-shot requests.  The former regular loop is
# intentionally disabled: it would turn a buffered user request into retries.
while false; do
  sequence=$((sequence + 1))
  height="$(continuity_curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
  gateway_status="$(continuity_curl -sS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" || true)"
  chain_phase="$(jq -r '
    ([.devshards[]? | select(.active == true) | .chain_phase]
      + [if .chain_phase? then .chain_phase else empty end])
    | map(select(. != null and . != "")) | first // "UNKNOWN"
  ' <<<"$gateway_status" 2>/dev/null || printf UNKNOWN)"

  if (( height < target_anchor )); then
    window=before
  elif [[ "$chain_phase" != Inference && "$chain_phase" != UNKNOWN ]]; then
    window=poc
    poc_active_seen=true
  elif [[ "$poc_active_seen" == true ]]; then
    window=after
    after_seen=true
  else
    window=poc
  fi

  if (( height >= target_anchor )); then
    snapshot="$(continuity_curl -sS --connect-timeout 5 --max-time 15 \
      "$chain_base/chain-api/productscience/inference/inference/preserved_nodes_snapshot" || true)"
    snapshot_anchor="$(jq -r '.snapshot.episode_anchor_height // 0 | tonumber' <<<"$snapshot" 2>/dev/null || printf 0)"
    if (( snapshot_anchor == target_anchor )); then
      jq . <<<"$snapshot" >"$RUN/preserved-snapshot.json"
      snapshot_captured=true
    fi
  fi

  observation="$(request_observation "$height" "$window" regular "$sequence")"
  http_code="$(jq -r .http_code <<<"$observation")"
  printf '%s\n' "$observation" >>"$RUN/requests.jsonl"
  printf '%s height=%s phase=%s window=%s HTTP=%s\n' \
    "$([[ "$http_code" =~ ^2 ]] && printf PASS || printf FAILED)" "$height" "$chain_phase" "$window" "$http_code"

  if [[ "$window" == after && "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    post_successes=$((post_successes + 1))
  elif [[ "$window" == after ]]; then
    post_successes=0
  fi
  if [[ "$snapshot_captured" == true && "$after_seen" == true && "$post_successes" -ge "$post_success_target" ]]; then
    break
  fi
  sleep 1
done

set +e
wait "$immediate_before_pid"
immediate_before_rc=$?
wait "$anchor_pid"
anchor_rc=$?
wait "$poc_pid"
poc_rc=$?
wait "$snapshot_pid"
snapshot_rc=$?
set -e
for observation_file in "$RUN/immediate-before-request.json" "$RUN/anchor-request.json" "$RUN/poc-request.json"; do
  if [[ -s "$observation_file" ]]; then
    cat "$observation_file" >>"$RUN/requests.jsonl"
  fi
done
if (( immediate_before_rc != 0 || anchor_rc != 0 || poc_rc != 0 )); then
  printf 'INCONCLUSIVE targeted boundary capture: immediate-before=%s anchor=%s poc=%s\n' \
    "$immediate_before_rc" "$anchor_rc" "$poc_rc" >&2
fi
if (( snapshot_rc != 0 )); then
  printf 'INCONCLUSIVE targeted PoC snapshot capture: status=%s\n' "$snapshot_rc" >&2
fi

post_successes=0
last_post_observation_height=0
last_recovery_evaluation_height=0
while (( SECONDS < deadline && post_successes < post_success_target )); do
  height="$(continuity_curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
  gateway_status="$(continuity_curl -sS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" || true)"
  chain_phase="$(jq -r '([.devshards[]? | select(.active == true) | .chain_phase] + [if .chain_phase? then .chain_phase else empty end]) | map(select(. != null and . != "")) | first // "UNKNOWN"' <<<"$gateway_status" 2>/dev/null || printf UNKNOWN)"
  # A successful request consumes the participant's current block budget.
  # Keep the independent recovery observations on distinct heights so the
  # second probe measures recovery, rather than competing with the first.
  if (( height > target_anchor && height > last_post_observation_height && height > last_recovery_evaluation_height )); then
    last_recovery_evaluation_height="$height"
    if ! capture_recovery_readiness; then
      sleep 1
      continue
    fi
    last_post_observation_height="$height"
    coverage="post-recovery-$((post_successes + 1))"
    mkdir -p "$RUN/observability/$coverage"
    "$ROOT/scripts/capture-gateway-observability.sh" "$RUN/observability/$coverage" \
      "$chain_base" "$gateway_url" "$height" "$coverage" \
      >"$RUN/observability/$coverage/capture.log" 2>&1 &
    observability_pids+=("$!")
    observation="$(request_observation "$height" after post-recovery "$((post_successes + 1))")"
    printf '%s\n' "$observation" >>"$RUN/requests.jsonl"
    http_code="$(jq -r .http_code <<<"$observation")"
    admission="$(jq -r .admission <<<"$observation")"
    if [[ "$http_code" =~ ^2[0-9][0-9]$ && "$admission" == dispatched_once ]]; then
      post_successes=$((post_successes + 1))
    else
      # One failed attempt is already decisive evidence. Do not manufacture
      # further failures by repeating requests in the same recovery window.
      break
    fi
  else
    sleep 1
  fi
done

continuity_curl -fsS "$chain_base/chain-rpc/status" >"$RUN/chain-status-after.json"
continuity_curl -fsS "$chain_base/chain-api/productscience/inference/inference/current_epoch_group_data" >"$RUN/epoch-group-after.json"
set +e
observability_rc=0
for observability_pid in "${observability_pids[@]}"; do
  wait "$observability_pid" || observability_rc=1
done
set -e
observability_incomplete=false
if (( observability_rc != 0 )); then
  printf 'INCONCLUSIVE continuity observability snapshot capture failed\n' >&2
  observability_incomplete=true
fi
expected_observability=$((3 + post_success_target))
observability_count="$(find "$RUN/observability" -name finalize.json -type f 2>/dev/null | wc -l)"
if (( observability_count < expected_observability )); then
  printf 'INCONCLUSIVE continuity observability snapshots: expected=%s captured=%s\n' \
    "$expected_observability" "$observability_count" >&2
  observability_incomplete=true
fi
if [[ ! -s "$RUN/preserved-snapshot.json" ]]; then
  printf '{"found":false,"capture":{"reason":"snapshot_not_captured"},"snapshot":{"episode_anchor_height":"%s","model_preserved_nodes":[]}}\n' \
    "$target_anchor" >"$RUN/preserved-snapshot.json"
fi

set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$MODEL_ID" \
  "$RUN/preserved-snapshot.json" "$RUN/requests.jsonl" "$RUN/verdict.md"
verdict_rc=$?
set -e
if [[ "$observability_incomplete" == true && "$verdict_rc" == 0 ]]; then
  cat >"$RUN/verdict.md" <<EOF
# Gateway continuity: INCONCLUSIVE

Authenticated requests completed, but only $observability_count of
$expected_observability required cross-surface snapshots finalized. No
continuity PASS is implied.
EOF
  verdict_rc=2
fi
case "$verdict_rc" in
  0) printf 'PASS gateway continuity evidence: %s\n' "$RUN" ;;
  1) printf 'FAILED gateway continuity evidence: %s\n' "$RUN" ;;
  2) printf 'INCONCLUSIVE gateway continuity evidence: %s\n' "$RUN" ;;
  3) printf 'BLOCKED gateway continuity evidence: %s\n' "$RUN" ;;
  *) die "unexpected continuity classifier status $verdict_rc" ;;
esac
exit "$verdict_rc"
