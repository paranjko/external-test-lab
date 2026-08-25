#!/usr/bin/env bash
set -Eeuo pipefail

# Reconcile the *external* lifecycle of persistent gateway runtimes.  The
# gateway itself already rotates healthy escrows around a PoC boundary.  This
# controller covers the other direction: an escrow which the chain has pruned
# or settled must never remain a locally "active" but unroutable runtime.

gateway_env="${GDC_GATEWAY_ENV:-/srv/dai/ops/gateway.env}"
status_file="${GDC_GATEWAY_RECONCILIATION_FILE:-/srv/dai/ops/status/gateway-reconciliation.json}"
gateway_url="${GDC_GATEWAY_RECONCILIATION_URL:-http://127.0.0.1:18080}"
chain_rest="${GDC_GATEWAY_CHAIN_REST:-http://127.0.0.1:1317}"
lock_file="${GDC_GATEWAY_RECONCILIATION_LOCK:-$(dirname "$status_file")/gateway-escrow-reconciler.lock}"
reserve_file="${GDC_GATEWAY_RESERVE_FILE:-$(dirname "$status_file")/gateway-reserve.json}"
replacement_attempt_file="${GDC_GATEWAY_REPLACEMENT_ATTEMPT_FILE:-$(dirname "$status_file")/gateway-replacement-attempt.json}"
replacement_max_attempts="${GDC_GATEWAY_REPLACEMENT_MAX_ATTEMPTS:-1}"
replacement_backoff_seconds="${GDC_GATEWAY_REPLACEMENT_BACKOFF_SECONDS:-60}"

mkdir -p "$(dirname "$status_file")"
exec 9>"$lock_file"
flock -n 9 || exit 0

