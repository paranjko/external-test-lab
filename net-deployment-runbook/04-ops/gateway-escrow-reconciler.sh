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
lock_file="${GDC_GATEWAY_RECONCILIATION_LOCK:-/run/gdc-gateway-escrow-reconciler.lock}"

mkdir -p "$(dirname "$status_file")"
exec 9>"$lock_file"
flock -n 9 || exit 0

write_status() {
  local state="$1" reason="$2" replacement="${3:-}"
  local tmp="${status_file}.tmp"
  jq -n --arg state "$state" --arg reason "$reason" --arg replacement_escrow "$replacement" \
    --arg checked_at "$(date -u +%FT%TZ)" \
    '{state:$state,reason:$reason,replacement_escrow:$replacement_escrow,checked_at:$checked_at}' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$status_file"
}

[[ -s "$gateway_env" && -f "$gateway_env" && ! -L "$gateway_env" ]] || {
  write_status PENDING gateway_credentials_unavailable
  exit 0
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

bind_and_open_replacement() {
  local id="$1" body status
  # Recover cleanly from older controller revisions which used the global
  # disabled flag.  New revisions never set it, but an owner chat cannot bind
  # while it remains enabled.
  admin_post /v1/admin/settings '{"disabled":{"enabled":false}}' >/dev/null || {
    write_status FAILED gateway_admission_cannot_be_opened "$id"
    return 1
  }
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

pending_id="$(jq -r 'select(.state == "RECOVERING" and .reason == "waiting_for_chain_confirmation") | .replacement_escrow // empty' "$status_file" 2>/dev/null || true)"
valid_active_ids=()
unknown_ids=()
while IFS=$'\t' read -r id active phase blocked; do
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || continue
  escrow="$(chain_escrow "$id" 2>/dev/null || true)"
  if jq -e --arg id "$id" '.found == true and (.escrow.id | tostring) == $id and ((.escrow.settled // .settled // false) != true)' <<<"$escrow" >/dev/null 2>&1; then
    # A replacement creation is asynchronous.  Its ID remains reserved until
    # chain confirmation even when a replica briefly reports found:false.
    if [[ "$id" == "$pending_id" ]]; then
      if [[ "$active" == true && "$phase" == active && "$blocked" != true ]]; then
        bind_and_open_replacement "$id" || exit 0
      else
        write_status RECOVERING waiting_for_routable_runtime "$id"
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
done < <(jq -r '.devshards[]? | [(.id // empty), (.active == true), (.phase // ""), (.requests_blocked // false)] | @tsv' <<<"$admin_state")

if ((${#valid_active_ids[@]} > 0)); then
  # A gateway pool must not route a request to a second, merely chain-valid
  # escrow while the chosen runtime is being replaced or PoC has narrowed the
  # allowed hosts.  Keep one drain-safe public runtime; historical runtimes
  # remain registered for settlement and can be reactivated by reconciliation.
  selected_id="${valid_active_ids[0]}"
  for id in "${valid_active_ids[@]:1}"; do
    admin_post "/v1/admin/devshards/$id/deactivate" '{}' >/dev/null 2>&1 || true
  done
  bind_and_open_replacement "$selected_id" || exit 0
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
write_status RECOVERING replacement_escrow_creating

create_payload="$(jq -cn --arg key "$DEVSHARD_PRIVATE_KEY" --arg model "$DEVSHARD_MODEL" --arg route "${DEVSHARD_ROUTE_PREFIX:-}" --arg chain_id "${DEVSHARD_CHAIN_ID:-}" \
  --argjson amount "${DEVSHARD_ROTATION_ESCROW_AMOUNT:-0}" \
  '{private_key:$key,model_id:$model,route_prefix:$route,chain_id:$chain_id,amount:$amount,register:true}')"
create_response="$(admin_post /v1/admin/escrows "$create_payload" 2>/dev/null || true)"
replacement_id="$(jq -r '.escrow_id // empty | tostring' <<<"$create_response" 2>/dev/null || true)"
if [[ ! "$replacement_id" =~ ^[1-9][0-9]*$ ]]; then
  write_status FAILED replacement_escrow_creation_failed
  exit 0
fi

replacement_chain="$(chain_escrow "$replacement_id" 2>/dev/null || true)"
if ! jq -e --arg id "$replacement_id" '.found == true and (.escrow.id | tostring) == $id and ((.escrow.settled // .settled // false) != true)' <<<"$replacement_chain" >/dev/null 2>&1; then
  write_status RECOVERING waiting_for_chain_confirmation "$replacement_id"
  exit 0
fi

bind_and_open_replacement "$replacement_id" || exit 0
