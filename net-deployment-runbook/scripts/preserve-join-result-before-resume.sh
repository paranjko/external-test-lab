#!/usr/bin/env bash
# Preserve the conservative failed result before an explicitly receipt-bound
# CANONICAL_VERIFIED continuation is allowed to publish a later outcome.
set -Eeuo pipefail

usage() { echo "Usage: $0 --result FILE --profile-sha256 SHA256" >&2; }
result=''; profile_sha=''
while (($#)); do
  case "$1" in
    --result) result="${2:-}"; shift 2 ;;
    --profile-sha256) profile_sha="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$result" && "$profile_sha" =~ ^[a-f0-9]{64}$ ]] || { usage; exit 2; }
[[ -f "$result" && ! -L "$result" && "$(stat -c %a "$result")" == 600 ]] || {
  echo 'canonical resume requires a regular mode-0600 failed JOIN result' >&2
  exit 1
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/record-join-result.sh" --validate "$result" >/dev/null
jq -e --arg profile "$profile_sha" '
  .kind == "gdc-host-join-result" and .outcome == "failed" and
  .phase == "signer" and .category == "internal" and
  .reason == "join_phase_failed" and .exit_code > 0 and
  .mutation == "signer_may_be_on" and .signer_state == "unknown" and
  .resume == "automatic_retry_forbidden" and .join_profile_sha256 == $profile
' "$result" >/dev/null || {
  echo 'canonical resume result is not the expected conservative failed phase outcome' >&2
  exit 1
}

digest="$(sha256sum "$result" | awk '{print $1}')"
archive="$(dirname "$result")/join-result-resume-source-$digest.v1.json"
if [[ -e "$archive" || -L "$archive" ]]; then
  [[ -f "$archive" && ! -L "$archive" && "$(stat -c %a "$archive")" == 600 ]] \
    && cmp -s "$result" "$archive" || {
    echo 'canonical resume refuses conflicting prior-result history' >&2
    exit 1
  }
else
  # Hard-link the already validated file: later atomic replacement of the
  # current result cannot change this immutable evidence copy.
  ln -- "$result" "$archive" || {
    [[ -f "$archive" && ! -L "$archive" ]] && cmp -s "$result" "$archive" || {
      echo 'canonical resume could not preserve the prior failed JOIN result' >&2
      exit 1
    }
  }
  sync -f "$archive"
  sync -f "$(dirname "$result")"
fi
printf 'PASS preserved conservative JOIN failure result sha256=%s\n' "$digest"