write_status() {
  local state="$1" reason="$2" replacement="${3:-}"
  local tmp checked_at entered_at
  checked_at="$(date -u +%FT%TZ)"
  entered_at="$(jq -r --arg state "$state" --arg reason "$reason" --arg replacement "$replacement" '
    select(.state == $state and .reason == $reason and (.replacement_escrow // "") == $replacement)
    | .entered_at // .checked_at // empty
  ' "$status_file" 2>/dev/null || true)"
  [[ -n "$entered_at" ]] || entered_at="$checked_at"
  tmp="$(mktemp "${status_file}.tmp.XXXXXX")"
  jq -n --arg state "$state" --arg reason "$reason" --arg replacement_escrow "$replacement" \
    --arg checked_at "$checked_at" --arg entered_at "$entered_at" \
    '{state:$state,reason:$reason,replacement_escrow:$replacement_escrow,entered_at:$entered_at,checked_at:$checked_at}' >"$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  chmod 0644 "$tmp"
  mv -fT -- "$tmp" "$status_file"
}

write_replacement_attempt() {
  local attempt="$1" tmp
  tmp="$(mktemp "${replacement_attempt_file}.tmp.XXXXXX")"
  jq -c . <<<"$attempt" >"$tmp"
  chmod 0644 "$tmp"
  mv -fT "$tmp" "$replacement_attempt_file"
}

replacement_attempt() {
  jq -c 'select(type == "object" and (.identity | type) == "string" and (.generation | type) == "string")' \
    "$replacement_attempt_file" 2>/dev/null || true
}

replacement_generation() {
  local epoch
  epoch="$(curl -fsS --connect-timeout 3 --max-time 15 \
    "$chain_rest/productscience/inference/inference/current_epoch_group_data" 2>/dev/null \
    | jq -r '.epoch_group_data.epoch_index // empty' 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf 'epoch-%s\n' "$epoch"
}

[[ -s "$gateway_env" && -f "$gateway_env" && ! -L "$gateway_env" ]] || {
  write_status PENDING gateway_credentials_unavailable
  exit 0
}
[[ "$replacement_max_attempts" =~ ^[1-9][0-9]*$ && "$replacement_backoff_seconds" =~ ^[1-9][0-9]*$ ]] || {
  write_status FAILED replacement_attempt_configuration_invalid
  exit 1
}

# This runs from a root-owned systemd timer, while install-ops deliberately
# leaves /srv/dai/ops operator-owned for routine deployment.  Never source
# gateway.env here: a mode-0600 file remains executable shell input for its
# owner.  The generated file is a simple KEY=value format, so read only the
# values this controller needs as data.  Shell syntax is consequently inert.
gateway_env_value() {
  local key="$1"
  awk -v key="$key" '
    index($0, key "=") == 1 {
      if (++matches > 1) exit 2
      value = substr($0, length(key) + 2)
    }
    END { if (matches == 1) print value; else exit 1 }
  ' "$gateway_env"
}

DEVSHARD_ADMIN_API_KEY="$(gateway_env_value DEVSHARD_ADMIN_API_KEY 2>/dev/null || true)"
DEVSHARD_PRIVATE_KEY="$(gateway_env_value DEVSHARD_PRIVATE_KEY 2>/dev/null || true)"
DEVSHARD_MODEL="$(gateway_env_value DEVSHARD_MODEL 2>/dev/null || true)"
DEVSHARD_ROUTE_PREFIX="$(gateway_env_value DEVSHARD_ROUTE_PREFIX 2>/dev/null || true)"
DEVSHARD_CHAIN_ID="$(gateway_env_value DEVSHARD_CHAIN_ID 2>/dev/null || true)"
DEVSHARD_ROTATION_ESCROW_AMOUNT="$(gateway_env_value DEVSHARD_ROTATION_ESCROW_AMOUNT 2>/dev/null || true)"
GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED="$(gateway_env_value GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED 2>/dev/null || printf true)"
[[ "${GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED:-true}" == true ]] || {
  write_status PENDING reconciliation_disabled
  exit 0
}
[[ -n "${DEVSHARD_ADMIN_API_KEY:-}" && -n "${DEVSHARD_PRIVATE_KEY:-}" && -n "${DEVSHARD_MODEL:-}" ]] || {
  write_status FAILED gateway_credentials_incomplete
  exit 0
}

admin_get() {
  curl -fsS --connect-timeout 3 --max-time 15 \
    -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" "$gateway_url$1"
}
admin_post() {
  curl -fsS --connect-timeout 3 --max-time 30 -X POST \
    -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" -H 'Content-Type: application/json' \
    --data "$2" "$gateway_url$1"
}
admin_delete() {
  curl -sS --connect-timeout 3 --max-time 15 -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" "$gateway_url$1" || true
}
chain_escrow() {
  curl -fsS --connect-timeout 3 --max-time 15 \
    "$chain_rest/productscience/inference/inference/devshard_escrow/$1"
}

runtime_requires_poc_probation_recovery() {
  local id="$1" participants
  [[ "${poc_active:-false}" == true && "${preserved_participants:-[]}" != '[]' ]] || return 1
  participants="$(admin_get "/v1/admin/devshards/$id/participants" 2>/dev/null || true)"
  jq -e --argjson preserved "$preserved_participants" '
    [.participants[]?
      | .participant_key as $participant
      | select($preserved | index($participant))] as $eligible
    | ($eligible | length) > 0
      and all($eligible[];
        .probationary == true
        and .request_allowed == true
        and .quarantined != true
        and .blocked != true)
  ' <<<"$participants" >/dev/null 2>&1
}

recover_poc_probation() {
  local id="$1" body status recovery_attempt=0
  local payload
  payload="$(jq -cn --arg model "$DEVSHARD_MODEL" \
    '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:8,stream:true}')"
  while (( recovery_attempt < 12 )); do
    ((recovery_attempt += 1))
    runtime_requires_poc_probation_recovery "$id" || return 0
    body="$(mktemp)"
    status="$(curl -sS --connect-timeout 3 --max-time 45 -o "$body" -w '%{http_code}' \
      -X POST "$gateway_url/devshard/$id/v1/chat/completions" \
      -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" -H 'Content-Type: application/json' \
      --data "$payload" || true)"
    if [[ "$status" != 200 ]] || ! grep -Eq '^data: .*"choices"' "$body"; then
      rm -f -- "$body"
      write_status RECOVERING waiting_for_trusted_poc_runtime "$id"
      return 1
    fi
    rm -f -- "$body"
  done
  runtime_requires_poc_probation_recovery "$id" || return 0
  write_status RECOVERING waiting_for_trusted_poc_runtime "$id"
  return 1
}

bind_and_probe_runtime() {
  local id="$1" body status settings
  # Global admission is an operator control.  Reconciliation must never undo
  # a maintenance or incident shutdown merely to make its own probe pass.
  settings="$(admin_get /v1/admin/settings 2>/dev/null || true)"
  if jq -e '.disabled.enabled == true' <<<"$settings" >/dev/null 2>&1; then
    write_status PENDING gateway_admission_disabled "$id"
    return 2
  fi
  # A participant which recovered from quarantine remains a no-winner until
  # successful inference proves it healthy. During PoC it may be the only
  # chain-eligible Host. A bounded streaming probe can complete through the
  # gateway's existing suspicious-winner fallback and reduce that probation;
  # the canonical non-streaming probe below must still pass before READY.
  if runtime_requires_poc_probation_recovery "$id"; then
    recover_poc_probation "$id" || return 1
  fi
  # An owner chat binds the versiond session.  Target this runtime explicitly;
  # a pooled request may select an older escrow.  A successful completion is
  # stronger than querying the Genesis host versiond: routing can bind the session on a
  # different selected validator host, so a local-only /diffs probe may
  # correctly return 404 even though the routable session is healthy.
  probe_payload="$(jq -cn --arg model "$DEVSHARD_MODEL" '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:1}')"
  body="$(mktemp)"
  trap 'rm -f "$body"' RETURN
  status="$(curl -sS --connect-timeout 3 --max-time 30 -o "$body" -w '%{http_code}' \
    -X POST "$gateway_url/devshard/$id/v1/chat/completions" \
    -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" -H 'Content-Type: application/json' \
    --data "$probe_payload" || true)"
  if [[ "$status" != 200 ]] || ! jq -e '.choices | type == "array" and length > 0' "$body" >/dev/null 2>&1; then
    write_status RECOVERING waiting_for_versiond_session "$id"
    return 1
  fi
  write_status READY replacement_routable "$id"
}

