#!/usr/bin/env bash
# Bounded, public-safe terminal diagnostics. This helper deliberately stores
# no paths, command lines, logs, credentials, or arbitrary operator input.
set -Eeuo pipefail

MAX_TEXT=240
die() { printf 'ERROR diagnostic envelope: %s\n' "$*" >&2; exit 1; }
valid_token() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
valid_text() {
  [[ ${#1} -le $MAX_TEXT && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]] \
    && [[ "$1" =~ ^[[:print:]]*$ ]]
}

validate() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" && $(stat -c '%a' "$file") == 600 ]] || die 'envelope must be a regular mode-0600 file'
  [[ $(wc -c <"$file") -le 8192 ]] || die 'envelope exceeds 8192 bytes'
  jq -e '
    type == "object" and
    (keys | sort) == ["attempts","category","checkpoint","command_family","created_at","deadline_seconds","exit_code","phase","resume","schema_version","state","summary","tool"] and
    .schema_version == 1 and
    (.command_family | test("^(genesis|qualification|join|poc|gateway|upgrade|bridge|observability|launcher)$")) and
    (.phase | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.checkpoint | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.state | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.category | test("^(configuration|identity|lineage|network|chain|timeout|dependency|operator|unknown)$")) and
    (.tool | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.exit_code | type == "number" and . >= 1 and . <= 255) and
    (.attempts | type == "number" and . >= 1 and . <= 999) and
    (.deadline_seconds | type == "number" and . >= 0 and . <= 604800) and
    (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and
    (.summary | type == "string" and length <= 240 and test("^[^\\n\\r\\t]*$")) and
    (.resume | type == "object" and (keys | sort) == ["decision","token"] and
      (.decision | test("^(safe|manual_action_required|unsafe|not_applicable)$")) and
      (.token | test("^(none|join-repeat)$")) and
      ((.decision == "safe") == (.token == "join-repeat")))
  ' "$file" >/dev/null || die 'envelope does not match diagnostic-envelope.v1'
}

write() {
  local output="$1" family="$2" phase="$3" checkpoint="$4" state="$5" category="$6" tool="$7" exit_code="$8" decision="$9" token="${10}" summary="${11}" tmp
  valid_token "$family" && valid_token "$phase" && valid_token "$checkpoint" && valid_token "$state" && valid_token "$tool" || die 'unsafe token'
  [[ "$category" =~ ^(configuration|identity|lineage|network|chain|timeout|dependency|operator|unknown)$ ]] || die 'unsupported category'
  [[ "$exit_code" =~ ^[1-9][0-9]*$ && "$exit_code" -le 255 ]] || die 'unsafe exit code'
  [[ "$decision" =~ ^(safe|manual_action_required|unsafe|not_applicable)$ && "$token" =~ ^(none|join-repeat)$ ]] || die 'unsupported resume decision'
  [[ "$decision" == safe && "$token" == join-repeat || "$decision" != safe && "$token" == none ]] || die 'unsafe resume token'
  valid_text "$summary" || die 'unsafe summary'
  mkdir -p "$(dirname "$output")"
  tmp="$(mktemp "$(dirname "$output")/.diagnostic-envelope.XXXXXX")"
  jq -n --arg family "$family" --arg phase "$phase" --arg checkpoint "$checkpoint" --arg state "$state" --arg category "$category" --arg tool "$tool" --arg summary "$summary" --arg decision "$decision" --arg token "$token" --argjson exit_code "$exit_code" \
    '{schema_version:1,command_family:$family,phase:$phase,checkpoint:$checkpoint,state:$state,category:$category,tool:$tool,exit_code:$exit_code,attempts:1,deadline_seconds:0,created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),summary:$summary,resume:{decision:$decision,token:$token}}' >"$tmp"
  chmod 0600 "$tmp"
  validate "$tmp"
  mv -f "$tmp" "$output"
  chmod 0600 "$output"
}

case "${1:-}" in
  validate) [[ $# -eq 2 ]] || die 'usage: validate FILE'; validate "$2" ;;
  write) [[ $# -eq 12 ]] || die 'usage: write OUTPUT FAMILY PHASE CHECKPOINT STATE CATEGORY TOOL EXIT DECISION TOKEN SUMMARY'; write "${@:2}" ;;
  *) die 'usage: diagnostic-envelope.sh validate|write' ;;
esac
