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
unavailability_file="${GDC_GATEWAY_UNAVAILABILITY_FILE:-$(dirname "$status_file")/gateway-unavailability.json}"
transport_backoff_file="${GDC_GATEWAY_TRANSPORT_BACKOFF_FILE:-$(dirname "$status_file")/gateway-admission-transport.json}"
replacement_max_attempts="${GDC_GATEWAY_REPLACEMENT_MAX_ATTEMPTS:-1}"
replacement_backoff_seconds="${GDC_GATEWAY_REPLACEMENT_BACKOFF_SECONDS:-60}"
replacement_unavailability_observations="${GDC_GATEWAY_REPLACEMENT_UNAVAILABILITY_OBSERVATIONS:-2}"
transport_backoff_seconds="${GDC_GATEWAY_TRANSPORT_BACKOFF_SECONDS:-15}"
transport_backoff_max_seconds="${GDC_GATEWAY_TRANSPORT_BACKOFF_MAX_SECONDS:-120}"

mkdir -p "$(dirname "$status_file")"
exec 9>"$lock_file"
flock -n 9 || exit 0

write_status() {
  local state="$1" reason="$2" replacement="${3:-}"
  local tmp checked_at entered_at last_confirmed_at last_confirmed_state
  checked_at="$(date -u +%FT%TZ)"
  entered_at="$(jq -r --arg state "$state" --arg reason "$reason" --arg replacement "$replacement" '
    select(.state == $state and .reason == $reason and (.replacement_escrow // "") == $replacement)
    | .entered_at // .checked_at // empty
  ' "$status_file" 2>/dev/null || true)"
  [[ -n "$entered_at" ]] || entered_at="$checked_at"
  last_confirmed_at="$(jq -r 'if .state == "READY" then .checked_at else .last_confirmed_at // empty end' "$status_file" 2>/dev/null || true)"
  last_confirmed_state="$(jq -r 'if .state == "READY" then "READY" else .last_confirmed_state // empty end' "$status_file" 2>/dev/null || true)"
  if [[ "$state" == READY ]]; then
    last_confirmed_at="$checked_at"
    last_confirmed_state=READY
  fi
  tmp="$(mktemp "${status_file}.tmp.XXXXXX")"
  jq -n --arg state "$state" --arg reason "$reason" --arg replacement_escrow "$replacement" \
    --arg checked_at "$checked_at" --arg entered_at "$entered_at" --arg last_confirmed_at "$last_confirmed_at" \
    --arg last_confirmed_state "$last_confirmed_state" \
    '{state:$state,reason:$reason,replacement_escrow:$replacement_escrow,entered_at:$entered_at,checked_at:$checked_at}
     + (if $last_confirmed_at == "" then {} else {last_confirmed_at:$last_confirmed_at,last_confirmed_state:$last_confirmed_state} end)' >"$tmp" || {
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

clear_unavailability() {
  rm -f -- "$unavailability_file"
}

clear_transport_backoff() {
  rm -f -- "$transport_backoff_file"
}

transport_backoff_active() {
  local next_attempt_at now_epoch next_epoch
  [[ -f "$transport_backoff_file" ]] || return 1
  next_attempt_at="$(jq -r '.next_attempt_at // empty' "$transport_backoff_file" 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"
  next_epoch="$(date -u -d "$next_attempt_at" +%s 2>/dev/null || printf 0)"
  (( now_epoch < next_epoch )) || return 1
  jq -r '.failure_class // "connection_timeout"' "$transport_backoff_file"
}

record_transport_failure() {
  local failure_class="$1" previous observations delay_seconds next_attempt_at tmp
  previous="$(jq -c --arg failure_class "$failure_class" \
    'select(type == "object" and .failure_class == $failure_class) // empty' \
    "$transport_backoff_file" 2>/dev/null || true)"
  observations=1
  [[ -z "$previous" ]] || observations=$(( $(jq -r '.observations // 0' <<<"$previous") + 1 ))
  delay_seconds=$(( transport_backoff_seconds * (2 ** (observations - 1)) ))
  (( delay_seconds <= transport_backoff_max_seconds )) || delay_seconds="$transport_backoff_max_seconds"
  next_attempt_at="$(date -u -d "+${delay_seconds} seconds" +%FT%TZ)"
  tmp="$(mktemp "${transport_backoff_file}.tmp.XXXXXX")"
  jq -n --arg failure_class "$failure_class" --arg next_attempt_at "$next_attempt_at" \
    --argjson observations "$observations" --argjson delay_seconds "$delay_seconds" \
    '{failure_class:$failure_class,observations:$observations,delay_seconds:$delay_seconds,next_attempt_at:$next_attempt_at,checked_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' >"$tmp"
  chmod 0644 "$tmp"
  mv -fT -- "$tmp" "$transport_backoff_file"
}

observe_unavailability() {
  local generation="$1" reason="$2" previous count tmp
  previous="$(jq -c --arg generation "$generation" \
    'select(type == "object" and .generation == $generation) // empty' \
    "$unavailability_file" 2>/dev/null || true)"
  count=1
  [[ -z "$previous" ]] || count=$(( $(jq -r '.observations // 0' <<<"$previous") + 1 ))
  tmp="$(mktemp "${unavailability_file}.tmp.XXXXXX")"
  jq -n --arg generation "$generation" --arg reason "$reason" --argjson observations "$count" \
    '{generation:$generation,reason:$reason,observations:$observations,checked_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' >"$tmp"
  chmod 0644 "$tmp"
  mv -fT -- "$tmp" "$unavailability_file"
  printf '%s\n' "$count"
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
if ! [[ "$replacement_max_attempts" =~ ^[1-9][0-9]*$ && "$replacement_backoff_seconds" =~ ^[1-9][0-9]*$ && "$replacement_unavailability_observations" =~ ^[0-9]+$ && "$transport_backoff_seconds" =~ ^[1-9][0-9]*$ && "$transport_backoff_max_seconds" =~ ^[1-9][0-9]*$ ]] \
  || (( replacement_unavailability_observations < 2 || transport_backoff_max_seconds < transport_backoff_seconds )); then
  write_status FAILED replacement_attempt_configuration_invalid
  exit 1
fi

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
DEVSHARD_BINARY_URL="$(gateway_env_value DEVSHARD_BINARY_URL 2>/dev/null || true)"
DEVSHARD_BINARY_SHA256="$(gateway_env_value DEVSHARD_BINARY_SHA256 2>/dev/null || true)"
DEVSHARD_ROTATION_ESCROW_AMOUNT="$(gateway_env_value DEVSHARD_ROTATION_ESCROW_AMOUNT 2>/dev/null || true)"
GDC_GATEWAY_ADMISSION_URL="$(gateway_env_value GDC_GATEWAY_ADMISSION_URL 2>/dev/null || true)"
if [[ -z "$GDC_GATEWAY_ADMISSION_URL" ]]; then
  admission_host="$(awk -F= '$1 == "API_HOST" {print substr($0, index($0, "=") + 1); exit}' "$(dirname "$gateway_env")/.env" 2>/dev/null || true)"
  [[ "$admission_host" =~ ^[A-Za-z0-9.-]+$ ]] && GDC_GATEWAY_ADMISSION_URL="https://$admission_host"
fi
GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED="$(gateway_env_value GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED 2>/dev/null || printf true)"
expected_host_count="${GDC_GATEWAY_EXPECTED_HOST_COUNT:-$(gateway_env_value GDC_GATEWAY_EXPECTED_HOST_COUNT 2>/dev/null || printf 0)}"
[[ "$expected_host_count" =~ ^[0-9]+$ ]] || {
  echo 'GDC_GATEWAY_EXPECTED_HOST_COUNT must be a non-negative integer' >&2
  exit 2
}
[[ "${GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED:-true}" == true ]] || {
  write_status PENDING reconciliation_disabled
  exit 0
}
[[ -n "${DEVSHARD_ADMIN_API_KEY:-}" && -n "${DEVSHARD_PRIVATE_KEY:-}" && -n "${DEVSHARD_MODEL:-}" \
  && "$DEVSHARD_ROUTE_PREFIX" =~ ^/devshard/v[1-9][0-9]*$ \
  && "$DEVSHARD_BINARY_URL" =~ ^https:// && "$DEVSHARD_BINARY_SHA256" =~ ^[0-9a-f]{64}$ \
  && "$GDC_GATEWAY_ADMISSION_URL" =~ ^https://[A-Za-z0-9.-]+$ ]] || {
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
admission_post() {
  local path="$1" payload="$2" timeout_seconds="$3" deadline_ms stderr status rc failure_class
  deadline_ms="$(( $(date +%s%3N) + timeout_seconds * 1000 ))"
  stderr="$(mktemp)"
  rc=0
  status="$(curl -sS --connect-timeout 3 --max-time "$timeout_seconds" -o "$4" -w '%{http_code}' \
    -X POST "$GDC_GATEWAY_ADMISSION_URL$path" \
    -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" -H 'Content-Type: application/json' \
    -H "X-Request-Deadline-Ms: $deadline_ms" --data "$payload" 2>"$stderr")" || rc=$?
  if (( rc != 0 )); then
    case "$rc" in
      6) failure_class=dns_resolution_failed ;;
      7) failure_class=connection_refused ;;
      28) failure_class=connection_timeout ;;
      35|51|58|60) failure_class=tls_failed ;;
      *) failure_class=connection_timeout ;;
    esac
    rm -f -- "$stderr"
    printf 'transport:%s\n' "$failure_class"
    return 0
  fi
  rm -f -- "$stderr"
  if [[ "$status" =~ ^5[0-9][0-9]$ ]]; then
    printf 'transport:http_5xx\n'
  else
    printf '%s\n' "$status"
  fi
}
chain_escrow() {
  curl -fsS --connect-timeout 3 --max-time 15 \
    "$chain_rest/productscience/inference/inference/devshard_escrow/$1"
}

