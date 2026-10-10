#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
DIAG="$ROOT/scripts/join-signer-diagnostic.sh"
RECORDER="$ROOT/scripts/record-join-canary-transport-failure.sh"
SIGNER_RECORDER="$ROOT/scripts/record-join-signer-boundary-failure.sh"

# Contract: bounded, phase-owned signer diagnostic with closed vocabularies.
valid() {
  jq -n --arg run "$1" --arg last "$2" --arg failed "$3" --arg stage "$4" \
    '{schema_version:1,kind:"gdc-join-signer-diagnostic",run_id:$run,node_name:"node9",phase:"join-node9",
      last_completed_checkpoint:$last,failed_checkpoint:$failed,error_class:"transport",
      exit_code:255,attempt_count:1,mutation_state:"staging_only",signer_readback:"disabled",
      transport_stage:$stage,transport_result:"connection_reset",
      created_at:"2026-10-02T21:03:00Z",summary:"The signerless synchronization canary stopped before any signer change.",
      recovery:{decision:"safe",token:"join-repeat"}}'
}

write_receipt() {
  "$DIAG" write "$1" "${2:-fixture-run-1}" node9 join-node9 deployment_installed canary_running transport 255 1 \
    staging_only disabled canary_image_pull connection_reset safe join-repeat \
    'The signerless synchronization canary stopped at transport stage canary_image_pull before any signer change.'
}

receipt="$tmp/receipt.json"
write_receipt "$receipt"
[[ "$(stat -c %a "$receipt")" == 600 ]]
"$DIAG" validate "$receipt"

# Hostile fixtures must be refused.
chmod 644 "$receipt"
if "$DIAG" validate "$receipt" 2>/dev/null; then
  echo 'a world-readable diagnostic was accepted' >&2; exit 1
fi
chmod 600 "$receipt"
ln -s "$receipt" "$tmp/link.json"
if "$DIAG" validate "$tmp/link.json" 2>/dev/null; then
  echo 'a symlinked diagnostic was accepted' >&2; exit 1
fi
for mutation in \
  '.error_class = "weird"' \
  '.transport_stage = "undefined_stage"' \
  '.mutation_state = "canonical_signer_on"' \
  '.signer_readback = "enabled_by_operator"' \
  '.exit_code = 0' \
  '.attempt_count = 0' \
  '.recovery.token = "resume-same-run"' \
  '.summary = "with\u000acontrol"' \
  '.extra_key = true' \
  '.failed_checkpoint = "made_up_checkpoint"' \
  '.run_id = "../escape"'; do
  valid fixture-run-1 deployment_installed canary_running canary_image_pull | jq "$mutation" >"$tmp/bad.json"
  chmod 600 "$tmp/bad.json"
  if "$DIAG" validate "$tmp/bad.json" 2>/dev/null; then
    echo "hostile diagnostic variant was accepted: $mutation" >&2; exit 1
  fi
done
# Summary bound.
valid fixture-run-1 deployment_installed canary_running canary_image_pull \
  | jq '.summary = ([range(300)] | map("a") | join(""))' >"$tmp/long.json"
chmod 600 "$tmp/long.json"
if "$DIAG" validate "$tmp/long.json" 2>/dev/null; then
  echo 'an oversized diagnostic summary was accepted' >&2; exit 1
fi
# Decision/token pairing.
valid fixture-run-1 deployment_installed canary_running canary_image_pull \
  | jq '.recovery = {decision:"manual_action_required",token:"join-repeat"}' >"$tmp/pair.json"
chmod 600 "$tmp/pair.json"
if "$DIAG" validate "$tmp/pair.json" 2>/dev/null; then
  echo 'a mismatched recovery decision/token pair was accepted' >&2; exit 1
fi

# Exercise the failure recorder itself: a transport command that fails with a
# connection reset must retain the diagnostic, the envelope, the terminal
# result and a verdict, and replay the captured stderr.
run="$tmp/run/join-node9"
mkdir -p "$run"
stderr_fixture="$tmp/transport.stderr"
printf 'ssh: connect to host node9 port 22: Connection reset by peer\n' >"$stderr_fixture"
"$RECORDER" --run "$run" --run-id fixture-run-9 --node node9 \
  --last-checkpoint deployment_installed --failed-checkpoint canary_running \
  --stage canary_image_pull --exit-code 255 --profile-sha "$(printf '%064d' 7)" \
  --stderr-file "$stderr_fixture" --result-output "$run/join-result.v1.json" \
  >"$tmp/record.out" 2>"$tmp/record.err"