admin_state="$(admin_get /v1/admin/devshards 2>/dev/null || true)"
[[ -n "$admin_state" ]] || { write_status RECOVERING gateway_admin_unavailable; exit 0; }

# During PoC the chain intentionally allows only the preserved participant
# set to run inference.  A chain-valid escrow whose slots do not contain one
# of those participants is not public capacity for that window: leaving it
# active lets the pooled router select it and return a misleading 502.  Keep
# that decision in this external controller rather than changing node code.
gateway_status="$(admin_get /v1/status 2>/dev/null || true)"
poc_active=false
if jq -e '([.devshards[]? | .chain_phase] + [.chain_phase?] | any(. != null and . != "" and . != "Inference"))' \
  <<<"$gateway_status" >/dev/null 2>&1; then
  poc_active=true
fi
preserved_participants='[]'
if [[ "$poc_active" == true ]]; then
  preserved_snapshot="$(curl -fsS --connect-timeout 3 --max-time 15 \
    "$chain_rest/productscience/inference/inference/preserved_nodes_snapshot" 2>/dev/null || true)"
  preserved_participants="$(jq -c --arg model "$DEVSHARD_MODEL" '
    [.snapshot.model_preserved_nodes[]?
      | select(.model_id == $model)
      | .participants[]?.participant_id] | unique
  ' <<<"$preserved_snapshot" 2>/dev/null || printf '[]')"
  if [[ "$preserved_participants" == '[]' ]]; then
    write_status RECOVERING waiting_for_poc_preserved_runtime
    exit 0
  fi
fi

