#!/usr/bin/env bash
# Bounded, phase-owned signer diagnostic for a JOIN stop at or after the
# signerless canary boundary. Like the diagnostic envelope, it deliberately
# stores closed-vocabulary tokens only: no paths, command lines, raw stderr,
# credentials, or arbitrary operator input.
set -Eeuo pipefail

MAX_TEXT=240
readonly CHECKPOINT_PATTERN='^(run_created|bootstrap_verified|network_observed|join_profile_ready|target_classified|host_base_prepared|qualification_completed|identity_ready|candidate_rendered|deployment_installed|canary_running|canary_caught_up|canary_verified|canary_stopped|promotion_prepared|promoted|canonical_running|application_active|canonical_verified|signer_fenced|signer_activating|signer_enabled|complete|unknown)$'
readonly ERROR_CLASS_PATTERN='^(transport|local_command|timeout|signer|readback|unknown)$'
readonly MUTATION_PATTERN='^(none|staging_only|canonical_signer_off|signer_may_be_on|signer_enabled)$'
readonly READBACK_PATTERN='^(absent|fenced|disabled|enabled|unavailable|unknown)$'
readonly STAGE_PATTERN='^(canary_image_pull|canary_env_transfer|canary_lineage_transfer|canary_start|canary_verify|canary_wait|canary_stop|promotion_transfer|signer_fence|signer_pre_enable_state|signer_enable|signer_active_readback|signer_identity_readback|unavailable)$'
readonly TRANSPORT_PATTERN='^(connection_reset|timeout|auth_failed|command_failed|unavailable)$'
readonly DECISION_PATTERN='^(safe|manual_action_required|unsafe|not_applicable)$'
readonly TOKEN_PATTERN='^(none|join-repeat)$'

die() { printf 'ERROR join signer diagnostic: %s\n' "$*" >&2; exit 1; }
valid_text() {
  [[ ${#1} -le $MAX_TEXT && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]] \
    && [[ "$1" =~ ^[[:print:]]*$ ]]
}

validate() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" && $(stat -c '%a' "$file") == 600 ]] || die 'diagnostic must be a regular mode-0600 file'
  [[ $(wc -c <"$file") -le 8192 ]] || die 'diagnostic exceeds 8192 bytes'
  jq -e '
    type == "object" and
    (keys | sort) == ["attempt_count","created_at","error_class","exit_code","failed_checkpoint","kind","last_completed_checkpoint","mutation_state","node_name","phase","recovery","run_id","schema_version","signer_readback","summary","transport_result","transport_stage"] and
    .schema_version == 1 and
    .kind == "gdc-join-signer-diagnostic" and
    (.run_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.node_name | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.phase | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.last_completed_checkpoint | test("'"$CHECKPOINT_PATTERN"'")) and
    (.failed_checkpoint | test("'"$CHECKPOINT_PATTERN"'")) and
    (.error_class | test("'"$ERROR_CLASS_PATTERN"'")) and
    (.exit_code | type == "number" and . >= 1 and . <= 255) and
    (.attempt_count | type == "number" and . >= 1 and . <= 999) and
    (.mutation_state | test("'"$MUTATION_PATTERN"'")) and
    (.signer_readback | test("'"$READBACK_PATTERN"'")) and
    (.transport_stage | test("'"$STAGE_PATTERN"'")) and
    (.transport_result | test("'"$TRANSPORT_PATTERN"'")) and
    (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and
    (.summary | type == "string" and length <= 240 and test("^[[:print:]]*$")) and
    (.recovery | type == "object" and (keys | sort) == ["decision","token"] and
      (.decision | test("'"$DECISION_PATTERN"'")) and
      (.token | test("'"$TOKEN_PATTERN"'")) and
      ((.decision == "safe") == (.token == "join-repeat")))
  ' "$file" >/dev/null || die 'diagnostic does not match gdc-join-signer-diagnostic.v1'
}

write() {
  local output="$1" run_id="$2" node="$3" phase="$4" last_completed="$5" failed="$6" error_class="$7" \
    exit_code="$8" attempts="$9" mutation="${10}" readback="${11}" stage="${12}" transport="${13}" \
    decision="${14}" token="${15}" summary="${16}" tmp
  [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die 'unsafe run or node identifier'
  valid_token_phase "$phase" || die 'unsafe phase'
  [[ "$last_completed" =~ $CHECKPOINT_PATTERN && "$failed" =~ $CHECKPOINT_PATTERN ]] || die 'unsafe checkpoint'
  [[ "$error_class" =~ $ERROR_CLASS_PATTERN ]] || die 'unsupported error class'
  [[ "$exit_code" =~ ^[1-9][0-9]*$ && "$exit_code" -le 255 ]] || die 'unsafe exit code'
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$attempts" -le 999 ]] || die 'unsafe attempt count'
  [[ "$mutation" =~ $MUTATION_PATTERN && "$readback" =~ $READBACK_PATTERN ]] || die 'unsafe mutation or signer readback'
  [[ "$stage" =~ $STAGE_PATTERN && "$transport" =~ $TRANSPORT_PATTERN ]] || die 'unsafe transport stage or result'
  [[ "$decision" =~ $DECISION_PATTERN && "$token" =~ $TOKEN_PATTERN ]] || die 'unsupported recovery decision'
  [[ "$decision" == safe && "$token" == join-repeat || "$decision" != safe && "$token" == none ]] || die 'unsafe recovery token'
  valid_text "$summary" || die 'unsafe summary'
  mkdir -p "$(dirname "$output")"
  tmp="$(mktemp "$(dirname "$output")/.join-signer-diagnostic.XXXXXX")"
  jq -n --arg run_id "$run_id" --arg node "$node" --arg phase "$phase" \
    --arg last_completed "$last_completed" --arg failed "$failed" --arg error_class "$error_class" \
    --argjson exit_code "$exit_code" --argjson attempts "$attempts" \
    --arg mutation "$mutation" --arg readback "$readback" --arg stage "$stage" --arg transport "$transport" \
    --arg decision "$decision" --arg token "$token" --arg summary "$summary" \
    '{schema_version:1,kind:"gdc-join-signer-diagnostic",run_id:$run_id,node_name:$node,phase:$phase,
      last_completed_checkpoint:$last_completed,failed_checkpoint:$failed,error_class:$error_class,
      exit_code:$exit_code,attempt_count:$attempts,mutation_state:$mutation,signer_readback:$readback,
      transport_stage:$stage,transport_result:$transport,
      created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),summary:$summary,
      recovery:{decision:$decision,token:$token}}' >"$tmp"
  chmod 0600 "$tmp"
  validate "$tmp"
  mv -f "$tmp" "$output"
  chmod 0600 "$output"
}

valid_token_phase() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

case "${1:-}" in
  validate) [[ $# -eq 2 ]] || die 'usage: validate FILE'; validate "$2" ;;
  write) [[ $# -eq 17 ]] || die 'usage: write OUTPUT RUN_ID NODE PHASE LAST_COMPLETED FAILED ERROR_CLASS EXIT_CODE ATTEMPTS MUTATION READBACK STAGE TRANSPORT DECISION TOKEN SUMMARY'; write "${@:2}" ;;
  *) die 'usage: join-signer-diagnostic.sh validate|write' ;;
esac
