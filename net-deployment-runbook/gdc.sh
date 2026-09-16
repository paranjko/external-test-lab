#!/usr/bin/env bash
set -Eeuo pipefail

LAUNCHER_SOURCE="${BASH_SOURCE[0]}"
LAUNCHER_PATH="$(realpath -e -- "$LAUNCHER_SOURCE")"
ROOT="$(cd "$(dirname "$LAUNCHER_PATH")" && pwd)"
if [[ "${LAUNCHER_SOURCE##*/}" == gdc.sh ]]; then
  GDC_USAGE_COMMAND='./gdc.sh'
else
  GDC_USAGE_COMMAND="${LAUNCHER_SOURCE##*/}"
fi

GDC_LAUNCHER_EXIT_RECORDED=false
GDC_END_COMMAND=''
GDC_END_PID="$BASHPID"

record_join_terminal_result() {
  local outcome="$1" phase="$2" category="$3" reason="$4" exit_code="$5" mutation="$6" signer_state="$7" resume="$8" profile_sha='null' input
  [[ -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || return 0
  [[ -x "$ROOT/scripts/record-join-result.sh" ]] || return 70
  # Preflight adapters use broader diagnostic categories. Terminal results
  # deliberately have a smaller closed vocabulary.
  case "$category" in
    network) category=observation ;;
    configuration) category=profile ;;
    dependency) category=artifact ;;
  esac
  if [[ -r "${GDC_JOIN_PROFILE:-}" ]]; then
    profile_sha="\"$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')\""
  fi
  input="$(mktemp "$(dirname "$GDC_JOIN_RESULT_OUTPUT")/.join-result-input.XXXXXX")"
  chmod 600 "$input"
  jq -cn --arg outcome "$outcome" --arg phase "$phase" --arg category "$category" --arg reason "$reason" \
    --argjson exit_code "$exit_code" --arg mutation "$mutation" --arg signer_state "$signer_state" --arg resume "$resume" \
    --argjson profile_sha "$profile_sha" \
    '{schema_version:1,kind:"gdc-host-join-result",outcome:$outcome,phase:$phase,category:$category,reason:$reason,exit_code:$exit_code,mutation:$mutation,signer_state:$signer_state,resume:$resume,join_profile_sha256:$profile_sha,evidence:[]}' >"$input"
  "$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$input" >/dev/null || return $?
  rm -f "$input"
}

record_launcher_failure() {
  local rc="$1" tmp failure_dir run_manifest
  [[ "$rc" -ne 0 && -n "${GDC_LAUNCHER_ENVELOPE_DIR:-}" ]] || return 0
  # A driver reboot is an operator-directed continuation point, not a failed
  # command. Its JOIN terminal receipt is already persisted by run_phase.
  [[ "$rc" -eq 194 && "${GDC_JOIN_REBOOT_REQUIRED:-false}" == true ]] && return 0
  # A report-publication failure retains its own local draft; making it the
  # latest incident would recursively hide the selected operational failure.
  [[ "${GDC_REPORT_MODE:-false}" != true ]] || return 0
  [[ "$GDC_LAUNCHER_EXIT_RECORDED" != true ]] || return 0
  GDC_LAUNCHER_EXIT_RECORDED=true
  failure_dir="${GDC_DATA_ROOT:?}/reporting/failures"
  mkdir -p "$failure_dir"
  chmod 0700 "${GDC_DATA_ROOT:?}/reporting" "$failure_dir" 2>/dev/null || true
  tmp="$failure_dir/.latest-failure.$$.tmp"
  {
    printf 'schema_version=1\n'
    printf 'invocation_id=%s\n' "$GDC_LAUNCHER_INVOCATION_ID"
    printf 'exit_code=%s\n' "$rc"
    printf 'failure_stage=%s\n' "${GDC_ACTIVE_PHASE:-pre-phase}"
    printf 'active_phase=%s\n' "${GDC_ACTIVE_PHASE:-unavailable}"
    printf 'run_id=%s\n' "${GDC_RUN_ID:-unavailable}"
    printf 'run_log=%s\n' "${GDC_RUN_LOG:-unavailable}"
    if [[ -n "${GDC_RUN_ID:-}" ]]; then
      run_manifest="$GDC_HOME/runs/$GDC_RUN_ID/manifest.env"
      # Early JOIN preflight failures intentionally happen before a lifecycle
      # manifest can be created. Preserve an explicit unavailable value for
      # that case, while retaining any existing path for the reporter's
      # fail-closed safety checks.
      if [[ -e "$run_manifest" || -L "$run_manifest" ]]; then
        printf 'run_manifest=%s\n' "$run_manifest"
      else
        printf 'run_manifest=unavailable\n'
      fi
    else
      printf 'run_manifest=unavailable\n'
    fi
    printf 'envelope=%s\n' "$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"
    [[ -z "${GDC_DIAGNOSTIC_ENVELOPE:-}" ]] || printf 'diagnostic_envelope=%s\n' "$GDC_DIAGNOSTIC_ENVELOPE"
    [[ -z "${GDC_JOIN_PREFLIGHT_RECEIPT:-}" ]] || printf 'preflight_receipt=%s\n' "$GDC_JOIN_PREFLIGHT_RECEIPT"
    printf 'recorded_at=%s\n' "$(date -u +%FT%TZ)"
  } >"$GDC_LAUNCHER_ENVELOPE_DIR/failure.env"
  chmod 0600 "$GDC_LAUNCHER_ENVELOPE_DIR/failure.env"
  printf '%s\n' "$GDC_LAUNCHER_INVOCATION_ID" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$failure_dir/latest-failure"
  printf 'Hint: review the retained local failure and run gdc report github when you are ready to disclose a sanitized report.\n' >&2
}

on_launcher_exit() {
  local rc="$?"
  trap - EXIT
  set +e
  trap - ERR
  # A JOIN run without a terminal result blocks every later run: write one on abort.
  if (( rc != 0 )) && [[ -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] \
    && [[ ! -e "$GDC_JOIN_RESULT_OUTPUT" ]] && [[ -d "$(dirname "$GDC_JOIN_RESULT_OUTPUT")" ]] \
    && [[ "$GDC_JOIN_RESULT_OUTPUT" == "${GDC_HOME:-/nonexistent}/runs/"* ]]; then
    record_join_terminal_result failed signer internal join_launcher_aborted "$rc" \
      signer_may_be_on unknown manual_recovery \
      || printf 'ERROR JOIN aborted and its terminal result receipt could not be persisted at %s\n' \
        "$GDC_JOIN_RESULT_OUTPUT" >&2
  fi
  record_launcher_failure "$rc"
  # A phase pipeline runs in a subshell; only the outer command owns END.
  if [[ -n "$GDC_END_COMMAND" && "$BASHPID" == "$GDC_END_PID" ]]; then
    if [[ "$GDC_END_COMMAND" == 'host join' && "${plan_only:-false}" == true ]]; then
      GDC_END_COMMAND+=' PLAN'
    fi
    if (( rc == 0 )); then
      printf 'END %s SUCCESS\n' "$GDC_END_COMMAND"
    elif [[ "$GDC_END_COMMAND" == 'host join' && "$rc" -eq 194 && "${GDC_JOIN_REBOOT_REQUIRED:-false}" == true ]]; then
      printf 'END host join REBOOT_REQUIRED exit=194\n' >&2
    else
      printf 'END %s FAILED exit=%s\n' "$GDC_END_COMMAND" "$rc" >&2
    fi
  fi
  exit "$rc"
}

on_launcher_error() {
  local rc="$?"
  trap - ERR
  # Do not turn the explicit reboot continuation into an ERROR. The EXIT
  # handler emits its single terminal REBOOT_REQUIRED result instead.
  if [[ "$rc" -eq 194 && "${GDC_JOIN_REBOOT_REQUIRED:-false}" == true ]]; then
    exit "$rc"
  fi
  printf 'ERROR gdc command failed phase=%s exit=%s run_log=%s command=%s\n' \
    "${GDC_ACTIVE_PHASE:-unavailable}" "$rc" "${GDC_RUN_LOG:-unavailable}" \
    "${GDC_INVOCATION_COMMAND:-$ROOT/gdc.sh}" >&2
  exit "$rc"
}
trap 'on_launcher_error "$LINENO"' ERR

source "$ROOT/scripts/lib.sh"
init_gdc_data_root
# This capability is set only after an exact retained JOIN lineage resolves.
# An inherited environment value must not make a retired profile fresh-selectable.
unset GDC_ALLOW_RETIRED_PROFILE_RECOVERY

initialize_launcher_envelope() {
  local base
  base="$GDC_DATA_ROOT/reporting/invocations"
  mkdir -p "$base"
  chmod 0700 "$GDC_DATA_ROOT/reporting" "$base" 2>/dev/null || true
  GDC_LAUNCHER_ENVELOPE_DIR="$(mktemp -d "$base/invocation.XXXXXX")"
  GDC_LAUNCHER_INVOCATION_ID="${GDC_LAUNCHER_ENVELOPE_DIR##*/invocation.}"
  chmod 0700 "$GDC_LAUNCHER_ENVELOPE_DIR"
  {
    printf 'schema_version=1\n'
    printf 'invocation_id=%s\n' "$GDC_LAUNCHER_INVOCATION_ID"
    printf 'created_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'runbook_revision=%s\n' "$(runbook_revision)"
    printf 'gdc_launcher_sha256=%s\n' "$(gdc_launcher_sha256)"
  } >"$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"
  chmod 0600 "$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"
  export GDC_LAUNCHER_ENVELOPE_DIR GDC_LAUNCHER_INVOCATION_ID
}

initialize_launcher_envelope
trap on_launcher_exit EXIT

acquire_operator_lock() {
  [[ "${GDC_OPERATOR_LOCK_STATE:-}" == "$STATE" ]] && return 0
  local lock_file="$STATE/.lifecycle.lock"
  mkdir -p "$STATE"
  exec 9>"$lock_file"
  if ! flock -n 9; then
    echo 'another lifecycle phase is already running for this operator; wait for it to finish before starting another phase' >&2
    exit 1
  fi
  export GDC_OPERATOR_LOCK_STATE="$STATE"
}

format_safe_invocation() {
  local arg redact_next=false rendered=''
  for arg in "$@"; do
    if [[ "$redact_next" == true ]]; then
      rendered+=" $(printf '%q' '<redacted>')"
      redact_next=false
      continue
    fi
    case "$arg" in
      --*key|--*key-file|--*token|--*password|--*secret|--*mnemonic|--*credential)
        rendered+=" $(printf '%q' "$arg")"
        redact_next=true
        ;;
      --*key=*|--*key-file=*|--*token=*|--*password=*|--*secret=*|--*mnemonic=*|--*credential=*)
        rendered+=" $(printf '%q' "${arg%%=*}=<redacted>")"
        ;;
      *)
        rendered+=" $(printf '%q' "$arg")"
        ;;
    esac
  done
  printf '%q%s\n' 'gdc' "$rendered"
}