live_protocol_approved() {
  local params version
  version="${DEVSHARD_ROUTE_PREFIX##*/}"
  params="$(curl -fsS --connect-timeout 3 --max-time 15 \
    "$chain_rest/productscience/inference/inference/params")" || return 2
  jq -e '
    (.params // .).devshard_escrow_params.approved_versions as $versions
    | ($versions | type) == "array"
    and all($versions[];
      type == "object"
      and (.name | type == "string" and test("^v[1-9][0-9]*$"))
      and (.binary | type == "string" and test("^https://"))
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    and (($versions | map(.name) | length) == ($versions | map(.name) | unique | length))
  ' \
    <<<"$params" >/dev/null 2>&1 || return 2
  jq -e --arg version "$version" --arg url "$DEVSHARD_BINARY_URL" \
    --arg sha256 "$DEVSHARD_BINARY_SHA256" '
      (.params // .).devshard_escrow_params.approved_versions as $versions
      | ([$versions[] | select(.name == $version)] | length == 1)
      and ([$versions[] | select(.name == $version)][0]
        | .binary == $url and .sha256 == $sha256)
    ' <<<"$params" >/dev/null 2>&1
}

require_live_protocol_approval() {
  local runtime_id="${1:-}" runtime_active="${2:-false}" approval_rc=0 state reason
  live_protocol_approved || approval_rc=$?
  (( approval_rc != 0 )) || return 0
  if (( approval_rc == 1 )) \
    && [[ "$runtime_active" == true && "$runtime_id" =~ ^[1-9][0-9]*$ ]] \
    && ! admin_post "/v1/admin/devshards/$runtime_id/deactivate" '{}' >/dev/null 2>&1; then
    write_status FAILED devshard_protocol_deactivation_failed "$runtime_id"
    return 1
  fi
  if (( approval_rc == 1 )); then
    state=PENDING
    reason=devshard_protocol_not_approved
  else
    state=DEGRADED
    reason=devshard_protocol_approval_unavailable
  fi
  write_status "$state" "$reason" "$runtime_id"
  return 1
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
  local id="$1" body status backoff_class recovery_attempt=0
  local payload
  payload="$(jq -cn --arg model "$DEVSHARD_MODEL" \
    '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:8,stream:true}')"
  while (( recovery_attempt < 12 )); do
    ((recovery_attempt += 1))
    runtime_requires_poc_probation_recovery "$id" || return 0
    if backoff_class="$(transport_backoff_active)"; then
      write_status DEGRADED "$backoff_class" "$id"
      return 3
    fi
    body="$(mktemp)"
    status="$(admission_post "/devshard/$id/v1/chat/completions" "$payload" 45 "$body")"
    if [[ "$status" == transport:* ]]; then
      rm -f -- "$body"
      record_transport_failure "${status#transport:}"
      write_status DEGRADED "${status#transport:}" "$id"
      return 3
    fi
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
  local id="$1" body status settings backoff_class capacity_status
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
  if backoff_class="$(transport_backoff_active)"; then
    write_status DEGRADED "$backoff_class" "$id"
    return 3
  fi
  body="$(mktemp)"
  trap 'rm -f "$body"' RETURN
  status="$(admission_post "/devshard/$id/v1/chat/completions" "$probe_payload" 30 "$body")"
  if [[ "$status" == transport:* ]]; then
    record_transport_failure "${status#transport:}"
    write_status DEGRADED "${status#transport:}" "$id"
    return 3
  fi
  if [[ "$status" != 200 ]] || ! jq -e '.choices | type == "array" and length > 0' "$body" >/dev/null 2>&1; then
    write_status DEGRADED versiond_session_pending "$id"
    return 1
  fi
  clear_transport_backoff
  clear_unavailability
  if (( expected_host_count > 0 )); then
    capacity_status="$(admin_get /v1/status 2>/dev/null || true)"
    if ! jq -e --argjson expected "$expected_host_count" '
      (.capacity.host_count | tonumber) == $expected
      and (.capacity.available_host_count | tonumber) == $expected
    ' <<<"$capacity_status" >/dev/null 2>&1; then
      write_status DEGRADED fleet_capacity_incomplete "$id"
      return 4
    fi
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
if jq -e '(
  ([.devshards[]? | .chain_phase] + [.chain_phase?]
    | any(. != null and . != "" and . != "Inference"))
  or
  ([.devshards[]? | .confirmation_poc_phase] + [.confirmation_poc_phase?]
    | any(. != null and . != "" and . != "NORMAL_OPERATION"))
)' \
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
  # Confirmation PoC deliberately suspends normal user inference. A probe in
  # that phase cannot distinguish the expected admission result from a broken
  # versiond session, and may turn a short transition into replacement churn.
  # Preserve all existing runtime and reserve state until normal operation
  # resumes, then evaluate routability on its real inference path.
  write_status DEGRADED runtime_not_routable
  exit 0
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
    # The gateway's internal rotator may expose an already-active runtime
    # without passing through this controller's activation branch. Recheck the
    # exact governed artifact before any such runtime can be probed or reported
    # READY. Public admission independently checks the same exact chain tuple.
    if [[ "$active" == true && "$phase" == active && "$blocked" != true ]]; then
      require_live_protocol_approval "$id" true || exit 0
    fi
    # A replacement creation is asynchronous.  Its ID remains reserved until
    # chain confirmation even when a replica briefly reports found:false.
    if [[ "$id" == "$pending_id" ]]; then
      if [[ "$active" == true && "$phase" == active && "$blocked" != true ]]; then
        bind_and_probe_runtime "$id" || exit 0
      else
        if require_live_protocol_approval "$id"; then
          if admin_post "/v1/admin/devshards/$id/activate" '{}' >/dev/null 2>&1; then
            bind_and_probe_runtime "$id" || exit 0
          else
            write_status RECOVERING waiting_for_routable_runtime "$id"
          fi
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
      # that authoritative state instead of trying older pool members. A
      # classified transport failure is likewise a degraded observation, not
      # evidence that a different runtime needs activation or replacement.
      ((probe_rc == 2 || probe_rc == 3 || probe_rc == 4)) && exit 0
    fi
  done
  write_status DEGRADED versiond_session_pending "${valid_active_ids[0]}"
  exit 0
fi

if ((${#unknown_ids[@]} > 0)); then
  write_status DEGRADED connection_timeout
  exit 0
fi

# A PoC window has an authoritative preserved participant set. Creating a new
# escrow after locally deactivating non-preserved runtimes cannot make it
# eligible in that window and only consumes the bounded reserve. Wait for the
# native lifecycle to expose a routable preserved runtime instead.
if [[ "$poc_active" == true ]]; then
  write_status DEGRADED runtime_not_routable
  exit 0
fi

# There is no chain-valid runtime.  The documented gateway API persists a new
# runtime as active at creation time; it has no per-runtime staging state.  A
# targeted owner chat below binds the versiond session immediately afterwards.
# Do not use the global disabled setting here: it also blocks that owner chat.
# The public status remains RECOVERING until the bound-session probe passes.
require_live_protocol_approval || exit 0
if ! jq -e '.state == "READY" and (.current_balance | tonumber) >= (.low_watermark | tonumber)' "$reserve_file" >/dev/null 2>&1; then
  write_status RECOVERING replacement_reserve_not_ready
  exit 1
fi
generation="$(replacement_generation)" || {
  write_status RECOVERING replacement_generation_unavailable
  exit 1
}
unavailability_observations="$(observe_unavailability "$generation" runtime_not_routable)"
if (( unavailability_observations < replacement_unavailability_observations )); then
  write_status DEGRADED runtime_not_routable
  exit 0
fi
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
