#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
record_phase_profile gateway-continuity

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-gateway-continuity"
mkdir -p "$RUN"
install_evidence_exit_trap 'Gateway continuity'
declare -a observability_pids=()

gateway_url="${GDC_GATEWAY_PUBLIC_URL:-https://$API_HOST}"
gateway_url="${gateway_url%/}"
chain_base="${GDC_CONTINUITY_CHAIN_BASE_URL:-https://$GENESIS_PUBLIC_HOST}"
chain_base="${chain_base%/}"
timeout_seconds="${GDC_GATEWAY_CONTINUITY_TIMEOUT_SECONDS:-900}"
pre_blocks="${GDC_GATEWAY_CONTINUITY_PRE_BLOCKS:-3}"
post_success_target="${GDC_GATEWAY_CONTINUITY_POST_SUCCESSES:-2}"
minimum_lead_blocks="${GDC_GATEWAY_CONTINUITY_MIN_LEAD_BLOCKS:-10}"
# The gateway's non-stream response floor is 20 seconds.  The observer must
# outlive that floor; an equal client timeout fabricates HTTP 000 at the exact
# boundary while a valid completion is still permitted.
request_timeout="${GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS:-270}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_TIMEOUT_SECONDS must be positive'
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

step 'Capture the live topology and calculate the next PoC boundary'
curl -fsS "$chain_base/chain-api/productscience/inference/inference/params" >"$RUN/params.json"
curl -fsS "$chain_base/chain-api/productscience/inference/inference/participant" >"$RUN/participants.json"
curl -fsS "$chain_base/chain-api/productscience/inference/inference/current_epoch_group_data" >"$RUN/epoch-group-before.json"
curl -fsS "$chain_base/chain-rpc/status" >"$RUN/chain-status-before.json"
capture_canonical_genesis "$chain_base/chain-rpc/genesis" "$RUN/genesis.json"
genesis_sha256="$(genesis_sha256 "$RUN/genesis.json")"
read -r epoch_length epoch_shift < <(
  jq -er '(.params // .).epoch_params | [(.epoch_length|tonumber),(.epoch_shift|tonumber)] | @tsv' "$RUN/params.json"
)
height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/chain-status-before.json")"
(( epoch_length > 0 )) || die 'live epoch length must be positive'
position=$(((height - epoch_shift) % epoch_length))
(( position < 0 )) && position=$((position + epoch_length))
target_anchor=$((height + epoch_length - position))
current_height="$(curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
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
} >"$RUN/context.env"

deadline=$((SECONDS + timeout_seconds))
while (( height < start_height && SECONDS < deadline )); do
  printf 'WAIT  continuity window height=%s start=%s PoC=%s\n' "$height" "$start_height" "$target_anchor"
  sleep 5
  height="$(curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
done
(( height >= start_height )) || die "chain did not reach continuity start height $start_height"

step "Send authenticated requests across PoC anchor $target_anchor"
: >"$RUN/requests.jsonl"

