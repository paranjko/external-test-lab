#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
profile_sha="$(printf profile | sha256sum | awk '{print $1}')"

write_result() {
  local path="$1" outcome="${2:-failed}" resume="${3:-automatic_retry_forbidden}"
  jq -cn --arg profile "$profile_sha" --arg outcome "$outcome" --arg resume "$resume" '
    {schema_version:1,kind:"gdc-host-join-result",outcome:$outcome,phase:"signer",category:"internal",
     reason:"join_phase_failed",exit_code:1,mutation:"signer_may_be_on",signer_state:"unknown",
     resume:$resume,join_profile_sha256:$profile,evidence:[]}' >"$path"
  chmod 0600 "$path"
}

source_result="$tmp/join-result.v1.json"
write_result "$source_result"
"$ROOT/scripts/preserve-join-result-before-resume.sh" --result "$source_result" --profile-sha256 "$profile_sha"
digest="$(sha256sum "$source_result" | awk '{print $1}')"
history="$tmp/join-result-resume-source-$digest.v1.json"
[[ -f "$history" && ! -L "$history" && "$(stat -c %a "$history")" == 600 ]]
cmp -s "$source_result" "$history"
"$ROOT/scripts/preserve-join-result-before-resume.sh" --result "$source_result" --profile-sha256 "$profile_sha" >/dev/null

# Simulate the normal atomic publication of the later result. The retained
# source must remain byte-identical and cannot be silently rewritten.
later="$tmp/later.json"
write_result "$later" succeeded not_applicable
history_sha="$(sha256sum "$history" | awk '{print $1}')"
mv "$later" "$source_result"
[[ "$(sha256sum "$history" | awk '{print $1}')" == "$history_sha" ]]
if "$ROOT/scripts/preserve-join-result-before-resume.sh" --result "$source_result" --profile-sha256 "$profile_sha" >/dev/null 2>&1; then
  echo 'non-failed current result unexpectedly passed the resume-history gate' >&2
  exit 1
fi

# A same-name conflicting archive is refused, and an unsafe source symlink is
# never followed.
write_result "$source_result"
printf 'tampered\n' >"$history"
chmod 0600 "$history"
if "$ROOT/scripts/preserve-join-result-before-resume.sh" --result "$source_result" --profile-sha256 "$profile_sha" >/dev/null 2>&1; then
  echo 'conflicting result history unexpectedly passed' >&2
  exit 1
fi
rm -f "$source_result"
ln -s "$history" "$source_result"
if "$ROOT/scripts/preserve-join-result-before-resume.sh" --result "$source_result" --profile-sha256 "$profile_sha" >/dev/null 2>&1; then
  echo 'symlink result unexpectedly passed' >&2
  exit 1
fi

printf 'PASS prior failed JOIN result is preserved without overwriting or following unsafe paths\n'
