#!/usr/bin/env bash
set -Eeuo pipefail

RUNBOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

manifest=''
approval=''
evidence=''
timeout=''

die() {
  printf 'recovery rehearsal refused: %s\n' "$*" >&2
  exit 2
}

while (( $# )); do
  case "$1" in
    --manifest|--lab-approval|--evidence-dir|--timeout-seconds)
      (( $# >= 2 )) || die "$1 requires an explicit value"
      value="$2"
      [[ -n "$value" && "$value" != --* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
        || die "invalid value for $1"
      case "$1" in
        --manifest) [[ -z "$manifest" ]] || die 'duplicate --manifest'; manifest="$value" ;;
        --lab-approval) [[ -z "$approval" ]] || die 'duplicate --lab-approval'; approval="$value" ;;
        --evidence-dir) [[ -z "$evidence" ]] || die 'duplicate --evidence-dir'; evidence="$value" ;;
        --timeout-seconds) [[ -z "$timeout" ]] || die 'duplicate --timeout-seconds'; timeout="$value" ;;
      esac
      shift 2
      ;;
    *) die "unknown or positional argument: $1" ;;
  esac
done

[[ -n "$manifest" && -n "$approval" && -n "$evidence" && -n "$timeout" ]] \
  || die 'manifest, lab approval, evidence directory, and timeout are required'
[[ "${GDC_RECOVERY_REHEARSAL_AUTHORIZED:-}" == true ]] \
  || die 'missing authority: set GDC_RECOVERY_REHEARSAL_AUTHORIZED=true only for an isolated lab'
[[ "${GDC_RECOVERY_REHEARSAL_SCOPE:-}" == isolated-lab ]] \
  || die 'rehearsal scope must be explicitly set to isolated-lab'
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die 'timeout-seconds must be a positive integer'

# Load validators only after the authority gate; invalid calls touch no gdc paths.
# shellcheck source=scripts/lib-recovery.sh
source "$RUNBOOK_ROOT/scripts/lib-recovery.sh"

recovery_require_private_file "$manifest" || die 'manifest must be a canonical mode-0400/0600 regular file'
recovery_require_private_file "$approval" || die 'lab approval must be a canonical mode-0400/0600 regular file'
recovery_canonical_directory "$evidence" || die 'evidence-dir must be an existing canonical non-symlink directory'
repo_root="$(git -C "$RUNBOOK_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
  || die 'runbook must be executed from a Git worktree'
case "$evidence" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/tmp|/var/tmp/*|"$repo_root"|"$repo_root"/*)
    die 'evidence-dir must be persistent and outside repository/temp storage'
    ;;
esac
[[ "$(recovery_file_mode "$evidence")" == 700 ]] || die 'evidence-dir must have mode 0700'

recovery_validate_json_schema "$(recovery_manifest_schema)" "$manifest" \
  || die 'manifest does not match the recovery manifest schema'
recovery_validate_json_schema "$(recovery_receipt_schema)" "$approval" \
  || die 'lab approval does not match the recovery receipt schema'
manifest_sha="$(recovery_sha256 "$manifest")" || die 'cannot hash manifest'
jq -e '
  .lifecycle.state == "final"
  and .kind == "gdc-network-recovery-manifest"
  and .schema_version == 1
' "$manifest" >/dev/null || die 'rehearsal requires a final recovery manifest'
jq -e --arg manifest_sha "$manifest_sha" '
  .receipt_type == "approval"
  and .manifest_binding_kind == "final_manifest"
  and .manifest_sha256 == $manifest_sha
  and .approval.signed_payload.namespace == "gdc-network-recovery-v1"
  and .approval.signed_payload.subject_kind == "final_manifest"
  and .approval.signed_payload.subject_sha256 == $manifest_sha
  and .approval.signed_payload.run_id == .run_id
  and .approval.signed_payload.host == .host
' "$approval" >/dev/null || die 'lab approval is not exactly bound to the final manifest, run, and host'

not_before="$(jq -er '.approval.signed_payload.not_before' "$approval")" || die 'approval has no start time'
expires_at="$(jq -er '.approval.signed_payload.expires_at' "$approval")" || die 'approval has no expiry time'
not_before_epoch="$(recovery_epoch "$not_before")" || die 'approval start time is invalid'
expires_at_epoch="$(recovery_epoch "$expires_at")" || die 'approval expiry time is invalid'
now_epoch="$(date -u +%s)"
(( now_epoch >= not_before_epoch && now_epoch <= expires_at_epoch )) || die 'lab approval is expired or not yet valid'
recovery_verify_approval_signature "$approval" "$manifest" \
  || die 'lab approval signature or manifest policy verification failed'
(( expires_at_epoch - not_before_epoch <= RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS \
    && now_epoch - not_before_epoch <= RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS )) \
  || die 'lab approval exceeds the manifest policy maximum age'

printf '%s\n' \
  'recovery rehearsal refused: execution adapters remain unqualified; HF-03/HF-04 evidence, isolated adapter review, and HF-06 approval are still required (no SSH, Docker, chain transaction, or signing command was run)' >&2
exit 3