run_phase() {
  local phase="$1"
  shift
  local state run_id_file run_id run_dir log rc diagnostic_envelope
  state="$STATE"
  acquire_operator_lock
  if [[ "${GDC_RUN_CONTEXT:-}" == network-recovery ]]; then
    run_id_file="$state/active-recovery-run-id"
  else
    run_id_file="$state/active-run-id"
  fi
  mkdir -p "$state"
  # An assurance adapter owns one evidence namespace per scenario execution.
  # Do not silently append it to the last operator's lifecycle run.
  if [[ -n "${GDC_ASSURANCE_RUN_ID:-}" ]]; then
    run_id="assurance-${GDC_ASSURANCE_RUN_ID}"
    printf '%s\n' "$run_id" >"$run_id_file"
  # Host JOIN has already created its private profile, preflight receipt and
  # terminal-result location under this ID before it reaches run_phase. A
  # restore must keep that evidence namespace: GDC_JOIN_RECOVERY_NEW_RUN
  # means "do not reuse a historical recovery", not "split this invocation
  # into independent preflight and mutation runs".
  elif [[ -n "${GDC_RUN_ID:-}" ]]; then
    run_id="$GDC_RUN_ID"
    printf '%s\n' "$run_id" >"$run_id_file"
  elif [[ "${GDC_FORCE_NEW_RUN:-false}" == true || "${GDC_JOIN_RECOVERY_NEW_RUN:-false}" == true ]]; then
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    printf '%s\n' "$run_id" >"$run_id_file"
  elif [[ -s "$run_id_file" ]]; then
    run_id="$(<"$run_id_file")"
  else
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    printf '%s\n' "$run_id" >"$run_id_file"
  fi
  run_dir="$GDC_HOME/runs/$run_id"
  log="$run_dir/run.log"
  mkdir -p "$run_dir"
  export GDC_RUN_ID="$run_id" GDC_RUN_LOG="$log" GDC_ACTIVE_PHASE="$phase"
  # This immutable envelope exists before the invoked phase can mutate a
  # Host. `record_phase_profile` enriches it once role input is loaded.
  ensure_run_manifest "$phase"

  # Keep the phase pipeline in a conditional. A JOIN phase can return a
  # typed non-zero result such as 194 (Host preparation completed but needs a
  # reboot). The global ERR trap must not preempt the code below, which writes
  # its terminal receipt before returning that result to the caller.
  if {
    [[ -z "${GDC_INVOCATION_COMMAND:-}" ]] || printf 'INVOCATION command=%s\n' "$GDC_INVOCATION_COMMAND"
    printf 'LAUNCHER runbook_revision=%s gdc_launcher_sha256=%s\n' "$(runbook_revision)" "$(gdc_launcher_sha256)"
    printf 'BEGIN phase=%s timestamp=%s run_id=%s\n' "$phase" "$(date -u +%FT%TZ)" "$run_id"
    "$@"
    rc=$?
    exit "$rc"
  } 2>&1 | tee -a "$log"; then
    rc=0
  else
    rc=${PIPESTATUS[0]}
  fi
  if (( rc != 0 )); then
    diagnostic_envelope="$(find "$run_dir" -maxdepth 2 -type f -name diagnostic-envelope.v1.json -print 2>/dev/null | LC_ALL=C sort | tail -n1 || true)"
    if [[ -z "$diagnostic_envelope" ]]; then
      "$ROOT/scripts/phase-diagnostic-adapter.sh" "$run_dir/diagnostic-envelope.v1.json" "$phase" "$rc"
      diagnostic_envelope="$run_dir/diagnostic-envelope.v1.json"
    fi
    [[ -z "$diagnostic_envelope" ]] || export GDC_DIAGNOSTIC_ENVELOPE="$diagnostic_envelope"
  fi
  if [[ "$phase" == join-* && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]]; then
    # Existing-Host operator-state recovery deliberately runs in a fresh
    # evidence directory but does not create a new deployment authority.  The
    # prior completed run remains the only signer restart authority.
    if [[ "${GDC_JOIN_PRESERVE_PRIOR_RUN:-false}" == true || -n "$(find "$run_dir" -maxdepth 2 -type f -name preserve-prior-run -print -quit 2>/dev/null)" ]]; then
      printf 'READY JOIN recovery preserved the prior completed run authority\n'
    elif (( rc == 0 )); then
      # A successful phase has completed the guarded signer readback, so it
      # may replace the pre-start conservative terminal result.
      if ! record_join_terminal_result succeeded acceptance internal join_complete 0 signer_may_be_on enabled not_applicable; then
        printf 'ERROR JOIN completed without a terminal result receipt\n' >&2
        rc=70
      fi
    elif [[ -f "$GDC_JOIN_RESULT_OUTPUT" ]]; then
      # A phase may have recorded a more precise bounded terminal outcome
      # (for example a signerless restore refusal or activation guard).  Do
      # not overwrite it with the launcher-wide conservative fallback.
      :
    elif find "$run_dir" -maxdepth 2 -type f -name prepare-failed-before-identity -print -quit | grep -q .; then
      # phase-join records this marker only around phase-prepare, after the
      # target has been classified but before it can create identity,
      # deployment, or signer state. Re-running preparation is safe; the
      # next JOIN still performs fresh network observation and remote identity
      # preflight.
      if (( rc == 194 )); then
        prepare_reason=host_prepare_reboot_required
      else
        prepare_reason=host_prepare_failed_before_identity
      fi
      if ! record_join_terminal_result failed staging host "$prepare_reason" "$rc" staging_only disabled new_profile; then
        printf 'ERROR JOIN pre-identity preparation result could not be persisted\n' >&2
        rc=70
      elif (( rc == 194 )); then
        GDC_JOIN_REBOOT_REQUIRED=true
        export GDC_JOIN_REBOOT_REQUIRED
      fi
    elif (( rc == 194 )) && find "$run_dir" -maxdepth 2 -type f -name prepare-reboot-required -print -quit | grep -q .; then
      # Host preparation intentionally uses 194 after installing an NVIDIA
      # driver that cannot become active until reboot. It precedes identity
      # creation and deployment, so a fresh JOIN after reboot is safe and
      # deliberately observes the live runtime again.
      if ! record_join_terminal_result failed staging host host_prepare_reboot_required "$rc" staging_only disabled new_profile; then
        printf 'ERROR JOIN reboot-required result could not be persisted\n' >&2
        rc=70
      else
        GDC_JOIN_REBOOT_REQUIRED=true
        export GDC_JOIN_REBOOT_REQUIRED
      fi
    else
      # A phase may fail after an interrupted signer start. Be conservative:
      # a retained operator must read it back, never infer a retry point.
      if ! record_join_terminal_result failed signer internal join_phase_failed "$rc" signer_may_be_on unknown automatic_retry_forbidden; then
        printf 'ERROR JOIN failed and its terminal result receipt could not be persisted\n' >&2
        rc=70
      fi
    fi
  fi
  printf 'END phase=%s status=%s timestamp=%s\n' "$phase" "$rc" "$(date -u +%FT%TZ)" | tee -a "$log"
  return "$rc"
}

run_join_preflight() {
  local checkpoint="$1" state="$2" category="$3" tool="$4" summary="$5" rc diagnostic typed
  shift 5
  if "$@"; then
    return 0
  else
    rc=$?
  fi
  if [[ "$category" == lineage && -r "${GDC_JOIN_LINEAGE_FAILURE_FILE:-}" ]]; then
    typed="$(<"$GDC_JOIN_LINEAGE_FAILURE_FILE")"
    if [[ "$typed" =~ ^(rpc_quorum_conflict|rpc_fault_domain_alias|snapshot_unavailable|snapshot_incompatible|trust_expired|apphash_divergence|lineage_verification_failed|signer_activation_unsafe)$ ]]; then
      tool="${typed//_/-}"
    fi
  fi
  if [[ "$checkpoint" == software-observation && "${GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT:-false}" == true ]]; then
    tool=seed-observer-timeout
  fi
  # JOIN has not selected a local profile or touched a Host at this point.
  # Retain a bounded, structured diagnostic in the launcher envelope rather
  # than manufacturing a lifecycle manifest for an unselected release.
  GDC_ACTIVE_PHASE='join-preflight'
  diagnostic="$GDC_LAUNCHER_ENVELOPE_DIR/diagnostic-envelope.v1.json"
  "$ROOT/scripts/diagnostic-envelope.sh" write "$diagnostic" \
    join join-preflight "$checkpoint" "$state" "$category" "$tool" "$rc" \
    safe join-repeat "$summary"
  export GDC_DIAGNOSTIC_ENVELOPE="$diagnostic"
  write_join_preflight_receipt "$checkpoint" failed "$category" "$tool"
  if ! record_join_terminal_result refused profile "$category" join_preflight_failed "$rc" none absent new_profile; then
    printf 'ERROR JOIN preflight failed and its terminal result receipt could not be persisted\n' >&2
    return 70
  fi
  printf 'ERROR JOIN preflight failed checkpoint=%s preflight_receipt=%s result=%s\n' \
    "$checkpoint" "$GDC_JOIN_PREFLIGHT_RECEIPT" "${GDC_JOIN_RESULT_OUTPUT:-unavailable}" >&2
  return "$rc"
}

initialize_join_preflight_receipt() {
  GDC_JOIN_PREFLIGHT_RECEIPT="$STATE/preflight-receipt.env"
  export GDC_JOIN_PREFLIGHT_RECEIPT
  write_join_preflight_receipt initialized pending unavailable unavailable
}

write_join_preflight_receipt() {
  local checkpoint="$1" result="$2" category="$3" tool="$4" tmp
  [[ -n "${GDC_JOIN_PREFLIGHT_RECEIPT:-}" ]] || return 0
  tmp="${GDC_JOIN_PREFLIGHT_RECEIPT}.tmp.$$"
  {
    printf 'schema_version=1\n'
    printf 'invocation_id=%s\n' "$GDC_LAUNCHER_INVOCATION_ID"
    printf 'checkpoint=%s\nresult=%s\ncategory=%s\ntool=%s\n' \
      "$checkpoint" "$result" "$category" "$tool"
    printf 'recorded_at=%s\n' "$(date -u +%FT%TZ)"
    [[ -z "${GDC_NETWORK_FINGERPRINT:-}" ]] || printf 'network_fingerprint=%s\n' "$GDC_NETWORK_FINGERPRINT"
    [[ -z "${GDC_NETWORK_CHAIN_ID:-}" ]] || printf 'chain_id=%s\n' "$GDC_NETWORK_CHAIN_ID"
    [[ -z "${GDC_NETWORK_GENESIS_SHA256:-}" ]] || printf 'genesis_sha256=%s\n' "$GDC_NETWORK_GENESIS_SHA256"
    [[ -z "${GDC_NETWORK_CORE_VERSION:-}" ]] || printf 'core_version=%s\ncore_commit=%s\n' "$GDC_NETWORK_CORE_VERSION" "$GDC_NETWORK_CORE_COMMIT"
    [[ -z "${GDC_NETWORK_DAPI_VERSION:-}" ]] || printf 'dapi_version=%s\ndapi_commit=%s\n' "$GDC_NETWORK_DAPI_VERSION" "$GDC_NETWORK_DAPI_COMMIT"
    [[ -z "${GDC_NETWORK_DEVSHARD_APPROVALS:-}" ]] || printf 'devshard_approvals=%q\n' "$GDC_NETWORK_DEVSHARD_APPROVALS"
    [[ -z "${GDC_RELEASE_PROFILE:-}" ]] || printf 'release_profile=%s\n' "$GDC_RELEASE_PROFILE"
    [[ -z "${GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPTS_DIR:-}" ]] || printf 'software_observation_attempts_dir=%s\n' "$GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPTS_DIR"
    [[ -z "${GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPT_COUNT:-}" ]] || printf 'software_observation_attempt_count=%s\n' "$GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPT_COUNT"
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$GDC_JOIN_PREFLIGHT_RECEIPT"
}

parse_join_preflight_wait_seconds() {
  local value="$1" amount unit multiplier=1
  if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    amount="$value"
  elif [[ "$value" =~ ^([1-9][0-9]*)([smh])$ ]]; then
    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s) multiplier=1 ;;
      m) multiplier=60 ;;
      h) multiplier=3600 ;;
    esac
  else
    return 1
  fi
  (( amount <= 86400 / multiplier )) || return 1
  printf '%s\n' "$((amount * multiplier))"
}

join_observation_identity() {
  jq -cS '{bootstrap:{chain_id:.bootstrap.chain_id,genesis_sha256:.bootstrap.genesis_sha256,document_sha256:.bootstrap.document_sha256},runtime:{core:.runtime.core,dapi:.runtime.dapi}}' "$1"
}

wait_for_join_software_observation() {
  local stage="$1" output="$2" deadline="$3" retry_seconds="$4" attempt=0 consecutive=0 previous_identity='' identity=''
  local attempt_dir attempt_observation attempt_stdout attempt_stderr rc remaining
  unset GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT
  attempt_dir="$STATE/network-observation-attempts/$GDC_RUN_ID/$stage"
  install -d -m 0700 "$attempt_dir"
  GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPTS_DIR="$attempt_dir"
  export GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPTS_DIR

  while :; do
    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )); then
      GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT=true
      export GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT
      printf 'network_observation_timeout: no stable quorum-backed runtime observation before the preflight deadline; attempts=%s receipt=%s\n' \
        "$attempt" "$attempt_dir" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    attempt_observation="$attempt_dir/attempt-$attempt.json"
    attempt_stdout="$attempt_dir/attempt-$attempt.stdout"
    attempt_stderr="$attempt_dir/attempt-$attempt.stderr"
    if "$ROOT/scripts/observe-network-state.sh" --bootstrap-file "$join_bootstrap_file" --bootstrap-url "$join_bootstrap_url" \
      --chain-id "$join_chain_id" --run-id "$GDC_RUN_ID-$attempt" --output "$attempt_observation" \
      "${join_source_args[@]}" >"$attempt_stdout" 2>"$attempt_stderr"; then
      cat "$attempt_stdout"
      identity="$(join_observation_identity "$attempt_observation")"
      if [[ "$identity" == "$previous_identity" ]]; then
        consecutive=$((consecutive + 1))
      else
        previous_identity="$identity"
        consecutive=1
      fi
      GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPT_COUNT="$attempt"
      export GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPT_COUNT
      printf 'WAIT JOIN software observation stage=%s attempt=%s stable=%s/2 remaining_seconds=%s\n' \
        "$stage" "$attempt" "$consecutive" "$remaining"
      if (( consecutive >= 2 )); then
        cp "$attempt_observation" "$output" || {
          printf 'network_observation_receipt_write_failed: %s\n' "$output" >&2
          return 1
        }
        chmod 0600 "$output" || {
          printf 'network_observation_receipt_permission_failed: %s\n' "$output" >&2
          return 1
        }
        printf 'PASS JOIN software observation stable stage=%s attempts=%s receipt=%s\n' "$stage" "$attempt" "$attempt_dir"
        return 0
      fi
    else
      rc=$?
      cat "$attempt_stdout"
      cat "$attempt_stderr" >&2
      previous_identity=''
      consecutive=0
      GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPT_COUNT="$attempt"
      export GDC_JOIN_SOFTWARE_OBSERVATION_ATTEMPT_COUNT
      printf 'WAIT JOIN software observation stage=%s attempt=%s unavailable exit=%s remaining_seconds=%s\n' \
        "$stage" "$attempt" "$rc" "$remaining" >&2
    fi

    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )); then
      GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT=true
      export GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT
      printf 'network_observation_timeout: no stable quorum-backed runtime observation before the preflight deadline; attempts=%s receipt=%s\n' \
        "$attempt" "$attempt_dir" >&2
      return 1
    fi
    (( retry_seconds < remaining )) && remaining="$retry_seconds"
    sleep "$remaining"
  done
}

