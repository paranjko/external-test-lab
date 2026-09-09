#!/usr/bin/env bash
# Atomically persist the bounded terminal outcome of one JOIN invocation.
set -Eeuo pipefail
usage() { echo "Usage: $0 --output FILE --input FILE" >&2; }
OUTPUT=''; INPUT=''
while (($#)); do case "$1" in
  --output) OUTPUT="${2:-}"; shift 2 ;;
  --input) INPUT="${2:-}"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ -n "$OUTPUT" && -r "$INPUT" ]] || { usage; exit 2; }
command -v jq >/dev/null || { echo 'jq is required to record a JOIN result' >&2; exit 2; }
jq -e '
  type == "object" and .schema_version == 1 and .kind == "gdc-host-join-result" and
  (keys | sort) == ["category","evidence","exit_code","join_profile_sha256","kind","mutation","outcome","phase","reason","resume","schema_version","signer_state"] and
  (.outcome | IN("succeeded","no_op","refused","failed","manual_recovery_required")) and
  (.phase | IN("profile","identity","staging","state_sync","promotion","membership","signer","acceptance")) and
  (.category | IN("bootstrap","observation","profile","artifact","identity","host","state_sync","lineage","signer","chain","internal")) and
  (.reason | test("^[a-z][a-z0-9_]{0,63}$")) and
  (.exit_code | type == "number" and . >= 0 and . <= 255 and floor == .) and
  (.mutation | IN("none","staging_only","canonical_signer_off","signer_may_be_on")) and
  (.signer_state | IN("absent","fenced","disabled","enabled","unknown")) and
  (.resume | IN("new_profile","resume_same_run","manual_recovery","automatic_retry_forbidden","not_applicable")) and
  (.join_profile_sha256 == null or (.join_profile_sha256 | test("^[a-f0-9]{64}$"))) and
  (.evidence | type == "array" and length <= 16 and all(.[]; type == "object" and (keys | sort) == ["kind","sha256"] and (.kind | test("^[a-z][a-z0-9_-]{0,63}$")) and (.sha256 | test("^[a-f0-9]{64}$"))))
' "$INPUT" >/dev/null || { echo 'invalid JOIN terminal result input' >&2; exit 2; }
umask 077
mkdir -p "$(dirname "$OUTPUT")"
temporary="$(mktemp "$(dirname "$OUTPUT")/.join-result.XXXXXX")"
chmod 600 "$temporary"
jq -cS . "$INPUT" >"$temporary"
sync -f "$temporary"
mv -f "$temporary" "$OUTPUT"
sync -f "$(dirname "$OUTPUT")"
printf '%s\n' "$OUTPUT"