"$DIAG" validate "$run/signer-diagnostic.v1.json"
"$ROOT/scripts/diagnostic-envelope.sh" validate "$run/diagnostic-envelope.v1.json"
"$ROOT/scripts/record-join-result.sh" --validate "$run/join-result.v1.json"
jq -e '
  .error_class == "transport" and .transport_result == "connection_reset" and
  .transport_stage == "canary_image_pull" and
  .last_completed_checkpoint == "deployment_installed" and
  .failed_checkpoint == "canary_running" and
  .mutation_state == "staging_only" and .signer_readback == "disabled" and
  .recovery.decision == "safe" and .recovery.token == "join-repeat" and
  .exit_code == 255 and .run_id == "fixture-run-9" and .node_name == "node9"
' "$run/signer-diagnostic.v1.json" >/dev/null
jq -e '
  .outcome == "failed" and .phase == "state_sync" and .category == "state_sync" and
  .reason == "join_canary_transport_failed" and .exit_code == 255 and
  .mutation == "staging_only" and .signer_state == "disabled" and .resume == "new_profile" and
  .join_profile_sha256 == "0000000000000000000000000000000000000000000000000000000000000007"
' "$run/join-result.v1.json" >/dev/null
jq -e '
  .command_family == "join" and .phase == "join-node9" and
  .checkpoint == "canary_image_pull" and .state == "failed" and
  .category == "network" and .tool == "ssh-transport" and .exit_code == 255 and
  .resume.decision == "safe" and .resume.token == "join-repeat"
' "$run/diagnostic-envelope.v1.json" >/dev/null
[[ "$(head -n1 "$run/verdict.md")" == '# Host JOIN: FAILED' ]]
jq -e --arg raw 'Connection reset by peer' --arg local "$tmp" '
  ([.. | strings] | join(" ") | contains($raw) | not) and
  ([.. | strings] | join(" ") | contains($local) | not)
' "$run/signer-diagnostic.v1.json" "$run/diagnostic-envelope.v1.json" "$run/join-result.v1.json" >/dev/null

# A timeout stderr classifies as timeout, not connection reset.
stderr_timeout="$tmp/transport-timeout.stderr"
printf 'ssh: connect to host node9 port 22: Operation timed out\n' >"$stderr_timeout"
"$RECORDER" --run "$run" --run-id fixture-run-9 --node node9 \
  --last-checkpoint canary_running --failed-checkpoint canary_caught_up \
  --stage canary_wait --exit-code 255 --profile-sha "$(printf '%064d' 7)" \
  --stderr-file "$stderr_timeout" --result-output "$run/join-result2.v1.json" >/dev/null 2>&1
jq -e '.transport_result == "timeout" and .transport_stage == "canary_wait" and
  .last_completed_checkpoint == "canary_running" and .failed_checkpoint == "canary_caught_up"' \
  "$run/signer-diagnostic.v1.json" >/dev/null

# A post-enable readback timeout is deliberately not retryable. Its receipt
# names the boundary without copying stderr and preserves the existing
# automatic-retry fence in the terminal result.
signer_stderr="$tmp/signer-readback.stderr"
printf 'ssh: connect to host node9 port 22: Operation timed out\n' >"$signer_stderr"
"$SIGNER_RECORDER" --run "$run" --run-id fixture-run-9 --node node9 \
  --last-checkpoint signer_activating --failed-checkpoint signer_enabled \
  --stage signer_active_readback --error-class readback --exit-code 1 \
  --mutation signer_may_be_on --signer-readback unavailable --profile-sha "$(printf '%064d' 7)" \
  --stderr-file "$signer_stderr" --result-output "$run/signer-readback-result.v1.json"
"$DIAG" validate "$run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "signer_activating" and .failed_checkpoint == "signer_enabled" and
  .error_class == "readback" and .transport_stage == "signer_active_readback" and
  .transport_result == "timeout" and .mutation_state == "signer_may_be_on" and
  .signer_readback == "unavailable" and .recovery.decision == "manual_action_required" and
  .recovery.token == "none"