use_node_data_home() {
  select_node_data_home "$1"
}

use_network_owner_data_home() {
  select_network_owner_data_home || return 0
}

use_operator_inventory() {
  [[ -s "$GDC_DATA_ROOT/.env" ]] || return 0
  export GDC_ENV="$GDC_DATA_ROOT/.env"
}

usage() {
  sed "s#\\./gdc\\.sh#$GDC_USAGE_COMMAND#g" <<'EOF'
Gonka DevNet Community manual deployment

See the role guides for required input, then run:
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] [--public-edge <SSH_ALIAS>] [--skip-qualification]
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] [--public-edge <SSH_ALIAS>] --no-bootstrap-access
  ./gdc.sh --release v2026.07.23 baseline
  ./gdc.sh report github
  ./gdc.sh --release v2026.07.23 bootstrap-access
  ./gdc.sh --release v2026.07.23 gateway-continuity
  ./gdc.sh host join [--plan] [--chain-id <CHAIN_ID>] [--preflight-deadline <duration>] [--mnemonic-prompt | --mnemonic-file <PATH>] --public-host <IP_OR_DOMAIN> <SSH_ALIAS>
  ./gdc.sh host join --resume <RUN_ID> --public-host <IP_OR_DOMAIN> <SSH_ALIAS>
  ./gdc.sh host backup <SSH_ALIAS>
  ./gdc.sh --release v2026.07.23 ml attach <SSH_ALIAS>
  ./gdc.sh ops faucet
  ./gdc.sh ops monitoring
  ./gdc.sh ops site
  ./gdc.sh ops explorer
  ./gdc.sh ops consumer telegram apply
  ./gdc.sh ops consumer telegram status
  ./gdc.sh ops consumer telegram verify [MODEL] [SLA]
  ./gdc.sh gateway access-key ensure telegram
  ./gdc.sh gateway access-key revoke telegram
  ./gdc.sh gateway access-key list
  ./gdc.sh --release v2026.07.23 gateway apply v3
  ./gdc.sh --composition <COMPOSITION> gateway migration prepare v5
  ./gdc.sh --composition <COMPOSITION> gateway migration status
  ./gdc.sh --composition <COMPOSITION> gateway migration cutover
  ./gdc.sh --composition <COMPOSITION> gateway migration drain [SECONDS]
  ./gdc.sh --composition <COMPOSITION> gateway migration rollback|complete
  ./gdc.sh --composition <COMPOSITION> gateway canary prepare v4|v5
  ./gdc.sh --composition <COMPOSITION> gateway canary status|stop
  ./gdc.sh --release v2026.07.23 gateway reconcile v3
  ./gdc.sh gateway status
  ./gdc.sh gateway verify [SLA]
  ./gdc.sh --release v2026.07.23 gateway continuity
  ./gdc.sh --release v2026.07.23 gateway settle
  ./gdc.sh --release v2026.08.06 gateway ha v4
  ./gdc.sh network bootstrap verify FILE
  ./gdc.sh --release v2026.07.23 network genesis <SSH_ALIAS>
  ./gdc.sh --release v2026.07.23 network verify
  ./gdc.sh --release v2026.07.23 network gate-b verify
  ./gdc.sh --release v2026.07.23 network confirmation-poc verify
  ./gdc.sh --release v2026.08.06 network upgrade verify <proposal-id>
  ./gdc.sh network recover bootstrap <SSH_ALIAS>  # GNK-LAB-2026-0001; interactive confirmation
  ./gdc.sh network recover handoff|check <SSH_ALIAS> --hosts <RETURNING_ALIAS,...>
  ./gdc.sh host join --pex false --restore <ARCHIVE> --public-host <HOST> <SSH_ALIAS>
  ./gdc.sh host peers --pex true <SSH_ALIAS>
  ./gdc.sh network recover inspect --incident <INCIDENT_ID> --host <SSH_ALIAS> --run-id <RUN_ID> --output <ABSOLUTE_PATH>
  ./gdc.sh network recover prepare|freeze|stage|activate|retire|abort --host <SSH_ALIAS> --run-id <RUN_ID> --manifest <ABSOLUTE_PATH> --approval <ABSOLUTE_PATH>
  ./gdc.sh network recover status --host <SSH_ALIAS> --run-id <RUN_ID> --manifest <ABSOLUTE_PATH>
  ./gdc.sh network recover checkpoint --host <SSH_ALIAS> --run-id <RUN_ID> --manifest <ABSOLUTE_PATH> --output <ABSOLUTE_PATH>
  ./gdc.sh network recover rejoin --host <SSH_ALIAS> --run-id <RUN_ID> --manifest <ABSOLUTE_PATH> --checkpoint <ABSOLUTE_PATH> --approval <ABSOLUTE_PATH>
  ./gdc.sh network recover resume --step signers|poc|handoff --host <SSH_ALIAS> --run-id <RUN_ID> --manifest <ABSOLUTE_PATH> --approval <ABSOLUTE_PATH>
  ./gdc.sh network recover verify --host <SSH_ALIAS> --run-id <RUN_ID> --manifest <ABSOLUTE_PATH> --scope consensus|epochs
  ./gdc.sh network recover verify --host <SSH_ALIAS> --run-id <RUN_ID> --manifest <ABSOLUTE_PATH> --scope service --approval <ABSOLUTE_PATH>
  ./gdc.sh network reset --yes [--hosts <SSH_ALIAS[,SSH_ALIAS...]>]
  ./gdc.sh --release v2026.08.06 host upgrade prepare <ssh-alias> <proposal-id>
  ./gdc.sh --release v2026.08.06 host upgrade watch <ssh-alias> <proposal-id>
  ./gdc.sh --release v2026.07.23 host ml-attach <SSH_ALIAS>
  ./gdc.sh host stop|start|verify <SSH_ALIAS>
  ./gdc.sh host reset <SSH_ALIAS> [<SSH_ALIAS> ...]
  ./gdc.sh --composition <COMPOSITION> governance devshard submit [--protocols v3,v4,v5]
  ./gdc.sh --composition <COMPOSITION> governance devshard verify <proposal-id> [--protocols v3,v4,v5]
  ./gdc.sh --release v2026.08.06 governance vote <proposal-id> [yes|no|abstain|no_with_veto]
  ./gdc.sh --release v2026.08.06 bridge contract deploy sepolia
  ./gdc.sh --release v2026.08.06 bridge contract register sepolia
  ./gdc.sh --release v2026.08.06 bridge observer apply|status|verify <SSH_ALIAS>
  ./gdc.sh release candidate prepare --source-ref ak/height-sync-protocol-dapi --layer core [--profile vYYYY.MM.DD-rc.N]
  ./gdc.sh release candidate build <vYYYY.MM.DD-rc.N> [--dry-run] [--retry] [--wait]
  ./gdc.sh release candidate profile <vYYYY.MM.DD-rc.N> [--build-manifest <PATH>]
  ./gdc.sh release candidate verify <vYYYY.MM.DD-rc.N> [--build-manifest <PATH>]
  ./gdc.sh release composition create --core <CORE_PROFILE> --devshard <DEVSHARD_PROFILE> [--output <PATH>] [--materialize <PATH>]
  ./gdc.sh release composition verify <PATH|NAME>
  ./gdc.sh release composition materialize <PATH|NAME> [--output <PATH>]
  ./gdc.sh node stop <SSH_ALIAS>
  ./gdc.sh node start <SSH_ALIAS>
  ./gdc.sh node verify <SSH_ALIAS>
  ./gdc.sh node reset <SSH_ALIAS>
  ./gdc.sh ops edge
  ./gdc.sh --release v2026.07.23 verify
  ./gdc.sh --release v2026.08.06 upgrade-proposal
  ./gdc.sh --release v2026.08.06 upgrade-worker <proposal-id>
  ./gdc.sh --release v2026.08.06 advance-after-upgrade <proposal-id>
  ./gdc.sh --release v2026.08.06 advance-after-upgrade-worker <proposal-id>
  ./gdc.sh --release v2026.08.06 upgrade
  ./gdc.sh --composition <COMPOSITION> governance devshard [--protocols v3,v4,v5]
  ./gdc.sh --release v2026.08.06 vote <proposal-id> [yes|no|abstain|no_with_veto]
  GDC_GATEWAY_VERSION=v3 GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false ./gdc.sh --release v2026.08.06 ops gateway
  ./gdc.sh --release v2026.08.06 settle
  GDC_GATEWAY_VERSION=v4 GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false ./gdc.sh --release v2026.08.06 ops gateway
  ./gdc.sh --release v2026.08.06 settle
  ./gdc.sh --release v2026.08.06 ha v4
  ./gdc.sh --release v2026.08.06 bridge-deploy sepolia
  ./gdc.sh --release v2026.08.06 bridge-register sepolia
  ./gdc.sh --release v2026.08.06 bridge sepolia
  ./gdc.sh audit

Start a clean rehearsal with:
  ./gdc.sh reset --yes

Runtime data defaults to \$HOME/.gdc-data. Override it per operator with:
  GDC_HOME=/absolute/path ./gdc.sh <command>
EOF
}

GDC_INVOCATION_COMMAND="$(format_safe_invocation "$@")"
GDC_INVOCATION_CWD="$PWD"
export GDC_INVOCATION_COMMAND GDC_INVOCATION_CWD
{
  printf 'safe_invocation=%q\n' "$GDC_INVOCATION_COMMAND"
  printf 'invocation_cwd=%q\n' "$GDC_INVOCATION_CWD"
} >>"$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"

RELEASE=''
MODEL=''
COMPOSITION=''
RELEASE_OPTION_SEEN=false
MODEL_OPTION_SEEN=false
COMPOSITION_OPTION_SEEN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE_OPTION_SEEN=true; RELEASE="${2:-}"; shift 2 ;;
    --release=*) RELEASE_OPTION_SEEN=true; RELEASE="${1#--release=}"; shift ;;
    --composition) COMPOSITION_OPTION_SEEN=true; COMPOSITION="${2:-}"; shift 2 ;;
    --model) MODEL_OPTION_SEEN=true; MODEL="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
