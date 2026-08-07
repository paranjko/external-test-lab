#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
record_phase_profile gateway-continuity

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-gateway-continuity"
mkdir -p "$RUN"
install_evidence_exit_trap 'Gateway continuity'

gateway_url="${GDC_GATEWAY_PUBLIC_URL:-https://$API_HOST}"
gateway_url="${gateway_url%/}"
chain_base="${GDC_CONTINUITY_CHAIN_BASE_URL:-https://$NODE0_PUBLIC_HOST}"
chain_base="${chain_base%/}"
timeout_seconds="${GDC_GATEWAY_CONTINUITY_TIMEOUT_SECONDS:-900}"
pre_blocks="${GDC_GATEWAY_CONTINUITY_PRE_BLOCKS:-3}"
post_success_target="${GDC_GATEWAY_CONTINUITY_POST_SUCCESSES:-2}"
# The gateway's non-stream response floor is 20 seconds.  The observer must
# outlive that floor; an equal client timeout fabricates HTTP 000 at the exact
# boundary while a valid completion is still permitted.
request_timeout="${GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS:-45}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_TIMEOUT_SECONDS must be positive'
[[ "$pre_blocks" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_PRE_BLOCKS must be positive'
[[ "$post_success_target" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_POST_SUCCESSES must be positive'
[[ "$request_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS must be positive'

# The continuity verdict must exercise the same credential class a visitor
# receives from Telegram.  A privileged technical key can keep passing while
# all pool keys are rejected by gateway policy or participant throttling.
key_source="${GDC_GATEWAY_CONTINUITY_KEY_SOURCE:-telegram-pool}"
case "$key_source" in
  telegram-pool)
    client_key="$(ssh -T gdc-node0 'jq -r ".keys[0] // empty" /srv/dai/gonka-devnet-bot/gateway-key-pool.json')"
    [[ "$client_key" == sk-gdc-* ]] || die 'Telegram key pool is absent or invalid; run bootstrap-access or telegram-bot first'
    ;;
  technical)
    key_file="$SECRETS/gateway.client-keys"
    [[ -s "$key_file" ]] || die 'gateway client keys are absent; run bootstrap-access or ops gateway first'
    client_key="$(cut -d, -f1 "$key_file")"
    [[ -n "$client_key" ]] || die 'gateway client key is empty'
    ;;
  *) die 'GDC_GATEWAY_CONTINUITY_KEY_SOURCE must be telegram-pool or technical' ;;
esac

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
poc_active_seen=false
after_seen=false
post_successes=0
snapshot_captured=false
sequence=0
while (( SECONDS < deadline )); do
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

  request="$(jq -nc --arg prompt "continuity probe anchor $target_anchor sequence $sequence" \
    --arg model "$MODEL_ID" '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:1}')"
  response="$(curl -sS --connect-timeout 10 --max-time "$request_timeout" -w $'\n%{http_code}' \
    "$gateway_url/v1/chat/completions" -H "Authorization: Bearer $client_key" \
    -H 'Content-Type: application/json' --data-binary "$request" || true)"
  http_code="${response##*$'\n'}"
  payload="${response%$'\n'*}"
  [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code=000
  error="$(jq -r '.error.message // .message // empty' <<<"$payload" 2>/dev/null || true)"
  response_id="$(jq -r '.id // empty' <<<"$payload" 2>/dev/null || true)"
  jq -nc --arg timestamp "$(date -u +%FT%TZ)" --argjson height "$height" \
    --arg window "$window" --arg phase "$chain_phase" --arg code "$http_code" \
    --arg error "$error" --arg response_id "$response_id" \
    '{timestamp:$timestamp,height:$height,window:$window,chain_phase:$phase,http_code:($code|tonumber),error:$error,response_id:$response_id}' \
    >>"$RUN/requests.jsonl"
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

curl -fsS "$chain_base/chain-rpc/status" >"$RUN/chain-status-after.json"
curl -fsS "$chain_base/chain-api/productscience/inference/inference/current_epoch_group_data" >"$RUN/epoch-group-after.json"
if [[ "$snapshot_captured" != true ]]; then
  printf '{"found":false,"snapshot":{"episode_anchor_height":"%s","model_preserved_nodes":[]}}\n' \
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