request_observation() {
  local observation_height="$1"
  local window="$2"
  local coverage="$3"
  local sequence="$4"
  local request response http_code payload error response_id headers admission

  request="$(jq -nc --arg prompt "continuity probe anchor $target_anchor sequence $sequence" \
    --arg model "$MODEL_ID" '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:1}')"
  headers="$RUN/request-${coverage}.headers"
  response="$(curl -sS --connect-timeout 10 --max-time "$request_timeout" -D "$headers" -w $'\n%{http_code}' \
    "$gateway_url/v1/chat/completions" -H "Authorization: Bearer $client_key" \
    -H 'Content-Type: application/json' --data-binary "$request" || true)"
  http_code="${response##*$'\n'}"
  payload="${response%$'\n'*}"
  [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code=000
  admission="$(awk 'tolower($0) ~ /^x-gdc-admission:/ { value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/\r$/, "", value); print value; exit }' "$headers")"
  admission="${admission:-not_observed}"
  error=''
  if [[ "$admission" == pre_dispatch_rejected || "$admission" == dispatch_attempt_failed ]]; then
    error="$(jq -r '.error.code? | select(type == "string" and test("^[a-z0-9_]{1,64}$"))' <<<"$payload" 2>/dev/null || true)"
  fi
  rm -f "$headers"
  response_id="$(jq -r '.id // empty' <<<"$payload" 2>/dev/null || true)"
  jq -nc --arg timestamp "$(date -u +%FT%TZ)" --argjson height "$observation_height" \
    --arg window "$window" --arg coverage "$coverage" --arg phase "$chain_phase" \
    --arg code "$http_code" --arg error "$error" --arg admission "$admission" --arg response_id "$response_id" \
    --argjson target_anchor "$target_anchor" \
    '{timestamp:$timestamp,height:$height,target_anchor:$target_anchor,window:$window,coverage:$coverage,chain_phase:$phase,http_code:($code|tonumber),admission:$admission,error:$error,response_id:$response_id}'
}

capture_targeted_observation() {
  local observation_target="$1"
  local window="$2"
  local coverage="$3"
  local observation_height observability_pid observation

  while (( SECONDS < deadline )); do
    observation_height="$(curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
    if (( observation_height == observation_target )); then
      mkdir -p "$RUN/observability/$coverage"
      "$ROOT/scripts/capture-gateway-observability.sh" "$RUN/observability/$coverage" \
        "$chain_base" "$gateway_url" "$observation_height" "$coverage" \
        >"$RUN/observability/$coverage/capture.log" 2>&1 &
      observability_pid=$!
      gateway_status="$(curl -sS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" || true)"
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
  height="$(curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
  gateway_status="$(curl -sS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" || true)"
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
    snapshot="$(curl -sS --connect-timeout 5 --max-time 15 \
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
while (( SECONDS < deadline && post_successes < post_success_target )); do
  height="$(curl -fsS "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')"
  gateway_status="$(curl -sS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" || true)"
  chain_phase="$(jq -r '([.devshards[]? | select(.active == true) | .chain_phase] + [if .chain_phase? then .chain_phase else empty end]) | map(select(. != null and . != "")) | first // "UNKNOWN"' <<<"$gateway_status" 2>/dev/null || printf UNKNOWN)"
  # A successful request consumes the participant's current block budget.
  # Keep the independent recovery observations on distinct heights so the
  # second probe measures recovery, rather than competing with the first.
  if (( height > target_anchor && height > last_post_observation_height )) && [[ "$chain_phase" == Inference ]]; then
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

curl -fsS "$chain_base/chain-rpc/status" >"$RUN/chain-status-after.json"
curl -fsS "$chain_base/chain-api/productscience/inference/inference/current_epoch_group_data" >"$RUN/epoch-group-after.json"
set +e
observability_rc=0
for observability_pid in "${observability_pids[@]}"; do
  wait "$observability_pid" || observability_rc=1
done
set -e
if (( observability_rc != 0 )); then
  printf 'INCONCLUSIVE continuity observability snapshot capture failed\n' >&2
  exit 2
fi
expected_observability=$((3 + post_success_target))
observability_count="$(find "$RUN/observability" -name finalize.json -type f 2>/dev/null | wc -l)"
if (( observability_count < expected_observability )); then
  printf 'INCONCLUSIVE continuity observability snapshots: expected=%s captured=%s\n' \
    "$expected_observability" "$observability_count" >&2
  exit 2
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
case "$verdict_rc" in
  0) printf 'PASS gateway continuity evidence: %s\n' "$RUN" ;;
  1) printf 'FAILED gateway continuity evidence: %s\n' "$RUN" ;;
  2) printf 'INCONCLUSIVE gateway continuity evidence: %s\n' "$RUN" ;;
  3) printf 'BLOCKED gateway continuity evidence: %s\n' "$RUN" ;;
  *) die "unexpected continuity classifier status $verdict_rc" ;;
esac
exit "$verdict_rc"
