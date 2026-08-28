#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

GDC_HOME="$tmp/operator/gdc-node2"
STATE="$GDC_HOME/state"
export ROOT GDC_HOME STATE
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

# A repeated JOIN retains its recorded profile without asking the operator to
# remember a release selector.
mkdir -p "$GDC_HOME/runs/previous" "$STATE"
printf 'previous\n' >"$STATE/active-run-id"
printf '%s\n' \
  'schema_version=2' \
  'run_id=previous' \
  "operator_data_home=$GDC_HOME" \
  'release_profile=v2026.07.23' \
  >"$GDC_HOME/runs/previous/manifest.env"
unset GDC_RELEASE_PROFILE
resolve_join_release_profile ''
[[ "$GDC_RELEASE_PROFILE" == v2026.07.23 ]]

if (resolve_join_release_profile v2026.08.06) >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
  echo 'JOIN accepted a release selector that conflicts with retained lineage' >&2
  exit 1
fi
grep -Fq 'omit --release' "$tmp/conflict.err"

# Historical manifests can have an obsolete release label while their full
# immutable profile hash records the runtime actually used. A restore resolves
# that hash and starts a separate recovery evidence run without touching the
# historical record.
profile_hash="$(join_profile_hash v2026.08.06 community-lab qwen3-0.6b)"
printf '%s\n' \
  'release_profile=v2026.07.23' \
  'deployment_profile=community-lab' \
  'model_profile=qwen3-0.6b' \
  "profile_hash=$profile_hash" \
  >"$GDC_HOME/runs/previous/manifest.env"
unset GDC_RELEASE_PROFILE
resolve_join_release_profile '' "$tmp/validator-backup.tar"
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]]
[[ "$GDC_JOIN_RECOVERY_NEW_RUN" == true && "$GDC_JOIN_RECOVERY_FROM_RUN_ID" == previous ]]
GDC_RUN_ID=recovery-test
ensure_run_manifest restore-profile-lineage
grep -qx 'release_profile=v2026.08.06' "$GDC_HOME/runs/$GDC_RUN_ID/manifest.env"
grep -qx 'recovery_of_run_id=previous' "$GDC_HOME/runs/$GDC_RUN_ID/manifest.env"

# A first JOIN has one current profile and therefore needs no public selector.
rm -rf "$GDC_HOME/runs" "$STATE"
mkdir -p "$STATE"
unset GDC_RELEASE_PROFILE
resolve_join_release_profile ''
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]]

# A deliberate exceptional selector remains possible only where no retained
# lineage makes the choice unsafe.
unset GDC_RELEASE_PROFILE
resolve_join_release_profile v2026.07.23
[[ "$GDC_RELEASE_PROFILE" == v2026.07.23 ]]

printf 'PASS Host JOIN profile resolution\n'
