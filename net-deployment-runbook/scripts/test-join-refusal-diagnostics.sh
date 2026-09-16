#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
PHASE="$ROOT/scripts/phase-join.sh"

# Every stop before the first Host change goes through the one refusal
# recorder; none of them dies into the launcher fallback any more.
grep -Fq 'refuse_before_mutation host_unreachable' "$PHASE"
grep -Fq 'refuse_before_mutation identity_conflict' "$PHASE"
[[ "$(grep -c 'refuse_before_mutation partial_identity' "$PHASE")" == 2 ]]
grep -Fq 'record_join_transition REFUSED' "$PHASE"
for stop in partial_identity identity_conflict unreachable; do
  if grep -Fq "die 'Host JOIN classification=$stop" "$PHASE"; then
    echo "classification=$stop still dies without a typed refusal" >&2
    exit 1
  fi
done
# The composed summaries name no path and stay within the envelope bound
# even when every local file is present.
if grep -F 'Host JOIN stopped before any change' "$PHASE" | grep -q '/'; then
  echo 'a refusal summary contains a path' >&2
  exit 1
fi

# shellcheck source=/dev/null
source <(sed -n '/^refuse_before_mutation()/,/^}/p' "$PHASE")

run_refusal() {
  local name="$1" reason="$2" summary="$3" message="$4" rc=0
  RUN="$tmp/$name/join-node-a"
  mkdir -p "$RUN"
  : >"$tmp/$name.transitions"
  # shellcheck disable=SC2034
  (
    NODE=node-a
    join_profile_sha256="$(printf '%064d' 7)"
    GDC_JOIN_RESULT_OUTPUT="$RUN/join-result.v1.json"
    die() { printf 'error: %s\n' "$*" >&2; exit 1; }
    record_join_transition() { printf '%s\n' "$1" >>"$tmp/$name.transitions"; }
    refuse_before_mutation "$reason" "$summary" "$message"
  ) >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fxq "error: $message" "$tmp/$name.err"
  grep -Fxq REFUSED "$tmp/$name.transitions"
  "$ROOT/scripts/diagnostic-envelope.sh" validate "$RUN/diagnostic-envelope.v1.json"
  [[ "$(stat -c %a "$RUN/join-result.v1.json")" == 600 ]]
  grep -Fxq '# Host JOIN: REFUSED' "$RUN/verdict.md"
  grep -Fxq "$summary" "$RUN/verdict.md"
  jq -e --arg summary "$summary" '
    .command_family == "join" and .phase == "join-node-a" and .checkpoint == "classification" and
    .state == "refused" and .tool == "classify-join-state" and .exit_code == 1 and .summary == $summary
  ' "$RUN/diagnostic-envelope.v1.json" >/dev/null
  jq -e --arg reason "$reason" '
    .schema_version == 1 and .kind == "gdc-host-join-result" and .outcome == "refused" and .phase == "identity" and
    .reason == $reason and .exit_code == 1 and .mutation == "none" and .signer_state == "absent" and
    .join_profile_sha256 == "0000000000000000000000000000000000000000000000000000000000000007" and .evidence == []
  ' "$RUN/join-result.v1.json" >/dev/null
}

