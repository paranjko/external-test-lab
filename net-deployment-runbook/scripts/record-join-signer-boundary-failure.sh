#!/usr/bin/env bash
# Retain a closed, phase-owned record when JOIN cannot prove signer state at a
# fence, enable, or post-enable readback boundary. This helper never retries
# or reads a remote Host itself; the receipt directs the existing read-only
# signer-state resume path.
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --run DIR --run-id ID --node NAME --last-checkpoint TOKEN --failed-checkpoint TOKEN --stage TOKEN --error-class TOKEN --exit-code N --mutation TOKEN --signer-readback TOKEN --profile-sha SHA256_OR_EMPTY [--stderr-file FILE] [--result-output FILE]" >&2
}

RUN=''; RUN_ID=''; NODE=''; LAST=''; FAILED=''; STAGE=''; ERROR_CLASS=''; EXIT_CODE=''; MUTATION=''; READBACK=''; PROFILE_SHA=''; STDERR_FILE=''; RESULT_OUTPUT=''
while (($#)); do
  case "$1" in
    --run|--run-id|--node|--last-checkpoint|--failed-checkpoint|--stage|--error-class|--exit-code|--mutation|--signer-readback|--profile-sha|--stderr-file|--result-output)
      [[ -n "${2:-}" ]] || { usage; exit 2; }
      case "$1" in
        --run) RUN="$2" ;; --run-id) RUN_ID="$2" ;; --node) NODE="$2" ;;
        --last-checkpoint) LAST="$2" ;; --failed-checkpoint) FAILED="$2" ;;
        --stage) STAGE="$2" ;; --error-class) ERROR_CLASS="$2" ;; --exit-code) EXIT_CODE="$2" ;;
        --mutation) MUTATION="$2" ;; --signer-readback) READBACK="$2" ;; --profile-sha) PROFILE_SHA="$2" ;;
        --stderr-file) STDERR_FILE="$2" ;; --result-output) RESULT_OUTPUT="$2" ;;
      esac
      shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$RUN_ID" && -n "$NODE" && -n "$LAST" && -n "$FAILED" && -n "$STAGE" && -n "$ERROR_CLASS" && -n "$EXIT_CODE" && -n "$MUTATION" && -n "$READBACK" ]] || { usage; exit 2; }
[[ -d "$RUN" ]] || { echo 'ERROR JOIN signer boundary diagnostic requires a safe run directory' >&2; exit 2; }
[[ -z "$STDERR_FILE" || ( -f "$STDERR_FILE" && ! -L "$STDERR_FILE" ) ]] || { echo 'ERROR JOIN signer boundary diagnostic requires a regular stderr file' >&2; exit 2; }
[[ "$EXIT_CODE" =~ ^[1-9][0-9]*$ && "$EXIT_CODE" -le 255 ]] || { echo 'ERROR JOIN signer boundary diagnostic requires exit code 1..255' >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

transport=unavailable
if [[ -n "$STDERR_FILE" ]]; then
  transport="$(awk '
    BEGIN { IGNORECASE=1; result="command_failed" }
    /connection reset by peer|connection refused|broken pipe/ { result="connection_reset"; exit }
    /timed?[ _]?out|timeout/ { result="timeout"; exit }
    /permission denied|authentication/ { result="auth_failed"; exit }
    END { print result }
  ' "$STDERR_FILE")"
fi
case "$transport" in connection_reset|timeout|auth_failed|command_failed|unavailable) ;; *) transport=unavailable ;; esac
summary="JOIN could not prove signer state at boundary $STAGE; use the read-only signer-state recovery path before any retry."
"$ROOT/scripts/join-signer-diagnostic.sh" write "$RUN/signer-diagnostic.v1.json" \
  "$RUN_ID" "$NODE" "join-$NODE" "$LAST" "$FAILED" "$ERROR_CLASS" "$EXIT_CODE" 1 \
  "$MUTATION" "$READBACK" "$STAGE" "$transport" manual_action_required none "$summary"
"$ROOT/scripts/diagnostic-envelope.sh" write "$RUN/diagnostic-envelope.v1.json" \
  join "join-$NODE" "$STAGE" failed unknown signer-boundary "$EXIT_CODE" manual_action_required none "$summary"
if [[ -n "$RESULT_OUTPUT" ]]; then
  input="$(mktemp "$RUN/.signer-boundary-result.XXXXXX")"
  chmod 600 "$input"
  case "$READBACK" in unavailable) terminal_signer=unknown ;; *) terminal_signer="$READBACK" ;; esac
  # Terminal-result v1 retains only conservative mutation states. The richer
  # signer receipt can prove `signer_enabled`; its terminal companion still
  # uses signer_may_be_on to preserve the no-automatic-retry invariant.
  case "$MUTATION" in signer_enabled) terminal_mutation=signer_may_be_on ;; *) terminal_mutation="$MUTATION" ;; esac
  jq -cn --argjson exit_code "$EXIT_CODE" --arg profile "$PROFILE_SHA" --arg mutation "$terminal_mutation" --arg signer "$terminal_signer" \
    '{schema_version:1,kind:"gdc-host-join-result",outcome:"manual_recovery_required",phase:"signer",category:"signer",
      reason:"signer_boundary_readback_required",exit_code:$exit_code,mutation:$mutation,signer_state:$signer,
      resume:"automatic_retry_forbidden",join_profile_sha256:(if $profile == "" then null else $profile end),evidence:[]}' >"$input"
  "$ROOT/scripts/record-join-result.sh" --output "$RESULT_OUTPUT" --input "$input"
  rm -f "$input"
fi
printf '# Host JOIN: OPERATOR ACTION REQUIRED\n\n%s\n' "$summary" >"$RUN/verdict.md"
