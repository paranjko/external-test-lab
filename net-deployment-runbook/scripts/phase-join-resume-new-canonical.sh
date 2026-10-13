#!/usr/bin/env bash
# Continue a fresh JOIN that reached a signerless canonical runtime.  This is
# intentionally limited to the pre-signer boundary: it neither resets,
# re-syncs nor replaces identity, and delegates the retained membership state
# to the existing membership continuation.
set -Eeuo pipefail
# shellcheck source=lib.sh
# shellcheck disable=SC2153 # load_project defines the retained account root.
source "$(dirname "$0")/lib.sh"
load_project
# shellcheck source=lib-join-resume.sh
source "$(dirname "$0")/lib-join-resume.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 NODE RUN_DIR" >&2; exit 2; }
NODE="$(node_name "$1")"
RUN="$2"

lookup_participant() {
  local endpoint="$1" body_file="$2" stderr_file="$3" attempts=6
  participant_attempt=0
  while :; do
    participant_attempt=$((participant_attempt + 1))
    participant_curl_exit=0
    participant_http_status="$(curl -sS --connect-timeout 10 --max-time 30 -o "$body_file" -w '%{http_code}' "$endpoint" 2>"$stderr_file")" || participant_curl_exit=$?
    if (( participant_curl_exit == 0 )) && [[ ! "$participant_http_status" =~ ^5[0-9][0-9]$ ]]; then return 0; fi
    (( participant_attempt < attempts )) || return 0
    printf 'WAIT  participant lookup attempt %s failed (curl_exit=%s http_status=%s); retrying\n' "$participant_attempt" "$participant_curl_exit" "${participant_http_status:-000}"
    sleep 10
  done
}

read_participant_state() {
  local endpoint="https://${GENESIS_PUBLIC_HOST}/v2/participants/$ADDRESS" body stderr status
  body="$(mktemp)"; stderr="$(mktemp)"
  lookup_participant "$endpoint" "$body" "$stderr"
  participant_detail="$(tr '\n' ' ' <"$stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  participant_body="$(<"$body")"
  rm -f "$body" "$stderr"
  if (( participant_curl_exit != 0 )); then
    echo "new canonical resume cannot determine participant state (url=$endpoint http_status=${participant_http_status:-000} curl_exit=$participant_curl_exit${participant_detail:+ detail=$participant_detail})" >&2
    return 1
  fi
  case "$participant_http_status" in
    200)
      status="$(jq -r '.participant.status // empty' <<<"$participant_body" 2>/dev/null || true)"
      [[ -n "$status" ]] || { echo 'new canonical resume received an empty participant status' >&2; return 1; }
      participant_onboarding_state "$status"
      ;;
    404) printf 'new\n' ;;
    *) echo "new canonical resume cannot determine participant state (url=$endpoint http_status=$participant_http_status attempts=$participant_attempt)" >&2; return 1 ;;
  esac
}

verify_published_validator_key() {
  local endpoint="https://${GENESIS_PUBLIC_HOST}/chain-api/productscience/inference/inference/participant/$ADDRESS" body expected
  body="$(mktemp)"
  curl -fsS --connect-timeout 5 --max-time 15 "$endpoint" >"$body" || {
    rm -f "$body"; echo 'new canonical resume cannot read the registered validator key' >&2; return 1;
  }
  expected="$(jq -er .consensus_pubkey "$IDENTITY")"
  "$ROOT/scripts/verify-participant-validator-key.sh" "$ADDRESS" "$expected" "$body" >/dev/null
  rm -f "$body"
}

register_new_participant() {
  local timeout="${GDC_JOIN_REGISTRATION_TIMEOUT_SECONDS:-300}" deadline succeeded=false log observed observed_status
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'GDC_JOIN_REGISTRATION_TIMEOUT_SECONDS must be positive' >&2; return 1; }
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ssh "$NODE" 'cd /srv/dai/deploy && ./register-participant.sh .env >register-participant.log 2>&1'; then
      succeeded=true; break
    fi
    log="$(ssh "$NODE" 'tail -100 /srv/dai/deploy/register-participant.log' 2>/dev/null || true)"
    if grep -Eq '(^|[^0-9])5[0-9]{2}([^0-9]|$)|Service Temporarily Unavailable|context deadline exceeded|Client\.Timeout exceeded|TLS handshake timeout' <<<"$log"; then
      observed="$(curl -fsS --connect-timeout 5 --max-time 15 "https://$GENESIS_PUBLIC_HOST/v2/participants/$ADDRESS" 2>/dev/null || true)"
      observed_status="$(jq -r '.participant.status // empty' <<<"$observed" 2>/dev/null || true)"
      case "$(participant_onboarding_state "$observed_status")" in
        active|registered) succeeded=true; break ;;
      esac
      printf 'WAIT  %s registration endpoint is transiently unavailable\n' "$NODE"
      sleep 5
      continue
    fi
    printf '%s\n' "$log" >&2
    echo 'new canonical resume registration command failed without a retryable server response' >&2
    return 1
  done
  [[ "$succeeded" == true ]] || { echo "new canonical resume registration did not complete within ${timeout}s" >&2; return 1; }
  "$ROOT/03-join/wait-registered.sh" "https://$GENESIS_PUBLIC_HOST" "$ADDRESS" "$timeout"
}

join_resume_prepare_post_sync new

step "Create $NODE validator recovery archive before registration"
"$ROOT/scripts/validator-backup.sh" create "$NODE" pre-registration
join_resume_append_transition RECOVERY_ARCHIVE_READY
case "$(read_participant_state)" in
  new)
    step "Register $NODE before funding"
    register_new_participant
    ;;
  registered|active)
    verify_published_validator_key || {
      echo 'new canonical resume refused: existing participant validator key does not match the retained signer' >&2
      exit 1
    }
    ;;
  *) echo 'new canonical resume received an invalid participant state' >&2; exit 1 ;;
esac
record_join_state "$NODE" MEMBERSHIP_RECONCILED "$ADDRESS"
join_resume_append_transition MEMBERSHIP_RECONCILED
# shellcheck disable=SC2029 # The locally validated staging path is quoted for the remote shell.
# shellcheck disable=SC2154 # join_resume_prepare_post_sync binds the staging directory.
ssh "$NODE" "rm -rf '$remote'" || printf 'WARN staging directory %s was not removed on %s\n' "$remote" "$NODE"
exec "$ROOT/scripts/phase-join-resume-membership.sh" "$NODE" "$RUN"