local_state='identity record present, cold account present, joined marker present'
summary_partial="Host JOIN stopped before any change: $local_state; the Host holds no validator identity. Resolve the incomplete operator state through the documented recovery path."
summary_adopt="Host JOIN stopped before any change: $local_state; the Host holds a validator identity. Restore from the matching archive or follow the documented recovery path."
summary_conflict='Host JOIN stopped before any change: the Host holds a validator identity that the operator state does not know. Restore it from the matching validator archive or follow the documented recovery path.'
summary_unreachable='Host JOIN stopped before any change: the remote identity preflight could not open an SSH session to the Host. Repeat the same command once the Host is reachable.'
for summary in "$summary_partial" "$summary_adopt" "$summary_conflict" "$summary_unreachable"; do
  (( ${#summary} <= 240 ))
done
grep -Fq 'the Host holds no validator identity. Resolve the incomplete operator state through the documented recovery path.' "$PHASE"
grep -Fq 'the Host holds a validator identity. Restore from the matching archive or follow the documented recovery path.' "$PHASE"
grep -Fq "$summary_conflict" "$PHASE"
grep -Fq "$summary_unreachable" "$PHASE"

run_refusal partial partial_identity "$summary_partial" \
  'Host JOIN classification=partial_identity; refuse mutation until the incomplete local identity is resolved through the documented recovery path'
jq -e '.category == "identity" and .resume == "manual_recovery"' "$RUN/join-result.v1.json" >/dev/null
jq -e '.category == "identity" and .resume.decision == "manual_action_required" and .resume.token == "none"' "$RUN/diagnostic-envelope.v1.json" >/dev/null

run_refusal conflict identity_conflict "$summary_conflict" \
  'Host JOIN classification=identity_conflict; a remote validator identity exists without matching local operator state'
jq -e '.category == "identity" and .resume == "manual_recovery"' "$RUN/join-result.v1.json" >/dev/null
jq -e '.category == "identity" and .resume.decision == "manual_action_required" and .resume.token == "none"' "$RUN/diagnostic-envelope.v1.json" >/dev/null

# An unreachable Host is a transport stop: the same command may be repeated.
run_refusal unreachable host_unreachable "$summary_unreachable" \
  'Host JOIN classification=unreachable; remote identity preflight could not establish an SSH session'
jq -e '.category == "host" and .resume == "new_profile"' "$RUN/join-result.v1.json" >/dev/null
jq -e '.category == "network" and .resume.decision == "safe" and .resume.token == "join-repeat"' "$RUN/diagnostic-envelope.v1.json" >/dev/null

# Without a terminal-result location the envelope and verdict are still
# retained; nothing else is written.
RUN="$tmp/no-result/join-node-a"
mkdir -p "$RUN"
rc=0
# shellcheck disable=SC2034
(
  NODE=node-a
  join_profile_sha256="$(printf '%064d' 7)"
  unset GDC_JOIN_RESULT_OUTPUT
  die() { printf 'error: %s\n' "$*" >&2; exit 1; }
  record_join_transition() { :; }
  refuse_before_mutation partial_identity "$summary_partial" 'refused'
) >/dev/null 2>"$tmp/no-result.err" || rc=$?
[[ "$rc" == 1 ]]
"$ROOT/scripts/diagnostic-envelope.sh" validate "$RUN/diagnostic-envelope.v1.json"
[[ -s "$RUN/verdict.md" && ! -e "$RUN/join-result.v1.json" ]]

# Unknown reasons and unsafe summaries fail closed before any record exists.
RUN="$tmp/hostile/join-node-a"
mkdir -p "$RUN"
rc=0
# shellcheck disable=SC2034
(
  NODE=node-a
  join_profile_sha256="$(printf '%064d' 7)"
  GDC_JOIN_RESULT_OUTPUT="$RUN/join-result.v1.json"
  die() { printf 'error: %s\n' "$*" >&2; exit 1; }
  record_join_transition() { :; }
  refuse_before_mutation signer_exploded 'x' 'y'
) >/dev/null 2>"$tmp/hostile.err" || rc=$?
[[ "$rc" == 1 ]]
grep -Fq 'unsupported Host JOIN refusal reason' "$tmp/hostile.err"
rc=0
# shellcheck disable=SC2034
(
  NODE=node-a
  join_profile_sha256="$(printf '%064d' 7)"
  GDC_JOIN_RESULT_OUTPUT="$RUN/join-result.v1.json"
  die() { printf 'error: %s\n' "$*" >&2; exit 1; }
  record_join_transition() { :; }
  refuse_before_mutation partial_identity $'first line\nsecond line' 'y'
) >/dev/null 2>"$tmp/hostile-summary.err" || rc=$?
[[ "$rc" != 0 ]]
grep -Fq 'unsafe summary' "$tmp/hostile-summary.err"
grep -Fq 'could not retain its diagnostic envelope' "$tmp/hostile-summary.err"
[[ ! -e "$RUN/join-result.v1.json" && ! -e "$RUN/verdict.md" && ! -e "$RUN/diagnostic-envelope.v1.json" ]]

printf 'PASS JOIN refusal before mutation records a typed result, envelope and verdict\n'