if [[ -n "$COMPOSITION" ]]; then
  export GDC_COMPOSITION="$COMPOSITION"
  if [[ -r "$COMPOSITION" ]]; then
    :
  elif [[ "$COMPOSITION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && -r "$ROOT/profiles/compositions/$COMPOSITION.json" ]]; then
    :
  else
    echo "Unknown composition: $COMPOSITION" >&2
    exit 2
  fi
  composition_env="$("$ROOT/scripts/release-candidate.py" composition export-env "$COMPOSITION")" || exit $?
  eval "$composition_env"
  export GDC_COMPOSITION="$COMPOSITION"
fi
if [[ -n "$RELEASE" ]]; then
  [[ "$RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { echo "Invalid release profile: $RELEASE" >&2; exit 2; }
  [[ -r "$ROOT/profiles/releases/$RELEASE.lock" || -r "$ROOT/profiles/compositions/$RELEASE.json" || -r "$RELEASE" ]] || { echo "Unknown release: $RELEASE" >&2; exit 2; }
  [[ -z "$COMPOSITION" || "$RELEASE" == "$GDC_RELEASE_PROFILE" ]] \
    || { echo "Release profile $RELEASE conflicts with composition core profile $GDC_RELEASE_PROFILE" >&2; exit 2; }
  export GDC_RELEASE_PROFILE="$RELEASE"
fi
[[ -z "$MODEL" || "$MODEL" == qwen3-0.6b ]] || { echo "Unknown model overlay: $MODEL" >&2; exit 2; }
[[ -z "$MODEL" ]] || export GDC_MODEL_PROFILE="$MODEL"

is_upgrade_target_profile() {
  local profile="${GDC_RELEASE_PROFILE:-}" lock
  if [[ -n "${GDC_COMPOSITION:-}" ]]; then
    return 0
  fi
  [[ -n "$profile" ]] || return 1
  [[ "$profile" == v2026.08.06 ]] && return 0
  if [[ -f "$ROOT/profiles/compositions/$profile.json" || -f "$profile" ]]; then
    return 0
  fi
  lock="$ROOT/profiles/releases/$profile.lock"
  [[ -r "$lock" ]] && grep -Eq '^UPGRADE_FROM_PROFILE=[a-z0-9][a-z0-9.-]*$' "$lock"
}

configure_devshard_governance_protocols() {
  local raw="$1" protocol normalized=''
  local -a protocols=()
  [[ -n "$raw" ]] || { echo 'DevShard protocol list must not be empty' >&2; exit 2; }
  IFS=',' read -r -a protocols <<<"$raw"
  ((${#protocols[@]} > 0)) || { echo 'DevShard protocol list must not be empty' >&2; exit 2; }
  for protocol in "${protocols[@]}"; do
    [[ "$protocol" =~ ^v[1-9][0-9]*$ ]] || { echo "Invalid DevShard protocol: $protocol" >&2; exit 2; }
    case " $normalized " in
      *" $protocol "*) echo "Duplicate DevShard protocol: $protocol" >&2; exit 2 ;;
    esac
    normalized="${normalized:+$normalized }$protocol"
  done
  export GDC_GOVERNANCE_DEVSHARD_PROTOCOLS="$normalized"
}

network_recover_cli_error() {
  printf 'network recover: %s\n' "$*" >&2
  return 2
}

network_recover_input_path_valid() {
  local path="$1" canonical mode
  [[ "$path" == /* && "$path" != / && -f "$path" && ! -L "$path" ]] || return 1
  canonical="$(realpath -e -- "$path" 2>/dev/null)" || return 1
  [[ "$canonical" == "$path" ]] || return 1
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)" || return 1
  [[ "$mode" == 400 || "$mode" == 600 ]]
}

network_recover_output_path_valid() {
  local path="$1" parent base canonical_parent
  [[ "$path" == /* && "$path" != / && "$path" != */../* && "$path" != */./* ]] || return 1
  parent="$(dirname "$path")"; base="$(basename "$path")"
  [[ -d "$parent" && ! -L "$parent" && "$base" != . && "$base" != .. ]] || return 1
  canonical_parent="$(realpath -e -- "$parent" 2>/dev/null)" || return 1
  [[ "$canonical_parent/$base" == "$path" && ! -e "$path" && ! -L "$path" ]] || return 1
  case "$path" in /tmp/*|/private/tmp/*|/var/tmp/*) return 1 ;; esac
}

parse_network_recover_args() {
  local phase="${1:-}" allowed required seen_options='' key value required_key required_value path_value
  shift || true

  RECOVERY_PHASE="$phase"
  RECOVERY_INCIDENT=''
  RECOVERY_HOST=''
  RECOVERY_RUN_ID=''
  RECOVERY_MANIFEST=''
  RECOVERY_APPROVAL=''
  RECOVERY_CHECKPOINT=''
  RECOVERY_OUTPUT=''
  RECOVERY_SCOPE=''
  RECOVERY_STEP=''

  case "$phase" in
    inspect)
      allowed='incident host run-id output'
      required="$allowed"
      ;;
    prepare|freeze|stage|activate|retire|abort)
      allowed='host run-id manifest approval'
      required="$allowed"
      ;;
    status)
      allowed='host run-id manifest'
      required="$allowed"
      ;;
    checkpoint)
      allowed='host run-id manifest output'
      required="$allowed"
      ;;
    rejoin)
      allowed='host run-id manifest checkpoint approval'
      required="$allowed"
      ;;
    resume)
      allowed='step host run-id manifest approval'
      required="$allowed"
      ;;
    verify)
      allowed='host run-id manifest scope approval'
      required='host run-id manifest scope'
      ;;
    '') network_recover_cli_error 'a phase is required' || return 2 ;;
    *) network_recover_cli_error "unknown phase: $phase" || return 2 ;;
  esac

  while (( $# > 0 )); do
    [[ "$1" == --* ]] || network_recover_cli_error "unexpected positional argument: $1" || return 2
    key="${1#--}"
    [[ " $allowed " == *" $key "* ]] \
      || network_recover_cli_error "option --$key is not allowed for phase $phase" || return 2
    [[ " $seen_options " != *" $key "* ]] \
      || network_recover_cli_error "option --$key was provided more than once" || return 2
    (( $# >= 2 )) && [[ "$2" != --* ]] \
      || network_recover_cli_error "option --$key requires a value" || return 2
    value="$2"
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
      || network_recover_cli_error "option --$key has an invalid value" || return 2
    seen_options="${seen_options:+$seen_options }$key"
    case "$key" in
      incident) RECOVERY_INCIDENT="$value" ;;
      host) RECOVERY_HOST="$value" ;;
      run-id) RECOVERY_RUN_ID="$value" ;;
      manifest) RECOVERY_MANIFEST="$value" ;;
      approval) RECOVERY_APPROVAL="$value" ;;
      checkpoint) RECOVERY_CHECKPOINT="$value" ;;
      output) RECOVERY_OUTPUT="$value" ;;
      scope) RECOVERY_SCOPE="$value" ;;
      step) RECOVERY_STEP="$value" ;;
    esac
    shift 2
  done

  for required_key in $required; do
    case "$required_key" in
      incident) required_value="$RECOVERY_INCIDENT" ;;
      host) required_value="$RECOVERY_HOST" ;;
      run-id) required_value="$RECOVERY_RUN_ID" ;;
      manifest) required_value="$RECOVERY_MANIFEST" ;;
      approval) required_value="$RECOVERY_APPROVAL" ;;
      checkpoint) required_value="$RECOVERY_CHECKPOINT" ;;
      output) required_value="$RECOVERY_OUTPUT" ;;
      scope) required_value="$RECOVERY_SCOPE" ;;
      step) required_value="$RECOVERY_STEP" ;;
    esac
    [[ -n "$required_value" ]] \
      || network_recover_cli_error "phase $phase requires --$required_key" || return 2
  done

  [[ "$RECOVERY_HOST" =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]] \
    || network_recover_cli_error 'host must be a lowercase safe SSH alias of at most 63 characters' || return 2
  [[ "$RECOVERY_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
    || network_recover_cli_error 'run-id must contain only letters, digits, dot, underscore, or dash' || return 2
  if [[ -n "$RECOVERY_INCIDENT" && ! "$RECOVERY_INCIDENT" =~ ^GNK-LAB-[0-9]{4}-[0-9]{4}$ ]]; then
    network_recover_cli_error 'incident must use the GNK-LAB-YYYY-NNNN form' || return 2
  fi
  if [[ -n "$RECOVERY_STEP" && ! "$RECOVERY_STEP" =~ ^(signers|handoff|poc)$ ]]; then
    network_recover_cli_error 'resume step must be signers, poc, or handoff' || return 2
  fi
  if [[ -n "$RECOVERY_SCOPE" && ! "$RECOVERY_SCOPE" =~ ^(consensus|epochs|service)$ ]]; then
    network_recover_cli_error 'verify scope must be consensus, epochs, or service' || return 2
  fi
  if [[ "$phase" == verify && "$RECOVERY_SCOPE" == service && -z "$RECOVERY_APPROVAL" ]]; then
    network_recover_cli_error 'verify --scope service requires --approval' || return 2
  fi
  if [[ "$phase" == verify && "$RECOVERY_SCOPE" != service && -n "$RECOVERY_APPROVAL" ]]; then
    network_recover_cli_error 'verify --approval is allowed only with --scope service' || return 2
  fi
  for path_value in "$RECOVERY_MANIFEST" "$RECOVERY_APPROVAL" "$RECOVERY_CHECKPOINT"; do
    [[ -z "$path_value" ]] || network_recover_input_path_valid "$path_value" \
      || network_recover_cli_error 'manifest, approval, and checkpoint must be existing canonical non-symlink files' || return 2
  done
  [[ -z "$RECOVERY_OUTPUT" ]] || network_recover_output_path_valid "$RECOVERY_OUTPUT" \
    || network_recover_cli_error 'output must be a new canonical path outside temporary storage' || return 2
}

COMMAND="${1:-help}"
shift || true

# Domain aliases make the authority boundary visible without invalidating
# existing executable evidence that still names the original lifecycle phases.
case "$COMMAND" in
  network)
    subcommand="${1:-}"; shift || true
    case "$subcommand" in
      bootstrap)
        if [[ "${1:-}" != verify ]] || { [[ "$#" -ne 2 ]] && { [[ "$#" -ne 3 || "${2:-}" != --online ]]; }; }; then
          usage
          exit 2
        fi
        COMMAND='network-bootstrap-verify'
        if [[ "${2:-}" == --online ]]; then set -- --online "$3"; else set -- "$2"; fi
        ;;
      recover)
        COMMAND='network-recover'
        ;;
      genesis|verify|reset) COMMAND="$subcommand" ;;
      gate-b) [[ "${1:-}" == verify && $# -eq 1 ]] || { usage; exit 2; }; shift; COMMAND=public-network-verify ;;
      confirmation-poc) [[ "${1:-}" == verify && $# -eq 1 ]] || { usage; exit 2; }; shift; COMMAND=confirmation-poc ;;
      upgrade) [[ "${1:-}" == verify && $# -eq 2 ]] || { usage; exit 2; }; COMMAND=public-upgrade-verify; set -- "$2" ;;
      *) usage; exit 2 ;;
    esac
    ;;
  host)
    subcommand="${1:-}"; shift || true
    case "$subcommand" in
      join) COMMAND='join' ;;
      backup) COMMAND='host-backup' ;;
      peers) COMMAND='host-peers' ;;
      upgrade)
        upgrade_action="${1:-}"; shift || true
        [[ "$upgrade_action" =~ ^(prepare|watch)$ ]] || { usage; exit 2; }
        COMMAND="host-upgrade-$upgrade_action"
        ;;
      ml-attach) COMMAND=ml; set -- attach "$@" ;;
      start|stop|verify|reset) COMMAND=node; set -- "$subcommand" "$@" ;;
      *) usage; exit 2 ;;
    esac
    ;;
esac
case "$COMMAND" in
  join) GDC_END_COMMAND='host join' ;;
  node) [[ "${1:-}" != reset ]] || GDC_END_COMMAND='host reset' ;;
  host-peers) GDC_END_COMMAND='host peers' ;;
  network-recover)
    case "${1:-}" in bootstrap|check) GDC_END_COMMAND="$1" ;; esac
    ;;
esac
case "$COMMAND" in
  host-peers)
    bash "$ROOT/scripts/host-peers.sh" "$@"
    ;;
  network-recover)
    [[ "$RELEASE_OPTION_SEEN" == false && "$COMPOSITION_OPTION_SEEN" == false && "$MODEL_OPTION_SEEN" == false ]] \
      || { echo 'network recover does not accept --release, --composition, or --model; runtime inputs come from the recovery manifest' >&2; exit 2; }
    if [[ "${1:-}" =~ ^(bootstrap|handoff|check)$ ]]; then
      if [[ "$1" == handoff ]]; then exec bash "$ROOT/scripts/recover-incident.sh" "$@"; fi
      bash "$ROOT/scripts/recover-incident.sh" "$@"
      exit 0
    fi
    recovery_phase="${1:-}"
    shift || true
    recovery_cli_args=("$@")
    if ! parse_network_recover_args "$recovery_phase" "${recovery_cli_args[@]}"; then
      exit 2
    fi
    # Recovery evidence is controller/run-wide. Preserve the original root
    # before selecting the Host-specific runtime home so cross-host gates and
    # approval replay protection never look beneath the current Host.
    GDC_RECOVERY_ROOT="$GDC_DATA_ROOT"
    export GDC_RECOVERY_ROOT
    use_node_data_home "$RECOVERY_HOST"
    export GDC_RUN_ID="$RECOVERY_RUN_ID" GDC_RUN_CONTEXT=network-recovery
    recovery_run_phase="network-recover-$RECOVERY_PHASE"
    [[ -z "$RECOVERY_STEP" ]] || recovery_run_phase+="-$RECOVERY_STEP"
    recovery_run_phase+="-$RECOVERY_HOST"
    run_phase "$recovery_run_phase" "$ROOT/scripts/phase-network-recover.sh" \
      "$RECOVERY_PHASE" "${recovery_cli_args[@]}"
    ;;
  network-bootstrap-verify)
    if [[ "${1:-}" == --online ]]; then
      [[ $# -eq 2 && -f "$2" && -r "$2" ]] || { echo 'network bootstrap verify --online requires one readable file' >&2; exit 2; }
      exec "$ROOT/scripts/network-bootstrap.sh" online "$2"
    fi
    [[ $# -eq 1 && -f "$1" && -r "$1" ]] || { echo 'network bootstrap verify requires one readable file' >&2; exit 2; }
    exec "$ROOT/scripts/network-bootstrap.sh" verify "$1"
    ;;
  release)
    case "${1:-}" in
      candidate)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        shift
        "$ROOT/scripts/release-candidate.py" "$@"
        ;;
      composition)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        "$ROOT/scripts/release-candidate.py" "$@"
        ;;
      *)
        usage; exit 2
        ;;
    esac
    ;;
  report)
    [[ "${1:-}" == github && $# -eq 1 ]] || { usage; exit 2; }
    export GDC_REPORT_MODE=true
    "$ROOT/scripts/gdc-report-github.sh"
    ;;
  public-network-verify|confirmation-poc|public-upgrade-verify)
    [[ $# -le 1 ]] || { usage; exit 2; }
    if [[ "$COMMAND" == confirmation-poc ]]; then
      use_network_owner_data_home
      use_operator_inventory
    fi
    case "$COMMAND" in
      public-network-verify) run_phase public-network-verify "$ROOT/scripts/phase-public-network-verify.sh" ;;
      confirmation-poc) run_phase confirmation-poc "$ROOT/scripts/phase-confirmation-poc.sh" ;;
      public-upgrade-verify)
        [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] && is_upgrade_target_profile || { usage; exit 2; }
        run_phase "public-upgrade-verify-$1" "$ROOT/scripts/phase-public-upgrade-verify.sh" "$1"
        ;;
    esac
    ;;
  host-upgrade-prepare|host-upgrade-watch)
    [[ $# -eq 2 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$2" =~ ^[1-9][0-9]*$ ]] && is_upgrade_target_profile || { usage; exit 2; }
    use_node_data_home "$1"
    if [[ "$COMMAND" == host-upgrade-prepare ]]; then
      run_phase "host-upgrade-prepare-$1-$2" "$ROOT/scripts/phase-host-upgrade-prepare.sh" "$1" "$2"
    else
      run_phase "host-upgrade-watch-$1-$2" "$ROOT/scripts/phase-host-upgrade-watch.sh" "$1" "$2"
    fi
    ;;
  host-backup)
    backup_alias="${1:-}"
    [[ $# -eq 1 && "$backup_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'host backup requires exactly one SSH alias' >&2; exit 2; }
    use_node_data_home "$backup_alias"
    backup_role_config=''
    if [[ -s "$GDC_HOME/.env" ]]; then backup_role_config="$GDC_HOME/.env";
    elif [[ -s "$STATE/active-role-config" ]]; then backup_role_config="$(<"$STATE/active-role-config")"; fi
    [[ -s "$backup_role_config" ]] || { echo "host backup requires retained operator state for $backup_alias; a running Host cannot recreate cold or warm recovery material" >&2; exit 1; }
    export GDC_ENV="$backup_role_config"
    source "$ROOT/scripts/lib.sh"
    load_project host-recovery
    run_phase "backup-$backup_alias" "$ROOT/scripts/phase-host-backup.sh" "$backup_alias"
    ;;
  prepare|verify|reset|baseline|settle|bootstrap-access|gateway-continuity|audit)
    use_network_owner_data_home
    if [[ "$COMMAND" == verify || "$COMMAND" == gateway-continuity || "$COMMAND" == audit ]]; then
      use_operator_inventory
    fi
    [[ "$COMMAND" == reset || $# -eq 0 ]] || { usage; exit 2; }
    if [[ "$COMMAND" == reset ]]; then
      # A completed Genesis keeps its narrow role input under the network-owner
      # Host. Reset must instead use the operator inventory at the data-root so
      # an explicit future Host can be reset before it has ever joined.
      if [[ -s "$GDC_DATA_ROOT/.env" ]]; then
        export GDC_ENV="$GDC_DATA_ROOT/.env"
        # A completed network may have left a runtime topology behind.  Reset
        # is an operator-inventory operation, so its public edge must come
        # from that inventory rather than from the network being removed.
        inventory_public_edge="$(awk -F= '$1 == "GDC_PUBLIC_EDGE_NODE" { print $2; exit }' "$GDC_DATA_ROOT/.env")"
        if [[ -n "$inventory_public_edge" ]]; then
          export GDC_PUBLIC_EDGE_NODE="$inventory_public_edge"
        fi
      fi
      # Reset begins a new evidence namespace. A prior lifecycle may have
      # been recorded against another release profile, which must not block
      # removal of the managed deployment state.
      export GDC_FORCE_NEW_RUN=true
      run_phase reset "$ROOT/scripts/phase-reset.sh" "$@"
      exit $?
    fi
    if [[ "$COMMAND" == baseline ]]; then
      run_phase baseline "$ROOT/scripts/phase-baseline.sh"
    elif [[ "$COMMAND" == bootstrap-access ]]; then
      run_phase bootstrap-access "$ROOT/scripts/phase-bootstrap-access.sh"
    elif [[ "$COMMAND" == gateway-continuity ]]; then
      run_phase gateway-continuity "$ROOT/scripts/phase-gateway-continuity.sh"
    elif [[ "$COMMAND" == audit ]]; then
      run_phase lifecycle-audit "$ROOT/scripts/phase-audit-lifecycle.sh"
    else
      run_phase "$COMMAND" "$ROOT/scripts/phase-$COMMAND.sh" "$@"
    fi
    ;;
  qualify-ml)
    [[ $# -le 1 ]] || { usage; exit 2; }
    if [[ $# -eq 1 ]]; then
      use_node_data_home "$1"
    else
      use_network_owner_data_home
    fi
    # Resolve topology after parsing flags so the same command works for any
    # valid SSH alias supplied by the operator inventory.
    source "$ROOT/scripts/lib.sh"
    load_project
    qualification_node="${1:-$GENESIS_NODE}"
    topology_contains_node "$qualification_node" || { echo "qualify-ml expects an alias from GDC_NODE_ALIASES, got: $qualification_node" >&2; exit 2; }
    use_node_data_home "$qualification_node"
    load_project
    qualification_target="$(node_ml_host "$qualification_node" || printf '%s' "$qualification_node")"
    export GDC_QUALIFY_HOSTS="$qualification_target"
    run_phase qualify-ml "$ROOT/scripts/phase-qualify-ml.sh"
    ;;
  genesis)
    genesis_alias='' genesis_time='' bootstrap_access=true skip_qualification=false
    genesis_public_host='' genesis_public_edge=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --time=*) [[ -z "$genesis_time" ]] || { usage; exit 2; }; genesis_time="$1" ;;
        --no-bootstrap-access) bootstrap_access=false ;;
        --skip-qualification) skip_qualification=true ;;
        --public-host) genesis_public_host="${2:-}"; shift ;;
        --public-edge) genesis_public_edge="${2:-}"; shift ;;
        *) [[ -z "$genesis_alias" ]] || { usage; exit 2; }; genesis_alias="$1" ;;
      esac
      shift
    done
    [[ -n "$genesis_alias" ]] || { echo 'genesis requires an SSH alias' >&2; usage; exit 2; }
    [[ -z "$genesis_public_edge" || "$genesis_public_edge" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
      echo "invalid public edge SSH alias: $genesis_public_edge" >&2; exit 2;
    }
    [[ -n "$genesis_public_edge" ]] || genesis_public_edge="$genesis_alias"
    use_node_data_home "$genesis_alias"
    genesis_input="$STATE/role-inputs/genesis-$genesis_alias"
    genesis_config_args=(--output "$genesis_input" --ssh-alias "$genesis_alias")
    [[ -n "$genesis_public_host" ]] && genesis_config_args+=(--public-host "$genesis_public_host")
    genesis_config_args+=(--public-edge-ssh-alias "$genesis_public_edge")
    "$ROOT/scripts/write-genesis-role-config.sh" "${genesis_config_args[@]}"
    printf '%s\n' "$genesis_input" >"$STATE/active-role-config"
    export GDC_ENV="$genesis_input"
    source "$ROOT/scripts/lib.sh"
    load_project
    topology_contains_node "$genesis_alias" || { echo "genesis expects an alias from GDC_NODE_ALIASES, got: $genesis_alias" >&2; exit 2; }
    topology_contains_node "$genesis_public_edge" || { echo "public edge expects an alias from GDC_NODE_ALIASES, got: $genesis_public_edge" >&2; exit 2; }
    export GDC_GENESIS_NODE="$genesis_alias" GDC_PUBLIC_EDGE_NODE="$genesis_public_edge" GDC_GATEWAY_NODE="$genesis_alias" GDC_TELEGRAM_BOT_HOST="$genesis_alias"
    export GDC_GENESIS_SKIP_QUALIFICATION="$skip_qualification"
    if [[ "$bootstrap_access" == true ]]; then
      export GDC_GENESIS_GUARDIAN_ENABLED=true GDC_GENESIS_BOOTSTRAP_ACCESS=true
    else
      export GDC_GENESIS_BOOTSTRAP_ACCESS=false
    fi
    genesis_args=()
    [[ -n "$genesis_time" ]] && genesis_args+=("$genesis_time")
    run_phase "genesis-$genesis_alias" "$ROOT/scripts/phase-genesis.sh" "${genesis_args[@]}"
    printf '%s\n' "$genesis_alias" >"$GDC_DATA_ROOT/network-owner"
    ;;
  upgrade)
    use_network_owner_data_home
    [[ $# -eq 0 ]] || { usage; exit 2; }
    is_upgrade_target_profile || { echo 'upgrade requires an upgrade-capable release profile' >&2; exit 2; }
    run_phase upgrade "$ROOT/scripts/phase-upgrade.sh"
    ;;
  upgrade-proposal)
    use_network_owner_data_home
    [[ $# -eq 0 ]] || { usage; exit 2; }
    is_upgrade_target_profile || { echo 'upgrade-proposal requires an upgrade-capable release profile' >&2; exit 2; }
    run_phase upgrade-proposal "$ROOT/scripts/phase-propose-upgrade.sh"
    ;;
  upgrade-worker)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    is_upgrade_target_profile || { echo 'upgrade-worker requires an upgrade-capable release profile' >&2; exit 2; }
    run_phase "upgrade-worker-$1" "$ROOT/scripts/phase-upgrade-worker.sh" "$1"
    ;;
  advance-after-upgrade)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'advance-after-upgrade requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase "advance-after-upgrade-$1" "$ROOT/scripts/phase-advance-after-upgrade.sh" "$1"
    ;;
  advance-after-upgrade-worker)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'advance-after-upgrade-worker requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase "advance-after-upgrade-worker-$1" "$ROOT/scripts/phase-advance-after-upgrade-worker.sh" "$1"
    ;;
  ops)
    use_network_owner_data_home
    # OPS configuration is owned by the network data root.  The network owner
    # has a node-local role input as well, but it must not shadow public
    # service settings such as the Telegram conversation URL.
    export GDC_ENV="$GDC_DATA_ROOT/.env"
    [[ $# -ge 1 ]] || { usage; exit 2; }
    if [[ "$1" == consumer ]]; then
      [[ $# -ge 3 && $# -le 5 && "$2" == telegram && "$3" =~ ^(apply|status|verify)$ ]] || { usage; exit 2; }
      [[ "$3" == verify || $# -eq 3 ]] || { usage; exit 2; }
      run_phase "ops-consumer-telegram-$3" "$ROOT/scripts/phase-telegram-consumer.sh" "${@:3}"
    elif [[ "$1" == edge-node ]]; then
      [[ $# -eq 2 ]] || { usage; exit 2; }
      source "$ROOT/scripts/lib.sh"
      load_project
      topology_contains_node "$2" || { echo "ops edge-node expects an alias from GDC_NODE_ALIASES, got: $2" >&2; exit 2; }
      run_phase "ops-edge-node-$2" "$ROOT/scripts/phase-ops.sh" "$1" "$2"
    else
      [[ $# -eq 1 && "$1" =~ ^(gateway|faucet|monitoring|site|explorer|edge)$ ]] || { usage; exit 2; }
      run_phase "ops-$1" "$ROOT/scripts/phase-ops.sh" "$1"
    fi
    ;;
  gateway)
    use_network_owner_data_home
    use_operator_inventory
    gateway_action="${1:-}"; shift || true
    case "$gateway_action" in
      access-key)
        if [[ "${1:-}" == list && $# -eq 1 ]]; then
          run_phase gateway-access-key-list "$ROOT/scripts/phase-gateway-access-key.sh" list
        elif [[ $# -eq 2 && "$1" =~ ^(ensure|revoke)$ && "$2" == telegram ]]; then
          run_phase "gateway-access-key-$1-telegram" "$ROOT/scripts/phase-gateway-access-key.sh" "$1" telegram
        else
          usage; exit 2
        fi
        ;;
      apply|reconcile)
        [[ $# -le 1 && "${1:-v3}" =~ ^v[345]$ ]] || { usage; exit 2; }
        export GDC_GATEWAY_VERSION="${1:-v3}"
        run_phase "gateway-$gateway_action-$GDC_GATEWAY_VERSION" "$ROOT/scripts/phase-ops.sh" gateway
        ;;
      migration)
        migration_action="${1:-}"
        shift || true
        case "$migration_action" in
          prepare)
            [[ $# -eq 1 && "$1" =~ ^v[45]$ ]] || { usage; exit 2; }
            run_phase "gateway-migration-prepare-$1" "$ROOT/scripts/phase-gateway-migration.sh" prepare "$1"
            ;;
          status|cutover|rollback|complete)
            [[ $# -eq 0 ]] || { usage; exit 2; }
            run_phase "gateway-migration-$migration_action" "$ROOT/scripts/phase-gateway-migration.sh" "$migration_action"
            ;;
          drain)
            [[ $# -le 1 && "${1:-900}" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
            run_phase gateway-migration-drain "$ROOT/scripts/phase-gateway-migration.sh" drain "${1:-900}"
            ;;
          *) usage; exit 2 ;;
        esac
        ;;
      canary)
        canary_action="${1:-}"
        shift || true
        case "$canary_action" in
          prepare)
            [[ $# -eq 1 && "$1" =~ ^v[45]$ ]] || { usage; exit 2; }
            run_phase "gateway-canary-prepare-$1" "$ROOT/scripts/phase-gateway-canary.sh" prepare "$1"
            ;;
          status|stop)
            [[ $# -eq 0 ]] || { usage; exit 2; }
            run_phase "gateway-canary-$canary_action" "$ROOT/scripts/phase-gateway-canary.sh" "$canary_action"
            ;;
          *) usage; exit 2 ;;
        esac
        ;;
      status|verify)
        [[ "$gateway_action" == verify || $# -eq 0 ]] || { usage; exit 2; }
        [[ $# -le 1 ]] || { usage; exit 2; }
        run_phase "gateway-$gateway_action" "$ROOT/scripts/phase-gateway-observe.sh" "$gateway_action" "$@"
        ;;
      continuity)
        [[ $# -eq 0 ]] || { usage; exit 2; }
        run_phase gateway-continuity "$ROOT/scripts/phase-gateway-continuity.sh"
        ;;
      settle)
        [[ $# -eq 0 ]] || { usage; exit 2; }
        run_phase settle "$ROOT/scripts/phase-settle.sh"
        ;;
      ha)
        [[ $# -eq 1 && "$1" == v4 ]] || { usage; exit 2; }
        run_phase ha-v4 "$ROOT/scripts/phase-ha-v4.sh"
        ;;
      *) usage; exit 2 ;;
    esac
    ;;
  node)
    node_action="${1:-}"
    shift || true
    [[ "$node_action" =~ ^(stop|start|verify|reset)$ ]] || { usage; exit 2; }
    if [[ "$node_action" == reset ]]; then
      [[ $# -ge 1 ]] || { usage; exit 2; }
      # Reset deliberately starts fresh evidence. It must remain usable after
      # a prior lifecycle under another release profile and must never alter
      # that prior manifest.
      export GDC_FORCE_NEW_RUN=true
    else
      [[ $# -eq 1 ]] || { usage; exit 2; }
    fi
    for node_alias in "$@"; do
      [[ "$node_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "node $node_action received an invalid SSH alias: $node_alias" >&2; exit 2; }
    done
    if [[ "$node_action" != reset ]]; then
      use_node_data_home "$1"
      source "$ROOT/scripts/lib.sh"
      load_retained_join_profile_for_node "$1"
      load_project
      topology_contains_node "$1" || { echo "node $node_action expects an alias from GDC_NODE_ALIASES, got: $1" >&2; exit 2; }
    fi
    # A multi-host reset deliberately invokes the identical one-host phase for
    # each alias. This preserves its safety checks and makes failure semantics
    # the same as running the commands separately: completed hosts stay reset,
    # and processing stops at the first failed host.
    for node_alias in "$@"; do
      use_node_data_home "$node_alias"
      if [[ "$node_action" == reset ]]; then
        reset_previous_run_id="$(cat "$STATE/active-run-id" 2>/dev/null || true)"
        [[ -z "$reset_previous_run_id" || "$reset_previous_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
          echo "host reset found an unsafe retained active run identifier for $node_alias" >&2; exit 2;
        }
        export GDC_RESET_PREVIOUS_RUN_ID="$reset_previous_run_id"
      else
        unset GDC_RESET_PREVIOUS_RUN_ID
      fi
      run_phase "node-$node_action-$node_alias" "$ROOT/scripts/phase-node.sh" "$node_action" "$node_alias"
    done
    ;;
  governance)
    export GDC_FORCE_NEW_RUN=true
    use_network_owner_data_home
    governance_action="${1:-}"; shift || true
    if [[ "$governance_action" == devshard ]]; then
      case "${1:-}" in
        '') run_phase governance-devshard "$ROOT/scripts/phase-governance-devshard.sh" ;;
        --protocols)
          [[ $# -eq 2 ]] || { usage; exit 2; }
          configure_devshard_governance_protocols "$2"
          run_phase governance-devshard "$ROOT/scripts/phase-governance-devshard.sh"
          ;;
        submit)
          shift
          if [[ $# -gt 0 ]]; then
            [[ $# -eq 2 && "$1" == --protocols ]] || { usage; exit 2; }
            configure_devshard_governance_protocols "$2"
          fi
          GDC_GOVERNANCE_SUBMIT=true run_phase governance-devshard-submit "$ROOT/scripts/phase-governance-devshard.sh"
          ;;
        verify)
          shift
          proposal_id="${1:-}"
          [[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
          shift
          if [[ $# -gt 0 ]]; then
            [[ $# -eq 2 && "$1" == --protocols ]] || { usage; exit 2; }
            configure_devshard_governance_protocols "$2"
          fi
          GDC_GOVERNANCE_PROPOSAL_ID="$proposal_id" run_phase "governance-devshard-verify-$proposal_id" "$ROOT/scripts/phase-governance-devshard.sh"
          ;;
        *) usage; exit 2 ;;
      esac
    elif [[ "$governance_action" == vote ]]; then
      [[ $# -eq 1 || $# -eq 2 ]] || { usage; exit 2; }
      run_phase "vote-proposal-$1" "$ROOT/scripts/phase-vote-proposal.sh" "$@"
    else
      usage; exit 2
    fi
    ;;
  vote)
    export GDC_FORCE_NEW_RUN=true
    use_network_owner_data_home
    [[ $# -eq 1 || $# -eq 2 ]] || { usage; exit 2; }
    run_phase "vote-proposal-$1" "$ROOT/scripts/phase-vote-proposal.sh" "$@"
    ;;
  ha)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" == v4 ]] || { usage; exit 2; }
    run_phase ha-v4 "$ROOT/scripts/phase-ha-v4.sh"
    ;;
  bridge-deploy)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" == sepolia ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'bridge-deploy requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase bridge-deploy-sepolia "$ROOT/scripts/phase-bridge-deploy-sepolia.sh"
    ;;
  bridge-register)
    use_network_owner_data_home
    [[ "${1:-}" == sepolia ]] || { echo 'usage: ./gdc.sh --release v2026.08.06 bridge-register sepolia' >&2; exit 2; }
    shift
    [[ "$RELEASE_PROFILE" == v2026.08.06 ]] || {
      echo 'bridge-register requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase bridge-register-sepolia "$ROOT/scripts/phase-bridge-register-sepolia.sh"
    ;;
  bridge)
    use_network_owner_data_home
    bridge_scope="${1:-}"; shift || true
    case "$bridge_scope" in
      sepolia)
        [[ $# -eq 0 ]] || { usage; exit 2; }
        run_phase bridge-sepolia "$ROOT/scripts/phase-bridge-observer.sh" apply "${GDC_BRIDGE_HOST:-$GENESIS_NODE}"
        ;;
      contract)
        bridge_action="${1:-}"; network="${2:-}"; [[ $# -eq 2 && "$network" == sepolia ]] || { usage; exit 2; }
        case "$bridge_action" in
          deploy) run_phase bridge-contract-deploy-sepolia "$ROOT/scripts/phase-bridge-deploy-sepolia.sh" ;;
          register) run_phase bridge-contract-register-sepolia "$ROOT/scripts/phase-bridge-register-sepolia.sh" ;;
          *) usage; exit 2 ;;
        esac
        ;;
      observer)
        bridge_action="${1:-}"; bridge_host="${2:-}"; [[ $# -eq 2 && "$bridge_action" =~ ^(apply|status|verify)$ ]] || { usage; exit 2; }
        run_phase "bridge-observer-$bridge_action-$bridge_host" "$ROOT/scripts/phase-bridge-observer.sh" "$bridge_action" "$bridge_host"
        ;;
      *) usage; exit 2 ;;
    esac
    ;;
  join)
    # A caller's inherited environment must never turn an ordinary JOIN into
    # a participant-key replacement. Only the explicit CLI option below may
    # grant that capability for this invocation.
    unset GDC_JOIN_REBIND_EXISTING_PARTICIPANT
    join_source_rpc='' join_pex=''
    join_source_args=()
    join_alias='' join_gpu_alias='' join_public_host='' join_restore_archive='' join_bootstrap_file='' join_p2p_port='' join_resume_run='' join_old_signer_fence='' join_mnemonic_file='' join_mnemonic_prompt=false join_chain_id=gonka-devnet-community join_preflight_deadline="${GDC_JOIN_PREFLIGHT_DEADLINE:-30m}" skip_qualification=false verification=false plan_only=false
    # JOIN derives its exact compatible runtime from the first healthy
    # Bootstrap seed. An operator-selected release or composition could
    # otherwise turn retained evidence into a software authority.
    [[ -z "$RELEASE" ]] || { echo 'host join does not accept --release; composition is selected from verified seed observations' >&2; exit 2; }
    [[ -z "$COMPOSITION" ]] || { echo 'host join does not accept --composition; composition is selected from verified seed observations' >&2; exit 2; }
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --release|--release=*|--composition|--composition=*)
          echo 'host join does not accept release or composition selectors; composition is selected from verified seed observations' >&2
          exit 2
          ;;
        --skip-qualification) skip_qualification=true ;;
        --verification) verification=true ;;
        --plan) plan_only=true ;;
        --mnemonic-prompt) join_mnemonic_prompt=true ;;
        --mnemonic-file)
          [[ -z "$join_mnemonic_file" && -n "${2:-}" ]] || { echo 'host join --mnemonic-file expects one non-empty path' >&2; exit 2; }
          join_mnemonic_file="$2"
          shift
          ;;
        --mnemonic-file=*)
          [[ -z "$join_mnemonic_file" && -n "${1#--mnemonic-file=}" ]] || { echo 'host join --mnemonic-file expects one non-empty path' >&2; exit 2; }
          join_mnemonic_file="${1#--mnemonic-file=}"
          ;;
        --preflight-deadline)
          [[ -n "${2:-}" ]] || { echo 'host join --preflight-deadline requires a positive duration such as 30m' >&2; exit 2; }
          join_preflight_deadline="$2"; shift ;;
        --preflight-deadline=*)
          join_preflight_deadline="${1#--preflight-deadline=}" ;;
        --pex)
          [[ -z "$join_pex" && "${2:-}" =~ ^(true|false)$ ]] || { echo 'host join --pex expects true or false once' >&2; exit 2; }
          join_pex="$2"; shift ;;
        --source-rpc)
          [[ -z "$join_source_rpc" && "${2:-}" =~ ^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?(/[A-Za-z0-9/_-]*)?$ ]] || { echo 'host join --source-rpc expects one RPC URL' >&2; exit 2; }
          join_source_rpc="${2%/}"; join_source_args=(--source-rpc "$join_source_rpc"); shift ;;
        --resume) join_resume_run="${2:-}"; shift ;;
        --old-signer-fence)
          join_old_signer_fence="${2:-}"
          [[ -n "$join_old_signer_fence" && -f "$join_old_signer_fence" && -r "$join_old_signer_fence" ]] || {
            echo 'host join --old-signer-fence requires a readable receipt file' >&2; exit 2;
          }
          join_old_signer_fence="$(realpath -e -- "$join_old_signer_fence")"
          shift
          ;;
        --chain-id)
          join_chain_id="${2:-}"
          [[ "$join_chain_id" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] || { echo 'host join --chain-id requires a safe chain identifier' >&2; exit 2; }
          shift
          ;;
        --chain-id=*)
          join_chain_id="${1#--chain-id=}"
          [[ "$join_chain_id" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] || { echo 'host join --chain-id requires a safe chain identifier' >&2; exit 2; }
          ;;
        --public-host)
          join_public_host="${2:-}"
          [[ "$join_public_host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'host join --public-host requires an IP address or domain' >&2; exit 2; }
          shift
          ;;
        --bootstrap-file)
          join_bootstrap_file="${2:-}"
          [[ -r "$join_bootstrap_file" ]] || { echo 'host join --bootstrap-file requires a readable file' >&2; exit 2; }
          join_bootstrap_file="$(realpath -e -- "$join_bootstrap_file")"
          shift
          ;;
        --p2p-port)
          join_p2p_port="${2:-}"
          [[ "$join_p2p_port" =~ ^[1-9][0-9]{0,4}$ && "$join_p2p_port" -le 65535 ]] || { echo 'host join --p2p-port requires a port from 1 through 65535' >&2; exit 2; }
          shift
          ;;
        --restore)
          join_restore_archive="${2:-}"
          [[ -n "$join_restore_archive" && -f "$join_restore_archive" && -r "$join_restore_archive" ]] || {
            echo 'host join --restore requires a readable validator backup archive' >&2; exit 2;
          }
          join_restore_archive="$(realpath -e -- "$join_restore_archive")"
          shift
          ;;
        --*) echo "unknown host join option: $1" >&2; usage; exit 2 ;;
        *)
          if [[ -z "$join_alias" ]]; then
            join_alias="$1"
          elif [[ -z "$join_gpu_alias" ]]; then
            join_gpu_alias="$1"
          else
            usage
            exit 2
          fi
          ;;
      esac
      shift
    done
    [[ -n "$join_alias" ]] || { echo 'host join requires an SSH alias' >&2; usage; exit 2; }
    join_preflight_deadline_seconds="$(parse_join_preflight_wait_seconds "$join_preflight_deadline")" || {
      echo 'host join --preflight-deadline requires a positive duration up to 24h, for example 30m or 1800' >&2; exit 2;
    }
    join_preflight_deadline_at=$((SECONDS + join_preflight_deadline_seconds))
    join_preflight_retry_seconds="${GDC_JOIN_PREFLIGHT_RETRY_SECONDS:-15}"
    [[ "$join_preflight_retry_seconds" =~ ^[1-9][0-9]*$ && "$join_preflight_retry_seconds" -le 300 ]] || {
      echo 'GDC_JOIN_PREFLIGHT_RETRY_SECONDS must be a positive integer up to 300' >&2; exit 2;
    }
    [[ -z "$join_resume_run" || "$join_resume_run" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo 'host join --resume requires a valid run ID' >&2; exit 2; }
    [[ -z "$join_old_signer_fence" || -n "$join_resume_run" ]] || { echo 'host join --old-signer-fence requires --resume <run-id>' >&2; exit 2; }
    [[ -z "$join_old_signer_fence" ]] || {
      echo 'host join does not accept an externally authored signer-fence receipt: independent prior-Host evidence is not implemented' >&2
      exit 2
    }
    if [[ "$join_mnemonic_prompt" == true && -n "$join_mnemonic_file" ]]; then
      echo 'Error: --mnemonic-prompt and --mnemonic-file are mutually exclusive' >&2
      exit 1
    fi
    [[ "$join_mnemonic_prompt" != true && -z "$join_mnemonic_file" || -z "$join_restore_archive" ]] || {
      echo 'host join mnemonic recovery cannot be combined with --restore; a validator archive already restores its original cold account and signer' >&2
      exit 2
    }
    [[ "$join_alias" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "invalid Host SSH alias: $join_alias (use lowercase letters, digits, _ or -)" >&2; exit 2; }
    if [[ -n "$join_gpu_alias" ]]; then
      [[ "$join_gpu_alias" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "invalid GPU SSH alias: $join_gpu_alias (use lowercase letters, digits, _ or -)" >&2; exit 2; }
      [[ "$join_gpu_alias" != "$join_alias" ]] || { echo 'Host and GPU SSH aliases must be different' >&2; exit 2; }
    fi
    use_node_data_home "$join_alias"
    if [[ ( "$join_mnemonic_prompt" == true || -n "$join_mnemonic_file" ) && "$plan_only" != true ]]; then
      # The mnemonic is read only on the operator machine, then retained as a
      # local mode-0600 recovery file. A new account follows ordinary
      # registration; an existing participant is explicitly rebound to the
      # newly generated TMKMS signer.
      join_mnemonic_input_args=()
      if [[ "$join_mnemonic_prompt" == true ]]; then
        join_mnemonic_input_args+=(--mnemonic-prompt)
      else
        join_mnemonic_input_args+=(--mnemonic-file "$join_mnemonic_file")
      fi
      join_cold_mnemonic="$("$ROOT/scripts/read-join-mnemonic.sh" "${join_mnemonic_input_args[@]}")"
      unset join_mnemonic_input_args
      join_mnemonic_dir="$GDC_HOME/mnemonics"
      install -d -m 0700 "$join_mnemonic_dir"
      join_mnemonic_file="$join_mnemonic_dir/$join_alias-cold.mnemonic"
      if [[ -e "$join_mnemonic_file" ]]; then
        [[ -f "$join_mnemonic_file" && ! -L "$join_mnemonic_file" ]] || { echo 'host join refuses an unsafe existing cold mnemonic path' >&2; exit 2; }
        [[ "$(<"$join_mnemonic_file")" == "$join_cold_mnemonic" ]] || { echo 'host join --mnemonic disagrees with the retained cold mnemonic for this Host' >&2; exit 2; }
      else
        umask 077
        printf '%s\n' "$join_cold_mnemonic" >"$join_mnemonic_file"
        chmod 0600 "$join_mnemonic_file"
      fi
      unset join_cold_mnemonic
      GDC_JOIN_REBIND_EXISTING_PARTICIPANT=true
      export GDC_JOIN_REBIND_EXISTING_PARTICIPANT
    fi
    acquire_operator_lock
    # Preserve the prior controller run before allocating this invocation's
    # evidence directory.  A normal JOIN may only be a no-op after a retained
    # COMPLETE; an incomplete run is resumed solely by its receipt-bound path.
    join_previous_run_id=''
    if [[ -s "$STATE/active-run-id" ]]; then
      join_previous_run_id="$(<"$STATE/active-run-id")"
      [[ "$join_previous_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
        echo 'host join refuses an unsafe retained active run identifier' >&2; exit 2;
      }
    fi
    export GDC_JOIN_PREVIOUS_RUN_ID="$join_previous_run_id"
    [[ -n "$join_public_host" ]] || { echo 'host join requires --public-host for a generated Join Profile' >&2; exit 2; }
    if [[ -n "$join_resume_run" ]]; then
      join_run="$GDC_HOME/runs/$join_resume_run/join-$join_alias"
      join_resume_verification="$("$ROOT/scripts/verify-join-resume-inputs.sh" --run-dir "$join_run" \
        --run-id "$join_resume_run" --node-name "$join_alias" --public-host "$join_public_host")"
      jq -e --arg source "$join_source_rpc" --arg pex "$join_pex" '
        ($source == "" or .spec.state_acquisition.trust_authority.rpc_url == $source) and
        ($pex == "" or .spec.state_acquisition.pex == ($pex == "true"))
      ' "$join_run/join-profile.v1.json" >/dev/null || { echo 'JOIN resume options differ from the retained profile' >&2; exit 2; }
      printf '%s\n' "$join_resume_verification"
      if [[ "$plan_only" == true ]]; then
        [[ -z "$join_old_signer_fence" ]] || {
          echo 'host join --plan --resume does not accept an old-signer fence because it performs no activation' >&2; exit 2;
        }
        printf 'PASS Host JOIN resume plan verified run_id=%s; no Host action was performed\n' "$join_resume_run"
        exit 0
      fi
      GDC_RUN_ID="$join_resume_run"
      GDC_JOIN_PROFILE="$join_run/join-profile.v1.json"
      GDC_JOIN_OBSERVATION="$join_run/network-observation.v1.json"
      GDC_JOIN_RESULT_OUTPUT="$join_run/join-result.v1.json"
      GDC_JOIN_RESUME=true
      export GDC_RUN_ID GDC_JOIN_PROFILE GDC_JOIN_OBSERVATION GDC_JOIN_RESULT_OUTPUT GDC_JOIN_RESUME
      printf '%s\n' "$GDC_RUN_ID" >"$STATE/active-run-id"
      join_role_config="$(<"$STATE/active-role-config")"
      [[ "$join_role_config" == "$STATE/role-inputs/"* && -r "$join_role_config" ]] || {
        echo 'host join --resume lacks its retained one-host role configuration' >&2; exit 2;
      }
      # shellcheck disable=SC1090 # retained role input was created by the original JOIN.
      source "$join_role_config"
      join_resume_state="$(jq -er .receipt_chain.last_state <<<"$join_resume_verification")"
      case "$join_resume_state" in
        CANONICAL_RUNNING|APPLICATION_ACTIVE)
          run_phase "join-resume-canonical-$join_alias" "$ROOT/scripts/phase-join-resume-canonical.sh" \
            "$join_alias" "$join_run"
          ;;
        SIGNER_ACTIVATING)
          run_phase "join-resume-signer-readback-$join_alias" "$ROOT/scripts/phase-join-resume-signer-readback.sh" \
            "$join_alias" "$join_run"
          ;;
        SIGNER_ACTIVE_VERIFIED)
          [[ "$verification" == true ]] || { echo 'host join signer acceptance resume requires --verification' >&2; exit 2; }
          run_phase "join-resume-acceptance-$join_alias" "$ROOT/scripts/phase-join-resume-acceptance.sh" \
            "$join_alias" "$join_run"
          ;;
        COMPLETE)
          # Keep the successful completion receipt intact: node start uses it
          # as the authority to restart the signer.  This invocation is
          # recorded in its run log, not by downgrading the retained result.
          printf 'PASS Host JOIN resume is already complete; no Host action was performed\n'
          ;;
        *)
          echo "host join --resume has no safe dispatcher for retained state=$join_resume_state" >&2
          exit 2
          ;;
      esac
      exit 0
    fi
    # Ordinary fresh JOIN restores normal peer discovery unless the operator
    # explicitly asks for the temporary recovery isolation mode. A retained
    # resume keeps its profile's recorded setting unless the user supplied an
    # explicit matching --pex option above.
    [[ -n "$join_pex" ]] || join_pex=true
    if [[ -z "${GDC_RUN_ID:-}" ]]; then
      GDC_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
      export GDC_RUN_ID
    fi
    # Persist bounded terminal evidence before any Bootstrap fetch or network
    # observation. The result location is fixed for this invocation even if
    # no phase manifest can be created safely.
    join_run="$GDC_HOME/runs/$GDC_RUN_ID/join-$join_alias"
    [[ ! -e "$join_run" ]] || { echo 'host join run directory already exists; use the receipt-bound resume command' >&2; exit 2; }
    install -d -m 0700 "$join_run"
    GDC_JOIN_RESULT_OUTPUT="$join_run/join-result.v1.json"
    export GDC_JOIN_RESULT_OUTPUT
    # Persist a bounded receipt before any Bootstrap fetch or network
    # observation. It is updated atomically as public facts become available.
    initialize_join_preflight_receipt
    # Bootstrap observation precedes both CLI installation and role-input
    # creation. The public network therefore selects the local immutable
    # profile before any software download or Host mutation.
    join_genesis="$GDC_HOME/genesis"
    join_secrets="$STATE/secrets"
    join_bootstrap_url="https://gonka-dev.net/${join_chain_id}/bootstrap.json"
    if [[ -z "$join_bootstrap_file" ]]; then
      join_bootstrap_file="$STATE/network-bootstrap.json"
      run_join_preflight bootstrap-fetch unavailable network curl \
        'The public Bootstrap descriptor could not be fetched and validated.' \
        "$ROOT/scripts/fetch-network-bootstrap.sh" --url "$join_bootstrap_url" --output "$join_bootstrap_file"
    else
      run_join_preflight bootstrap-verify invalid-bootstrap configuration bootstrap \
        'The supplied Bootstrap descriptor did not satisfy the local validation contract.' \
        "$ROOT/scripts/network-bootstrap.sh" verify "$join_bootstrap_file" >/dev/null
    fi
    run_join_preflight bootstrap-chain-id invalid-bootstrap configuration bootstrap \
      'The Bootstrap descriptor chain ID does not match the requested Host JOIN network.' \
      jq -e --arg chain "$join_chain_id" '.chain_id == $chain' "$join_bootstrap_file" >/dev/null
    # A first stable observation identifies the candidate runtime.  Local
    # downloads can take minutes, so a second stable observation is required
    # before the Host is touched.  Both gates share one operator-visible
    # deadline; a changed runtime starts another no-mutation candidate cycle.
    join_candidate_observation="$STATE/network-observation.candidate.v1.json"
    join_final_observation="$STATE/network-observation.v1.json"
    join_candidate_components="$STATE/join-components.candidate.v1.json"
    join_candidate_profile="$STATE/join-profile.candidate.v1.json"
    join_observation="$join_final_observation"
    join_profile="$STATE/join-profile.v1.json"
    join_operation=new
    [[ -z "$join_restore_archive" ]] || join_operation=restore
    join_preflight_cycle=0
    while :; do
      join_preflight_cycle=$((join_preflight_cycle + 1))
      run_join_preflight software-observation unavailable network seed-observer \
        'No Bootstrap seed established a complete healthy runtime identity.' \
        wait_for_join_software_observation "candidate-$join_preflight_cycle" "$join_candidate_observation" "$join_preflight_deadline_at" "$join_preflight_retry_seconds"
      GDC_NETWORK_FINGERPRINT="$(jq -r .network_state_id "$join_candidate_observation")"
      GDC_NETWORK_CHAIN_ID="$(jq -r .bootstrap.chain_id "$join_candidate_observation")"
      GDC_NETWORK_GENESIS_SHA256="$(jq -r .bootstrap.genesis_sha256 "$join_candidate_observation")"
      export GDC_NETWORK_FINGERPRINT GDC_NETWORK_CHAIN_ID GDC_NETWORK_GENESIS_SHA256
      run_join_preflight component-resolution unavailable dependency official-artifact-resolver \
        'Official immutable artifacts could not be resolved for the selected Core and DAPI runtime bytes.' \
        "$ROOT/scripts/resolve-join-components.sh" --observation "$join_candidate_observation" --output "$join_candidate_components"
      join_profile_args=(--observation "$join_candidate_observation" --components "$join_candidate_components" --node-name "$join_alias" --public-host "$join_public_host" --operation "$join_operation" --run-id "$GDC_RUN_ID" --output "$join_candidate_profile")
      [[ -z "$join_p2p_port" ]] || join_profile_args+=(--p2p-port "$join_p2p_port")
      join_profile_args+=(--pex "$join_pex")
      [[ -z "$join_restore_archive" ]] || join_profile_args+=(--restore-archive "$join_restore_archive")
      run_join_preflight join-profile unavailable profile join-profile \
        'The observed network could not be compiled into an executable Join Profile.' \
        "$ROOT/scripts/resolve-join-profile.sh" "${join_profile_args[@]}"
      # A plan produces only profile and observation evidence. It must not
      # download a release archive or contact a Host.
      if [[ "$plan_only" != true ]]; then
        join_preflight_remaining=$((join_preflight_deadline_at - SECONDS))
        (( join_preflight_remaining > 0 )) || {
          GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT=true
          export GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT
          run_join_preflight software-observation unavailable network seed-observer \
            'The JOIN preflight deadline elapsed before its immutable CLI was available.' false
        }
        GDC_INFERENCED_CLI_TIMEOUT_SECONDS="$(( join_preflight_remaining < 600 ? join_preflight_remaining : 600 ))"
        export GDC_INFERENCED_CLI_TIMEOUT_SECONDS
        run_join_preflight inferenced-cli unavailable dependency inferenced \
          'The pinned operator CLI was not available before the JOIN preflight deadline.' \
          "$ROOT/scripts/ensure-inferenced-cli.sh" --join-profile "$join_candidate_profile"
      fi
      run_join_preflight software-observation unavailable network seed-observer \
        'The runtime changed or could not be confirmed immediately before Host preparation.' \
        wait_for_join_software_observation "confirm-$join_preflight_cycle" "$join_final_observation" "$join_preflight_deadline_at" "$join_preflight_retry_seconds"
      if [[ "$(join_observation_identity "$join_candidate_observation")" == "$(join_observation_identity "$join_final_observation")" ]]; then
        break
      fi
      printf 'WAIT JOIN runtime changed during preflight cycle=%s; retrying without Host mutation\n' "$join_preflight_cycle"
    done
    GDC_NETWORK_FINGERPRINT="$(jq -r .network_state_id "$join_observation")"
    GDC_NETWORK_CHAIN_ID="$(jq -r .bootstrap.chain_id "$join_observation")"
    GDC_NETWORK_GENESIS_SHA256="$(jq -r .bootstrap.genesis_sha256 "$join_observation")"
    export GDC_NETWORK_FINGERPRINT GDC_NETWORK_CHAIN_ID GDC_NETWORK_GENESIS_SHA256
    write_join_preflight_receipt software-observation passed unavailable seed-observer
    join_components="$join_candidate_components"
    join_profile_args=(--observation "$join_observation" --components "$join_components" --node-name "$join_alias" --public-host "$join_public_host" --operation "$join_operation" --run-id "$GDC_RUN_ID" --output "$join_profile")
    [[ -z "$join_p2p_port" ]] || join_profile_args+=(--p2p-port "$join_p2p_port")
    join_profile_args+=(--pex "$join_pex")
    [[ -z "$join_restore_archive" ]] || join_profile_args+=(--restore-archive "$join_restore_archive")
    run_join_preflight join-profile unavailable profile join-profile \
      'The confirmed network could not be compiled into an executable Join Profile.' \
      "$ROOT/scripts/resolve-join-profile.sh" "${join_profile_args[@]}"
    if [[ "$plan_only" != true ]]; then
      # Candidate and confirmed profiles can differ in observation metadata.
      # Bind downstream commands to the confirmed profile; a matching archive
      # is reused from the verified cache rather than downloaded again.
      join_preflight_remaining=$((join_preflight_deadline_at - SECONDS))
      (( join_preflight_remaining > 0 )) || {
        GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT=true
        export GDC_JOIN_SOFTWARE_OBSERVATION_TIMEOUT
        run_join_preflight inferenced-cli unavailable dependency inferenced \
          'The JOIN preflight deadline elapsed before its immutable CLI was available.' false
      }
      GDC_INFERENCED_CLI_TIMEOUT_SECONDS="$(( join_preflight_remaining < 600 ? join_preflight_remaining : 600 ))"
      export GDC_INFERENCED_CLI_TIMEOUT_SECONDS
      run_join_preflight inferenced-cli unavailable dependency inferenced \
        'The pinned operator CLI was not available before the JOIN preflight deadline.' \
        "$ROOT/scripts/ensure-inferenced-cli.sh" --join-profile "$join_profile"
    fi
    # The state directory is mutable across invocations. Keep the exact
    # inputs for this run under its private evidence directory.
    install -m 0600 "$join_observation" "$join_run/network-observation.v1.json"
    install -m 0600 "$join_profile" "$join_run/join-profile.v1.json"
    GDC_JOIN_PROFILE="$join_run/join-profile.v1.json"
    GDC_JOIN_OBSERVATION="$join_run/network-observation.v1.json"
    export GDC_JOIN_PROFILE GDC_JOIN_OBSERVATION
    write_join_preflight_receipt join-profile passed unavailable join-profile
    install -m 0600 "$GDC_JOIN_PREFLIGHT_RECEIPT" "$join_run/preflight-receipt.env"
    if [[ "$plan_only" == true ]]; then
      record_join_terminal_result no_op profile internal plan_completed 0 none absent new_profile
      printf 'PASS Host JOIN plan profile=%s observation=%s preflight_receipt=%s result=%s\n' \
        "$GDC_JOIN_PROFILE" "$GDC_JOIN_OBSERVATION" "$join_run/preflight-receipt.env" "$GDC_JOIN_RESULT_OUTPUT"
      exit 0
    fi
    if [[ -n "$join_previous_run_id" && "$join_previous_run_id" != "$GDC_RUN_ID" ]]; then
      previous_join_run="$GDC_HOME/runs/$join_previous_run_id/join-$join_alias"
      join_reentry="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$previous_join_run" --current-profile "$GDC_JOIN_PROFILE")"
      join_reentry_class="$(jq -er '.classification' <<<"$join_reentry")"
      case "$join_reentry_class" in
        no_prior_run)
          ;;
        preflight_retry_allowed)
          printf 'PASS Host JOIN previous run stopped before Host mutation; preserving its evidence and retrying fresh preflight\n'
          ;;
        preparation_retry_allowed)
          printf 'PASS Host JOIN previous run stopped after Host preparation for reboot; preserving its evidence and retrying fresh preflight\n'
          ;;
        refused_before_mutation)
          printf 'READY prior JOIN run %s stopped before any Host change; classifying the Host afresh\n' "$join_previous_run_id"
          ;;
        completed_matched)
          head_name="$(find "$previous_join_run/receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
          # Semantic equality was established against the fresh profile above.
          # Remote deployment binding is intentionally checked against the
          # original retained file, whose invocation metadata has its own SHA.
          if ! "$ROOT/scripts/verify-complete-join-state.sh" "$join_alias" "$previous_join_run/join-profile.v1.json" "$previous_join_run/receipts/$head_name"; then
            record_join_terminal_result refused acceptance host completed_join_readback_failed 1 none unknown manual_recovery
            echo 'host join completed-state readback failed; do not rerun a completed JOIN as a deployment mutation' >&2
            exit 1
          fi
          record_join_terminal_result no_op acceptance internal join_complete_no_op 0 signer_may_be_on enabled not_applicable
          printf 'PASS Host JOIN is already complete with the current immutable profile; no Host mutation was performed\n'
          exit 0
          ;;
        resume_required)
          record_join_terminal_result refused identity internal join_reentry_requires_resume 1 none unknown manual_recovery
          printf 'host join found a retained incomplete run; use gdc host join --resume %s --public-host %s %s\n' \
            "$join_previous_run_id" "$join_public_host" "$join_alias" >&2
          exit 1
          ;;
        manual_recovery_required)
          record_join_terminal_result refused signer internal join_reentry_manual_recovery_required 1 none unknown manual_recovery
          echo 'host join retained state has no safe automatic resume dispatcher; preserve evidence and use an owner-authorized recovery protocol' >&2
          exit 1
          ;;
        profile_changed)
          record_join_terminal_result refused profile internal join_reentry_profile_changed 1 none unknown new_profile
          echo 'host join refuses to redeploy a completed validator with a different Join Profile; use the explicit upgrade workflow' >&2
          exit 1
          ;;
        blocked)
          record_join_terminal_result refused identity internal join_reentry_evidence_invalid 1 none unknown manual_recovery
          echo 'host join refuses retained incomplete or invalid JOIN evidence; inspect the retained run before any recovery action' >&2
          exit 1
          ;;
        *)
          echo 'host join received an invalid retained JOIN re-entry classification' >&2
          exit 70
          ;;
      esac
    fi
    join_lineage_receipt="$STATE/lineage-preflight.json"
    join_lineage_env="$STATE/lineage-preflight.env"
    GDC_JOIN_LINEAGE_FAILURE_FILE="$STATE/lineage-preflight.failure"
    export GDC_JOIN_LINEAGE_FAILURE_FILE
    rm -f "$GDC_JOIN_LINEAGE_FAILURE_FILE"
    join_lineage_args=(--bootstrap-file "$join_bootstrap_file" --observation "$join_observation" --receipt "$join_lineage_receipt" --env "$join_lineage_env")
    join_lineage_args+=("${join_source_args[@]}")
    run_join_preflight lineage-preflight refused lineage lineage-preflight \
      'Independent RPC lineage and trust were not established for native P2P state sync.' \
      "$ROOT/scripts/preflight-join-lineage.sh" "${join_lineage_args[@]}"
    # The preflight writes fixed-name, shell-quoted values only after it has
    # bound them to the observed runtime fingerprint and two fault domains.
    # shellcheck disable=SC1090
    source "$join_lineage_env"
    export GDC_JOIN_BOOTSTRAP_MODE GDC_JOIN_TRUST_HEIGHT GDC_JOIN_TRUST_HASH GDC_JOIN_SNAPSHOT_PEERS
    export GDC_JOIN_RPC_SERVER_1 GDC_JOIN_RPC_SERVER_2 GDC_JOIN_TRUSTED_BLOCK_PERIOD GDC_JOIN_LINEAGE_RECEIPT
    export GDC_JOIN_GATEWAY_ADMISSION_PROTOCOLS_JSON
    GDC_JOIN_LINEAGE_RECEIPT_SHA256="$(sha256sum "$GDC_JOIN_LINEAGE_RECEIPT" | awk '{print $1}')"
    export GDC_JOIN_LINEAGE_RECEIPT_SHA256
    write_join_preflight_receipt lineage-preflight passed unavailable lineage-preflight
    install -m 0600 "$join_lineage_receipt" "$join_run/lineage-preflight.v1.json"
    install -m 0600 "$join_lineage_env" "$join_run/lineage-preflight.env"
    run_join_preflight bootstrap-stage unavailable chain bootstrap \
       'The validated Bootstrap descriptor could not be staged locally.' \
       "$ROOT/scripts/stage-network-bootstrap.sh" --bootstrap-file "$join_bootstrap_file" --genesis-dir "$join_genesis" --state-dir "$STATE" --secrets-dir "$join_secrets"
    export GDC_JOIN_SKIP_QUALIFICATION="$skip_qualification"
    export GDC_JOIN_VERIFICATION="$verification"
    if [[ -n "$join_restore_archive" ]]; then
      export GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE="$join_restore_archive"
      # Recovery is not a continuation of a historical software decision.
      # It receives a new manifest bound to the currently observed network.
      export GDC_JOIN_RECOVERY_NEW_RUN=true
    fi
    join_role_ready=false
    join_role_config=''
    if [[ -n "${GDC_ENV:-}" && -s "$GDC_ENV" ]]; then
      join_role_config="$GDC_ENV"
    elif [[ -s "$GDC_HOME/.env" ]]; then
      join_role_config="$GDC_HOME/.env"
    elif [[ -s "$STATE/active-role-config" ]]; then
      join_role_config="$(<"$STATE/active-role-config")"
    fi
    if [[ -s "$join_role_config" ]]; then
      # This is a locally generated, mode-0600 role file.
      # shellcheck disable=SC1090
      source "$join_role_config"
    fi
    if [[ -s "$join_role_config" ]] && (
        # This is a locally generated, mode-0600 role file.
        # shellcheck disable=SC1090
        source "$join_role_config"
        # A bootstrap can rotate between attempts. Generated JOIN role inputs
        # therefore never bypass preparation on a new invocation.
        [[ "${GDC_JOIN_ROLE_INPUT:-false}" != true ]] || exit 1
        [[ -z "$join_source_rpc" ]] || exit 1
        [[ " ${GDC_NODE_ALIASES:-} " == *" $join_alias "* ]] || exit 1
        [[ -z "$join_public_host" ]] || [[ "$(topology_value "${GDC_NODE_PUBLIC_HOSTS:-}" "$join_alias" || true)" == "$join_public_host" ]] || exit 1
        [[ -z "$join_gpu_alias" ]] && exit 0
        for mapping in ${GDC_NODE_ML_HOSTS:-}; do
          [[ "$mapping" == "$join_alias=$join_gpu_alias" ]] && exit 0
        done
        exit 1
      ); then
      join_role_ready=true
      export GDC_ENV="$join_role_config"
    fi
    if [[ "$join_role_ready" != true ]]; then
      join_input="$STATE/role-inputs/join-$join_alias"
      join_config_args=(--output "$join_input" --ssh-alias "$join_alias")
      join_config_args+=(--bootstrap-file "$join_bootstrap_file")
      join_config_args+=("${join_source_args[@]}")
      [[ -n "$join_public_host" ]] && join_config_args+=(--public-host "$join_public_host")
      [[ -n "$join_gpu_alias" ]] && join_config_args+=(--gpu-ssh-alias "$join_gpu_alias")
      [[ -n "$join_p2p_port" ]] && join_config_args+=(--p2p-port "$join_p2p_port")
      "$ROOT/scripts/prepare-join-role-config.sh" "${join_config_args[@]}"
      printf '%s\n' "$join_input" >"$STATE/active-role-config"
      export GDC_ENV="$join_input"
      join_role_config="$join_input"
      # shellcheck disable=SC1090
      source "$join_role_config"
    fi
    # A plan is diagnostic output, not execution history.  Publish this run
    # as active only after all no-mutation preflight gates have passed and the
    # profile is still fresh immediately before the first mutating phase.
    "$ROOT/scripts/join-profile.sh" validate "$GDC_JOIN_PROFILE" >/dev/null
    printf '%s\n' "$GDC_RUN_ID" >"$STATE/active-run-id"
    # Preserve whether the operator explicitly selected the archival source.
    # GDC_JOIN_SOURCE_RPC is the preflight's selected source even in automatic
    # mode, so phase-join must not turn that selection into operator authority
    # when it refreshes short-lived lineage trust before its canary.
    GDC_JOIN_OPERATOR_SOURCE_RPC="$join_source_rpc"
    export GDC_JOIN_OPERATOR_SOURCE_RPC
    run_phase "join-$join_alias" "$ROOT/scripts/phase-join.sh" "$join_alias"
    ;;
  ml)
    [[ $# -eq 2 && "$1" == attach ]] || { usage; exit 2; }
    use_node_data_home "$2"
    source "$ROOT/scripts/lib.sh"
    load_project
    topology_contains_node "$2" || { echo "ml attach expects an alias from GDC_NODE_ALIASES, got: $2" >&2; exit 2; }
    [[ -n "$(node_ml_host "$2" || true)" ]] || { echo "no network GPU configured for $2 in GDC_NODE_ML_HOSTS" >&2; exit 2; }
    run_phase "ml-attach-$2" "$ROOT/scripts/phase-ml-attach.sh" "$2"
    ;;
  help|-h|--help) usage ;;
  *) echo "Unknown phase: $COMMAND" >&2; usage; exit 2 ;;
esac