pending_id="$(jq -r 'select(.state == "RECOVERING" or .state == "PENDING") | .replacement_escrow // empty' "$status_file" 2>/dev/null || true)"
# The gateway's built-in rotator can replace a runtime while this external
# controller is still tracking an older recovery candidate. Once a newer
# active runtime exists, the older pending ID is no longer authoritative and
# must not prevent the controller from evaluating the current pool.
if [[ "$pending_id" =~ ^[1-9][0-9]*$ ]]; then
  newer_active_id="$(jq -r --argjson pending "$pending_id" '
    [.devshards[]?
      | select(.active == true)
      | select((.runtime.phase // .phase // "") == "active")
      | select((.runtime.requests_blocked // .requests_blocked // false) != true)
      | (.id | tonumber)
      | select(. > $pending)]
    | max // empty
  ' <<<"$admin_state" 2>/dev/null || true)"
  [[ -z "$newer_active_id" ]] || pending_id=''
fi
valid_active_ids=()
unknown_ids=()
while IFS=$'\t' read -r id active phase blocked; do
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || continue
  # Chain transport failure and a chain answer are different states.  Only an
  # explicit, structurally valid `found:false` or settled escrow can permit
  # local deactivation/deletion.  In particular, a replacement may be absent
  # from a lagging REST endpoint immediately after it was created.
  if ! escrow="$(chain_escrow "$id" 2>/dev/null)"; then
    unknown_ids+=("$id")
    continue
  fi
  if ! jq -e 'type == "object" and (.found | type == "boolean")' <<<"$escrow" >/dev/null 2>&1; then
    unknown_ids+=("$id")
    continue
  fi
  if jq -e --arg id "$id" '.found == true and (.escrow.id | tostring) == $id and ((.escrow.settled // .settled // false) != true)' <<<"$escrow" >/dev/null 2>&1; then
    # A replacement creation is asynchronous.  Its ID remains reserved until
    # chain confirmation even when a replica briefly reports found:false.
    if [[ "$id" == "$pending_id" ]]; then
      if [[ "$active" == true && "$phase" == active && "$blocked" != true ]]; then
        bind_and_probe_runtime "$id" || exit 0
      else
        if admin_post "/v1/admin/devshards/$id/activate" '{}' >/dev/null 2>&1; then
          bind_and_probe_runtime "$id" || exit 0
        else
          write_status RECOVERING waiting_for_routable_runtime "$id"
        fi
      fi
      exit 0
    fi
    if [[ "$active" == true && "$phase" == active && "$blocked" != true ]]; then
      if [[ "$poc_active" == true ]] && ! jq -e --argjson preserved "$preserved_participants" '
        [(.escrow.slots // [])[]? as $slot | select($preserved | index($slot))] | length > 0
      ' <<<"$escrow" >/dev/null 2>&1; then
        # Preserve the runtime locally for the next inference phase, but keep
        # it out of the public pool until it has a chain-permitted host.
        admin_post "/v1/admin/devshards/$id/deactivate" '{}' >/dev/null 2>&1 || true
        continue
      fi
      valid_active_ids+=("$id")
    fi
    continue
  fi

  if [[ "$id" == "$pending_id" ]]; then
    write_status RECOVERING waiting_for_chain_confirmation "$id"
    exit 0
  fi

  # Only a structurally valid Chain REST response may authorise deletion.
  # Timeouts, HTTP errors and malformed JSON are retryable unknown state.
  if ! jq -e --arg id "$id" '
    (.found == false)
    or (.found == true and (.escrow.id | tostring) == $id and ((.escrow.settled // .settled // false) == true))
  ' <<<"$escrow" >/dev/null 2>&1; then
    unknown_ids+=("$id")
    continue
  fi

  # Stop routing first.  Deactivate is drain-safe; DELETE removes the local
# runtime/session storage when no request remains.  A 409 DELETE is retried
  # on the next reconciliation after the drain hook has completed.
  admin_post "/v1/admin/devshards/$id/deactivate" '{}' >/dev/null 2>&1 || true
  admin_delete "/v1/admin/devshards/$id" >/dev/null
# The gateway admin API nests live lifecycle fields below `runtime`.  Accept
# the former top-level shape as a compatibility fallback for persisted test
# fixtures and older gateway builds, but never mistake a live active runtime
# for an unknown one: that would mint a replacement on every timer tick.
done < <(jq -r '.devshards[]? | [(.id // empty), (.active == true), (.runtime.phase // .phase // ""), (.runtime.requests_blocked // .requests_blocked // false)] | @tsv' <<<"$admin_state")

if ((${#valid_active_ids[@]} > 0)); then
  # The gateway's built-in rotator owns the healthy temporary/regular pool.
  # Do not reduce that pool here: doing so makes the rotator recreate the
  # missing entries on every epoch and eventually exhausts the creator.  The
  # loop above has already removed chain-invalid entries and, during PoC, has
  # deactivated runtimes which contain no preserved participant.  Probe one of
  # the remaining chain-valid runtimes without changing its healthy peers.
  mapfile -t valid_active_ids < <(printf '%s\n' "${valid_active_ids[@]}" | sort -nr)
  for selected_id in "${valid_active_ids[@]}"; do
    if bind_and_probe_runtime "$selected_id"; then
      exit 0
    else
      probe_rc=$?
      # A manual global admission shutdown applies to every runtime. Preserve
      # that authoritative state instead of trying older pool members.
      ((probe_rc == 2)) && exit 0
    fi
  done
  write_status RECOVERING waiting_for_versiond_session "${valid_active_ids[0]}"
  exit 0
fi

if ((${#unknown_ids[@]} > 0)); then
  write_status RECOVERING chain_escrow_query_unavailable
  exit 0
fi

# There is no chain-valid runtime.  The documented gateway API persists a new
# runtime as active at creation time; it has no per-runtime staging state.  A
# targeted owner chat below binds the versiond session immediately afterwards.
# Do not use the global disabled setting here: it also blocks that owner chat.
# The public status remains RECOVERING until the bound-session probe passes.
if ! jq -e '.state == "READY" and (.current_balance | tonumber) >= (.low_watermark | tonumber)' "$reserve_file" >/dev/null 2>&1; then
  write_status RECOVERING replacement_reserve_not_ready
  exit 1
fi
generation="$(replacement_generation)" || {
  write_status RECOVERING replacement_generation_unavailable
  exit 1
}
existing_attempt="$(replacement_attempt)"
if [[ -n "$existing_attempt" ]] && [[ "$(jq -r .generation <<<"$existing_attempt")" == "$generation" ]]; then
  existing_state="$(jq -r .state <<<"$existing_attempt")"
  existing_count="$(jq -r '.attempts // 0' <<<"$existing_attempt")"
  existing_next="$(jq -r '.next_attempt_at // empty' <<<"$existing_attempt")"
  if [[ "$existing_state" == creating || "$existing_state" == submitted ]]; then
    write_status RECOVERING replacement_attempt_pending
    exit 1
  fi
  if [[ "$existing_state" == failed ]]; then
    if (( existing_count >= replacement_max_attempts )); then
      write_status FAILED replacement_attempt_limit_reached
      exit 1
    fi
    if [[ -n "$existing_next" ]] && (( $(date -u +%s) < $(date -u -d "$existing_next" +%s 2>/dev/null || printf 0) )); then
      write_status RECOVERING replacement_backoff
      exit 1
    fi
  fi
fi
write_status RECOVERING replacement_escrow_creating

attempt_count=1
if [[ -n "$existing_attempt" ]] && [[ "$(jq -r .generation <<<"$existing_attempt")" == "$generation" ]]; then
  attempt_count=$(( $(jq -r '.attempts // 0' <<<"$existing_attempt") + 1 ))
fi
attempt_identity="$(printf '%s' "$(date -u +%FT%N):$$:$RANDOM:$generation:$attempt_count" | sha256sum | cut -d' ' -f1)"
attempt="$(jq -cn --arg identity "$attempt_identity" --arg generation "$generation" --argjson attempts "$attempt_count" \
  '{identity:$identity,generation:$generation,attempts:$attempts,state:"creating",created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}')"
write_replacement_attempt "$attempt"

create_payload="$(jq -cn --arg key "$DEVSHARD_PRIVATE_KEY" --arg model "$DEVSHARD_MODEL" --arg route "${DEVSHARD_ROUTE_PREFIX:-}" --arg chain_id "${DEVSHARD_CHAIN_ID:-}" \
  --argjson amount "${DEVSHARD_ROTATION_ESCROW_AMOUNT:-0}" \
  '{private_key:$key,model_id:$model,route_prefix:$route,chain_id:$chain_id,amount:$amount,register:true}')"
create_body="$(mktemp)"
set +e
create_http="$(curl -sS --connect-timeout 3 --max-time 30 -o "$create_body" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" -H 'Content-Type: application/json' \
  --data "$create_payload" "$gateway_url/v1/admin/escrows")"
create_rc=$?
set -e
create_response="$(<"$create_body")"
rm -f -- "$create_body"
replacement_id="$(jq -r '.escrow_id // empty | tostring' <<<"$create_response" 2>/dev/null || true)"
if [[ ! "$replacement_id" =~ ^[1-9][0-9]*$ ]]; then
  if (( create_rc != 0 )); then
    creation_class=curl_failure
  elif [[ "$create_http" =~ ^[45][0-9][0-9]$ ]]; then
    creation_class="http_${create_http}"
  else
    creation_class=invalid_response
  fi
  retry_at="$(date -u -d "+${replacement_backoff_seconds} seconds" +%FT%TZ)"
  attempt="$(jq --arg failure_class "$creation_class" --arg retry_at "$retry_at" '(.state="failed") + {failure_class:$failure_class,next_attempt_at:$retry_at,failed_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' <<<"$attempt")"
  write_replacement_attempt "$attempt"
  write_status FAILED replacement_escrow_creation_failed
  exit 1
fi
attempt="$(jq --arg replacement_escrow "$replacement_id" '(.state="submitted") + {replacement_escrow:$replacement_escrow,submitted_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' <<<"$attempt")"
write_replacement_attempt "$attempt"

replacement_chain="$(chain_escrow "$replacement_id" 2>/dev/null || true)"
if ! jq -e --arg id "$replacement_id" '.found == true and (.escrow.id | tostring) == $id and ((.escrow.settled // .settled // false) != true)' <<<"$replacement_chain" >/dev/null 2>&1; then
  write_status RECOVERING waiting_for_chain_confirmation "$replacement_id"
  exit 0
fi

bind_and_probe_runtime "$replacement_id" || exit 0
