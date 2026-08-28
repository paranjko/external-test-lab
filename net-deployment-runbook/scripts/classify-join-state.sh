#!/usr/bin/env bash
# Classify only the local pre-mutation evidence. Remote recovery remains owned
# by the PR #51 verifier, which rejects mismatched chain and identity state.
set -Eeuo pipefail

classify_snapshot() {
  local snapshot="$1" result
  [[ -f "$snapshot" && ! -L "$snapshot" && $(wc -c <"$snapshot") -le 8192 ]] || { echo 'JOIN classification snapshot is unsafe' >&2; exit 1; }
  jq -e '
    type == "object" and (keys | sort) == ["archive","identity","lineage","managed_drift","reachable"] and
    (.reachable | type == "boolean") and
    (.identity | test("^(absent|matched|partial|conflict)$")) and
    (.lineage | test("^(matched|conflict)$")) and
    (.archive | test("^(none|matching)$")) and
    (.managed_drift | type == "boolean")
  ' "$snapshot" >/dev/null || { echo 'JOIN classification snapshot is malformed' >&2; exit 1; }
  result="$(jq -r '
    if .reachable == false then "unreachable"
    elif .lineage == "conflict" then "lineage_conflict"
    elif .identity == "conflict" then "identity_conflict"
    elif .identity == "partial" then "partial_identity"
    elif .managed_drift then "managed_drift"
    elif .identity == "absent" and .archive == "matching" then "restore_empty"
    elif .identity == "absent" then "new"
    elif .identity == "matched" then "running_matched"
    else error("unsupported JOIN state") end
  ' "$snapshot")"
  jq -n --arg classification "$result" --slurpfile snapshot "$snapshot" '$snapshot[0] + {schema_version:1,classification:$classification}'
}

if [[ "${1:-}" == --snapshot ]]; then
  [[ $# -eq 2 ]] || { echo "usage: $0 --snapshot SNAPSHOT.json" >&2; exit 2; }
  classify_snapshot "$2"
  exit 0
fi

[[ $# -eq 4 ]] || { echo "usage: $0 IDENTITY ACCOUNT JOINED_MARKER RESTORE_ARCHIVE_OR_EMPTY" >&2; exit 2; }
identity="$1" account="$2" joined="$3" restore="$4"
present() { [[ -s "$1" && ! -L "$1" ]]; }

identity_present=false account_present=false joined_present=false
present "$identity" && identity_present=true
present "$account" && account_present=true
[[ -e "$joined" && ! -L "$joined" ]] && joined_present=true

if [[ -n "$restore" ]]; then
  [[ -f "$restore" && ! -L "$restore" ]] || { echo 'restore archive is unsafe' >&2; exit 1; }
  if [[ "$identity_present" == false && "$account_present" == false && "$joined_present" == false ]]; then
    result=restore_empty
  else
    result=running_matched
  fi
elif [[ "$identity_present" == false && "$account_present" == false && "$joined_present" == false ]]; then
  result=new
elif [[ "$identity_present" == true && "$account_present" == true && "$joined_present" == true ]]; then
  result=running_matched
else
  result=partial_identity
fi

jq -n --arg classification "$result" --argjson identity_present "$identity_present" --argjson account_present "$account_present" --argjson joined_present "$joined_present" \
  '{schema_version:1,classification:$classification,identity_present:$identity_present,account_present:$account_present,joined_present:$joined_present}'
