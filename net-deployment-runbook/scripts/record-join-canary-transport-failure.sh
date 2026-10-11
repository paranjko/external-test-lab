#!/usr/bin/env bash
# Persist closed, safe diagnostics for a failure during the signerless JOIN
# canary. Raw transport output is deliberately replayed by phase-join only;
# it is not copied into any structured record consumed by reports.
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --run DIR --run-id ID --node NAME --last-checkpoint TOKEN --failed-checkpoint TOKEN --stage TOKEN --exit-code N --profile-sha SHA256_OR_EMPTY --stderr-file FILE [--result-output FILE]" >&2
}

RUN=''; RUN_ID=''; NODE=''; LAST=''; FAILED=''; STAGE=''; EXIT_CODE=''; PROFILE_SHA=''; STDERR_FILE=''; RESULT_OUTPUT=''
while (($#)); do
  case "$1" in
    --run|--run-id|--node|--last-checkpoint|--failed-checkpoint|--stage|--exit-code|--profile-sha|--stderr-file|--result-output)
      [[ -n "${2:-}" ]] || { usage; exit 2; }
      case "$1" in
        --run) RUN="$2" ;; --run-id) RUN_ID="$2" ;; --node) NODE="$2" ;;
        --last-checkpoint) LAST="$2" ;; --failed-checkpoint) FAILED="$2" ;;
        --stage) STAGE="$2" ;; --exit-code) EXIT_CODE="$2" ;;
        --profile-sha) PROFILE_SHA="$2" ;; --stderr-file) STDERR_FILE="$2" ;;
        --result-output) RESULT_OUTPUT="$2" ;;
      esac
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$RUN" && -n "$RUN_ID" && -n "$NODE" && -n "$LAST" && -n "$FAILED" && -n "$STAGE" && -n "$EXIT_CODE" && -n "$STDERR_FILE" ]] || { usage; exit 2; }
[[ -d "$RUN" && -f "$STDERR_FILE" && ! -L "$STDERR_FILE" ]] || { echo 'ERROR JOIN canary transport diagnostic requires a safe run directory and stderr file' >&2; exit 2; }
[[ "$EXIT_CODE" =~ ^[1-9][0-9]*$ && "$EXIT_CODE" -le 255 ]] || { echo 'ERROR JOIN canary transport diagnostic requires exit code 1..255' >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

transport="$(awk '
  BEGIN { IGNORECASE=1; result="command_failed" }
  /connection reset by peer|connection refused|broken pipe/ { result="connection_reset"; exit }
  /timed?[ _]?out|timeout/ { result="timeout"; exit }
  /permission denied|authentication/ { result="auth_failed"; exit }
  END { print result }
' "$STDERR_FILE")"
# Normalize the closed vocabulary after collection rather than letting
# untrusted stderr affect a token directly.
case "$transport" in connection_reset|timeout|auth_failed) ;; *) transport=command_failed ;; esac
summary="The signerless synchronization canary stopped at transport stage $STAGE before any signer change."

"$ROOT/scripts/join-signer-diagnostic.sh" write "$RUN/signer-diagnostic.v1.json" \
  "$RUN_ID" "$NODE" "join-$NODE" "$LAST" "$FAILED" transport "$EXIT_CODE" 1 \
  staging_only disabled "$STAGE" "$transport" safe join-repeat "$summary"
"$ROOT/scripts/diagnostic-envelope.sh" write "$RUN/diagnostic-envelope.v1.json" \
  join "join-$NODE" "$STAGE" failed network ssh-transport "$EXIT_CODE" safe join-repeat "$summary"

if [[ -n "$RESULT_OUTPUT" ]]; then
  input="$(mktemp "$RUN/.canary-result.XXXXXX")"
  chmod 600 "$input"
  jq -cn --argjson exit_code "$EXIT_CODE" --arg profile "$PROFILE_SHA" \
    '{schema_version:1,kind:"gdc-host-join-result",outcome:"failed",phase:"state_sync",category:"state_sync",
      reason:"join_canary_transport_failed",exit_code:$exit_code,mutation:"staging_only",signer_state:"disabled",
      resume:"new_profile",join_profile_sha256:(if $profile == "" then null else $profile end),evidence:[]}' >"$input"
  "$ROOT/scripts/record-join-result.sh" --output "$RESULT_OUTPUT" --input "$input"
  rm -f "$input"
fi
printf '# Host JOIN: FAILED\n\n%s\n' "$summary" >"$RUN/verdict.md"