' "$run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$run/signer-readback-result.v1.json"
jq -e '
  .outcome == "manual_recovery_required" and .phase == "signer" and
  .reason == "signer_boundary_readback_required" and .mutation == "signer_may_be_on" and
  .signer_state == "unknown" and .resume == "automatic_retry_forbidden"
' "$run/signer-readback-result.v1.json" >/dev/null

# A successful liveness readback with the wrong validator key is more
# specific: the signer is on, but it is not the expected signer. It remains a
# manual recovery state and must never become a repeatable JOIN.
"$SIGNER_RECORDER" --run "$run" --run-id fixture-run-9 --node node9 \
  --last-checkpoint signer_activating --failed-checkpoint signer_enabled \
  --stage signer_identity_readback --error-class readback --exit-code 1 \
  --mutation signer_enabled --signer-readback enabled --profile-sha "$(printf '%064d' 7)" \
  --result-output "$run/signer-identity-result.v1.json"
jq -e '
  .transport_stage == "signer_identity_readback" and .error_class == "readback" and
  .mutation_state == "signer_enabled" and .signer_readback == "enabled" and
  .transport_result == "unavailable" and .recovery.decision == "manual_action_required"
' "$run/signer-diagnostic.v1.json" >/dev/null
jq -e '
  .mutation == "signer_may_be_on" and .signer_state == "enabled" and
  .resume == "automatic_retry_forbidden"
' "$run/signer-identity-result.v1.json" >/dev/null

# Exercise the production phase wrappers, not only their recorder. The phase
# imports this library before it reaches the signerless canary. A simulated
# transport reset and signer-enable timeout must therefore produce the same
# phase-owned receipts before a launcher could substitute its generic result.
phase_run="$tmp/phase-run/join-node-phase"
mkdir -p "$phase_run"
# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
RUN="$phase_run"
# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
# shellcheck disable=SC2100 # fixture identifiers intentionally contain a hyphen.
NODE=node-phase
# shellcheck disable=SC2100 # fixture identifiers intentionally contain a hyphen.
GDC_RUN_ID=phase-wrapper-run
# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
join_profile_sha256="$(printf '%064d' 8)"
export GDC_RUN_ID
# shellcheck source=/dev/null # this is the production module under test.
source "$ROOT/scripts/lib-join-diagnostics.sh"

fixture_connection_reset() {
  printf 'scp: Connection reset by peer\n' >&2
  return 255
}

fixture_enable_timeout() {
  printf 'ssh: connect to host node-phase port 22: Operation timed out\n' >&2
  return 255
}

fixture_local_failure() {
  printf 'unexpected local command failure\n' >&2
  return 1
}

