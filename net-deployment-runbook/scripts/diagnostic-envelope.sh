#!/bin/sh
set -eu
MAX_TEXT=240
ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
. "$ROOT/scripts/portable.sh"
die() { printf 'ERROR diagnostic envelope: %s\n' "$*" >&2; exit 1; }
valid_token() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; }
valid_text() { [ "$#" -eq 1 ] && [ "$(printf %s "$1" | wc -c | tr -d ' ')" -le "$MAX_TEXT" ] && printf '%s' "$1" | LC_ALL=C grep -Eq '^[ -~]*$'; }
validate() {
  file=$1
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(gdc_file_mode "$file")" = 600 ] || die 'envelope must be a regular mode-0600 file'
  [ "$(wc -c <"$file")" -le 8192 ] || die 'envelope exceeds 8192 bytes'
  jq -e 'type == "object" and (keys | sort) == ["attempts","category","checkpoint","command_family","created_at","deadline_seconds","exit_code","phase","resume","schema_version","state","summary","tool"] and .schema_version == 1 and (.command_family | test("^(genesis|qualification|join|poc|gateway|upgrade|bridge|observability|launcher)$")) and (.phase | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and (.checkpoint | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and (.state | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and (.category | test("^(configuration|identity|lineage|network|chain|timeout|dependency|operator|unknown)$")) and (.tool | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and (.exit_code | type == "number" and . >= 1 and . <= 255) and (.attempts | type == "number" and . >= 1 and . <= 999) and (.deadline_seconds | type == "number" and . >= 0 and . <= 604800) and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and (.summary | type == "string" and length <= 240 and test("^[^\\n\\r\\t]*$")) and (.resume | type == "object" and (keys | sort) == ["decision","token"] and (.decision | test("^(safe|manual_action_required|unsafe|not_applicable)$")) and (.token | test("^(none|join-repeat)$")) and ((.decision == "safe") == (.token == "join-repeat")))' "$file" >/dev/null || die 'envelope does not match diagnostic-envelope.v1'
}
write() {
  output=$1 family=$2 phase=$3 checkpoint=$4 state=$5 category=$6 tool=$7 exit_code=$8 decision=$9
  shift 9; token=$1 summary=$2
  valid_token "$family" && valid_token "$phase" && valid_token "$checkpoint" && valid_token "$state" && valid_token "$tool" || die 'unsafe token'
  printf '%s\n' "$category" | grep -Eq '^(configuration|identity|lineage|network|chain|timeout|dependency|operator|unknown)$' || die 'unsupported category'
  printf '%s\n' "$exit_code" | grep -Eq '^[1-9][0-9]*$' && [ "$exit_code" -le 255 ] || die 'unsafe exit code'
  printf '%s\n' "$decision:$token" | grep -Eq '^(safe:join-repeat|(manual_action_required|unsafe|not_applicable):none)$' || die 'unsafe resume token'
  valid_text "$summary" || die 'unsafe summary'
  mkdir -p "$(dirname "$output")"
  tmp=$(gdc_mktemp_file "$(dirname "$output")/.diagnostic-envelope") || die 'cannot create envelope'
  jq -n --arg family "$family" --arg phase "$phase" --arg checkpoint "$checkpoint" --arg state "$state" --arg category "$category" --arg tool "$tool" --arg summary "$summary" --arg decision "$decision" --arg token "$token" --argjson exit_code "$exit_code" '{schema_version:1,command_family:$family,phase:$phase,checkpoint:$checkpoint,state:$state,category:$category,tool:$tool,exit_code:$exit_code,attempts:1,deadline_seconds:0,created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),summary:$summary,resume:{decision:$decision,token:$token}}' >"$tmp"
  chmod 0600 "$tmp"; validate "$tmp"; mv -f "$tmp" "$output"; chmod 0600 "$output"
}
gdc_require_jq || exit $?
[ "$#" -gt 0 ] && action=$1 || action=''
shift || true
case "$action" in
  validate) [ "$#" -eq 1 ] || die 'usage: validate FILE'; validate "$1" ;;
  write) [ "$#" -eq 11 ] || die 'usage: write OUTPUT FAMILY PHASE CHECKPOINT STATE CATEGORY TOOL EXIT DECISION TOKEN SUMMARY'; write "$@" ;;
  *) die 'usage: diagnostic-envelope.sh validate|write' ;;
esac
