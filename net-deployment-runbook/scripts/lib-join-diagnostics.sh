#!/usr/bin/env bash
# Failure boundaries shared by the Host JOIN phase and its behavioral tests.
# Callers provide ROOT, RUN, NODE, GDC_RUN_ID and join_profile_sha256.

# The signerless canary is the last boundary at which every failure remains
# safely repeatable with a fresh JOIN. Each transport command records where it
# stopped so a phase-owned signer diagnostic, not the launcher's generic
# placeholder, explains a stop in this window.
JOIN_LAST_CHECKPOINT=deployment_installed
JOIN_CANARY_STAGE=unavailable

join_canary_reached() {
  JOIN_LAST_CHECKPOINT="$1"
}

record_canary_transport_failure() {
  local rc="$1" pending="$2" stderr_file="$3"
  local -a diagnostic_args=(
    --run "$RUN" --run-id "${GDC_RUN_ID:-unknown}" --node "$NODE" \
    --last-checkpoint "$JOIN_LAST_CHECKPOINT" --failed-checkpoint "$pending" \
    --stage "$JOIN_CANARY_STAGE" --exit-code "$rc" --profile-sha "${join_profile_sha256:-}" \
    --stderr-file "$stderr_file"
  )
  [[ -z "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || diagnostic_args+=(--result-output "$GDC_JOIN_RESULT_OUTPUT")
  "$ROOT/scripts/record-join-canary-transport-failure.sh" "${diagnostic_args[@]}" \
    || printf 'ERROR JOIN canary transport diagnostic could not be retained\n' >&2
  export GDC_JOIN_SIGNER_DIAGNOSTIC="$RUN/signer-diagnostic.v1.json"
}

join_canary_transport_step() {
  local stage="$1" pending="$2" rc=0 stderr_file
  shift 2
  JOIN_CANARY_STAGE="$stage"
  stderr_file="$(mktemp "$RUN/.canary-transport-stderr.XXXXXX")"
  "$@" 2>"$stderr_file" || rc=$?
  if (( rc != 0 )); then
    cat "$stderr_file" >&2 || true
    record_canary_transport_failure "$rc" "$pending" "$stderr_file"
    rm -f "$stderr_file"
    return "$rc"
  fi
  rm -f "$stderr_file"
}

# Once the signer fence boundary begins, a failed command is not evidence that
# the signer stayed off. Retain a phase-owned diagnostic and terminal result
# before the launcher can fall back to its intentionally unclassified record.
join_signer_boundary_step() {
  local stage="$1" pending="$2" error_class="$3" mutation="$4" readback="$5" rc=0 stderr_file
  local -a diagnostic_args
  shift 5
  stderr_file="$(mktemp "$RUN/.signer-boundary-stderr.XXXXXX")"
  "$@" 2>"$stderr_file" || rc=$?
  if (( rc != 0 )); then
    cat "$stderr_file" >&2 || true
    diagnostic_args=(
      --run "$RUN" --run-id "${GDC_RUN_ID:-unknown}" --node "$NODE" \
      --last-checkpoint "$JOIN_LAST_CHECKPOINT" --failed-checkpoint "$pending" \
      --stage "$stage" --error-class "$error_class" --exit-code "$rc" \
      --mutation "$mutation" --signer-readback "$readback" --profile-sha "${join_profile_sha256:-}" \
      --stderr-file "$stderr_file"
    )
    [[ -z "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || diagnostic_args+=(--result-output "$GDC_JOIN_RESULT_OUTPUT")
    "$ROOT/scripts/record-join-signer-boundary-failure.sh" "${diagnostic_args[@]}" \
      || printf 'ERROR JOIN signer boundary diagnostic could not be retained\n' >&2
    export GDC_JOIN_SIGNER_DIAGNOSTIC="$RUN/signer-diagnostic.v1.json"
    rm -f "$stderr_file"
    return "$rc"
  fi
  rm -f "$stderr_file"
}

# Post-enable readback is outside the command wrapper because it may consist
# of a bounded retry loop or a successful RPC response whose validator key is
# nevertheless unexpected. Both outcomes remain non-retryable until a human
# performs the documented signer-state recovery readback.
record_post_enable_signer_failure() {
  local stage="$1" error_class="$2" mutation="$3" readback="$4" stderr_file="${5:-}"
  local -a diagnostic_args=(
    --run "$RUN" --run-id "${GDC_RUN_ID:-unknown}" --node "$NODE" \
    --last-checkpoint signer_activating --failed-checkpoint signer_enabled \
    --stage "$stage" --error-class "$error_class" --exit-code 1 \
    --mutation "$mutation" --signer-readback "$readback" --profile-sha "${join_profile_sha256:-}"
  )
  [[ -z "$stderr_file" ]] || diagnostic_args+=(--stderr-file "$stderr_file")
  [[ -z "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || diagnostic_args+=(--result-output "$GDC_JOIN_RESULT_OUTPUT")
  "$ROOT/scripts/record-join-signer-boundary-failure.sh" "${diagnostic_args[@]}" \
    || printf 'ERROR JOIN signer readback diagnostic could not be retained\n' >&2
  export GDC_JOIN_SIGNER_DIAGNOSTIC="$RUN/signer-diagnostic.v1.json"
}

# A shell-level failure after the signer fence cannot prove that the signer is
# still off. Preserve a phase-owned unknown boundary before the generic phase
# adapter writes its deliberately unclassified envelope. This handles normal
# shell exits and signals that run EXIT traps; SIGKILL remains unrecoverable by
# any local process and is intentionally not misrepresented as retained proof.
join_signer_boundary_exit_trap() {
  local rc=$?
  trap - EXIT
  set +e
  if (( rc != 0 )) \
    && [[ "$JOIN_LAST_CHECKPOINT" =~ ^(signer_fenced|signer_activating|signer_enabled)$ ]] \
    && [[ ! -e "$RUN/signer-diagnostic.v1.json" ]]; then
    "$ROOT/scripts/record-join-signer-boundary-failure.sh" \
      --run "$RUN" --run-id "${GDC_RUN_ID:-unknown}" --node "$NODE" \
      --last-checkpoint "$JOIN_LAST_CHECKPOINT" --failed-checkpoint unknown \
      --stage unavailable --error-class unknown --exit-code "$rc" \
      --mutation signer_may_be_on --signer-readback unknown --profile-sha "${join_profile_sha256:-}" \
      --result-output "${GDC_JOIN_RESULT_OUTPUT:-}" \
      || printf 'ERROR JOIN unclassified signer boundary diagnostic could not be retained\n' >&2
    export GDC_JOIN_SIGNER_DIAGNOSTIC="$RUN/signer-diagnostic.v1.json"
  fi
  evidence_exit_trap "$rc"
  exit "$rc"
}

install_join_signer_boundary_exit_trap() {
  trap join_signer_boundary_exit_trap EXIT
}