GDC_JOIN_RESULT_OUTPUT="$phase_run/canary-result.v1.json"
set +e
join_canary_reached deployment_installed
join_canary_transport_step canary_lineage_transfer canary_verified fixture_connection_reset
phase_canary_rc=$?
set -e
[[ "$phase_canary_rc" == 255 ]]
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "deployment_installed" and
  .failed_checkpoint == "canary_verified" and
  .transport_stage == "canary_lineage_transfer" and
  .transport_result == "connection_reset" and
  .mutation_state == "staging_only" and .signer_readback == "disabled" and
  .recovery == {decision:"safe",token:"join-repeat"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/canary-result.v1.json"
jq -e '.reason == "join_canary_transport_failed" and .mutation == "staging_only" and .resume == "new_profile"' \
  "$phase_run/canary-result.v1.json" >/dev/null

# An SSH timeout before signer activation is still a safe, staging-only
# canary failure. Test the production wrapper rather than its classifier.
# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
GDC_JOIN_RESULT_OUTPUT="$phase_run/canary-timeout-result.v1.json"
set +e
join_canary_reached canary_running
join_canary_transport_step canary_wait canary_caught_up fixture_enable_timeout
phase_canary_timeout_rc=$?
set -e
[[ "$phase_canary_timeout_rc" == 255 ]]
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "canary_running" and
  .failed_checkpoint == "canary_caught_up" and .transport_stage == "canary_wait" and
  .transport_result == "timeout" and .mutation_state == "staging_only" and
  .recovery == {decision:"safe",token:"join-repeat"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/canary-timeout-result.v1.json"
jq -e '.reason == "join_canary_transport_failed" and .mutation == "staging_only" and
  .resume == "new_profile"' "$phase_run/canary-timeout-result.v1.json" >/dev/null

# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
GDC_JOIN_RESULT_OUTPUT="$phase_run/signer-enable-result.v1.json"
set +e
join_canary_reached signer_activating
join_signer_boundary_step signer_enable signer_enabled signer signer_may_be_on unknown fixture_enable_timeout
phase_signer_rc=$?
set -e
[[ "$phase_signer_rc" == 255 ]]
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "signer_activating" and
  .failed_checkpoint == "signer_enabled" and
  .error_class == "signer" and .transport_stage == "signer_enable" and
  .transport_result == "timeout" and .mutation_state == "signer_may_be_on" and
  .signer_readback == "unknown" and
  .recovery == {decision:"manual_action_required",token:"none"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/signer-enable-result.v1.json"
jq -e '.outcome == "manual_recovery_required" and .mutation == "signer_may_be_on" and
  .signer_state == "unknown" and .resume == "automatic_retry_forbidden"' \
  "$phase_run/signer-enable-result.v1.json" >/dev/null

# A non-transport command failure has no affirmative signer readback either;
# it must remain a manual recovery boundary rather than being retried.
# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
GDC_JOIN_RESULT_OUTPUT="$phase_run/signer-enable-local-result.v1.json"
set +e
join_canary_reached signer_activating
join_signer_boundary_step signer_enable signer_enabled signer signer_may_be_on unknown fixture_local_failure
phase_signer_local_rc=$?
set -e
[[ "$phase_signer_local_rc" == 1 ]]
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "signer_activating" and
  .failed_checkpoint == "signer_enabled" and .error_class == "signer" and
  .transport_stage == "signer_enable" and .transport_result == "command_failed" and
  .mutation_state == "signer_may_be_on" and .signer_readback == "unknown" and
  .recovery == {decision:"manual_action_required",token:"none"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/signer-enable-local-result.v1.json"
jq -e '.outcome == "manual_recovery_required" and .mutation == "signer_may_be_on" and
  .signer_state == "unknown" and .resume == "automatic_retry_forbidden"' \
  "$phase_run/signer-enable-local-result.v1.json" >/dev/null

# Fence and pre-enable capture have distinct evidence: the first proves the
# canonical signer-off action had begun, while the second is ambiguous after
# the fence and must retain the more conservative mutation state.
GDC_JOIN_RESULT_OUTPUT="$phase_run/signer-fence-result.v1.json"
set +e
join_canary_reached canonical_verified
join_signer_boundary_step signer_fence signer_fenced signer canonical_signer_off fenced fixture_connection_reset
phase_fence_rc=$?
set -e
[[ "$phase_fence_rc" == 255 ]]
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "canonical_verified" and
  .failed_checkpoint == "signer_fenced" and .transport_stage == "signer_fence" and
  .mutation_state == "canonical_signer_off" and .signer_readback == "fenced" and
  .transport_result == "connection_reset" and .recovery == {decision:"manual_action_required",token:"none"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/signer-fence-result.v1.json"
jq -e '.mutation == "canonical_signer_off" and .signer_state == "fenced" and
  .resume == "automatic_retry_forbidden"' "$phase_run/signer-fence-result.v1.json" >/dev/null

# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
GDC_JOIN_RESULT_OUTPUT="$phase_run/pre-enable-result.v1.json"
set +e
join_canary_reached signer_fenced
join_signer_boundary_step signer_pre_enable_state signer_activating readback signer_may_be_on unavailable fixture_enable_timeout
phase_pre_enable_rc=$?
set -e
[[ "$phase_pre_enable_rc" == 255 ]]
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "signer_fenced" and
  .failed_checkpoint == "signer_activating" and .transport_stage == "signer_pre_enable_state" and
  .error_class == "readback" and .mutation_state == "signer_may_be_on" and
  .signer_readback == "unavailable" and .transport_result == "timeout" and
  .recovery == {decision:"manual_action_required",token:"none"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/pre-enable-result.v1.json"
jq -e '.mutation == "signer_may_be_on" and .signer_state == "unknown" and
  .resume == "automatic_retry_forbidden"' "$phase_run/pre-enable-result.v1.json" >/dev/null

# Post-enable branches are not command wrappers: the first records retry
# exhaustion while waiting for Core RPC, and the second records a live but
# wrong validator key. They use the same production library as phase-join.
post_enable_stderr="$tmp/post-enable.stderr"
printf 'ssh: connect to host node-phase port 22: Operation timed out\n' >"$post_enable_stderr"
# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
GDC_JOIN_RESULT_OUTPUT="$phase_run/post-enable-timeout-result.v1.json"
record_post_enable_signer_failure signer_active_readback readback signer_may_be_on unavailable "$post_enable_stderr"
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .transport_stage == "signer_active_readback" and .error_class == "readback" and
  .transport_result == "timeout" and .mutation_state == "signer_may_be_on" and
  .signer_readback == "unavailable" and .recovery == {decision:"manual_action_required",token:"none"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/post-enable-timeout-result.v1.json"
jq -e '.signer_state == "unknown" and .resume == "automatic_retry_forbidden"' \
  "$phase_run/post-enable-timeout-result.v1.json" >/dev/null

# shellcheck disable=SC2034 # consumed by the sourced production boundary library.
GDC_JOIN_RESULT_OUTPUT="$phase_run/post-enable-identity-result.v1.json"
record_post_enable_signer_failure signer_identity_readback readback signer_enabled enabled
"$DIAG" validate "$phase_run/signer-diagnostic.v1.json"
jq -e '
  .transport_stage == "signer_identity_readback" and .transport_result == "unavailable" and
  .mutation_state == "signer_enabled" and .signer_readback == "enabled" and
  .recovery == {decision:"manual_action_required",token:"none"}
' "$phase_run/signer-diagnostic.v1.json" >/dev/null
"$ROOT/scripts/record-join-result.sh" --validate "$phase_run/post-enable-identity-result.v1.json"
jq -e '.mutation == "signer_may_be_on" and .signer_state == "enabled" and
  .resume == "automatic_retry_forbidden"' "$phase_run/post-enable-identity-result.v1.json" >/dev/null

# An unexpected shell exit after the fence is not evidence that the signer
# stayed off. The phase-owned EXIT trap must retain an explicit unknown
# boundary before the generic diagnostic adapter records the verdict.
trap_run="$tmp/trap-run/join-node-trap"
mkdir -p "$trap_run"
set +e
(
  source "$ROOT/scripts/lib.sh"
  # shellcheck source=/dev/null # production JOIN diagnostic boundary under test.
  source "$ROOT/scripts/lib-join-diagnostics.sh"
  # shellcheck disable=SC2034 # consumed by the sourced production boundary library.
  RUN="$trap_run"
  # shellcheck disable=SC2034,SC2100 # consumed by the sourced production boundary library.
  NODE=node-trap
  # shellcheck disable=SC2034,SC2100 # consumed by the sourced production boundary library.
  GDC_RUN_ID=phase-trap-run
  # shellcheck disable=SC2034 # consumed by the sourced production boundary library.
  GDC_JOIN_RESULT_OUTPUT="$trap_run/trap-result.v1.json"
  # shellcheck disable=SC2034 # consumed by the sourced production boundary library.
  join_profile_sha256="$(printf '%064d' 9)"
  join_canary_reached signer_fenced
  install_join_signer_boundary_exit_trap
  exit 77
)
phase_trap_rc=$?
set -e
[[ "$phase_trap_rc" == 77 ]]
"$DIAG" validate "$trap_run/signer-diagnostic.v1.json"
jq -e '
  .last_completed_checkpoint == "signer_fenced" and .failed_checkpoint == "unknown" and
  .error_class == "unknown" and .transport_stage == "unavailable" and
  .transport_result == "unavailable" and .mutation_state == "signer_may_be_on" and
  .signer_readback == "unknown" and .recovery == {decision:"manual_action_required",token:"none"}
' "$trap_run/signer-diagnostic.v1.json" >/dev/null
# shellcheck disable=SC2031 # lib.sh is intentionally sourced in the isolated trap subprocess.
"$ROOT/scripts/record-join-result.sh" --validate "$trap_run/trap-result.v1.json"
jq -e '.outcome == "manual_recovery_required" and .mutation == "signer_may_be_on" and
  .signer_state == "unknown" and .resume == "automatic_retry_forbidden"' \
  "$trap_run/trap-result.v1.json" >/dev/null
[[ -s "$trap_run/verdict.md" ]]

printf 'test-join-signer-diagnostic: PASS\n'
