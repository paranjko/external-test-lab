#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
required_core_lock="$ROOT/profiles/releases/core-required-test.lock"
cleanup() {
  rm -rf "$tmp"
  rm -f "$required_core_lock"
}
trap cleanup EXIT

comp_out="$tmp/test-composition.json"

# Positive: create composition manifest via gdc.sh
out="$("$ROOT/gdc.sh" release composition create \
  --core v2026.08.06 \
  --devshard v2026.08.06 \
  --name test-gdc-comp \
  --output "$comp_out")"

[[ "$out" == *"READY composition=test-gdc-comp"* ]]
[[ -s "$comp_out" ]]
[[ -s "$tmp/test-composition.sha256" ]]

# Positive: verify composition manifest via gdc.sh
verify_out="$("$ROOT/gdc.sh" release composition verify "$comp_out")"
[[ "$verify_out" == *"PASS composition=test-gdc-comp"* ]]

# Positive: materialize lock via gdc.sh
mat_lock="$tmp/materialized.lock"
mat_out="$("$ROOT/gdc.sh" release composition materialize "$comp_out" --output "$mat_lock")"
[[ "$mat_out" == *"READY composition=test-gdc-comp lock="* ]]
[[ -s "$mat_lock" ]]
grep -q "LOCAL_GATEWAY_IMAGE=gdc/devshard-gateway:0.2.15-v3" "$mat_lock"

# Positive: test profile loading with composition flag
(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_COMPOSITION="$comp_out" load_profiles
  [[ "$GDC_COMPOSITION" == "$comp_out" ]]
  [[ "$DEVSHARD_PROTOCOL_VERSION" == "v3" ]]
  [[ "$DEVSHARD_SUPPORTED_PROTOCOLS" == "v3" ]]
  [[ "$DEVSHARD_GOVERNANCE_PROTOCOLS" == "v3 v4" ]]
  [[ "$LOCAL_GATEWAY_IMAGE" == "gdc/devshard-gateway:0.2.15-v3" ]]
  [[ -n "$GDC_COMPOSITION_HASH" ]]
  hash1="$(profile_hash)"
  [[ -n "$hash1" ]]
  # Different composition hash produces different runtime profile_hash
  GDC_COMPOSITION_HASH="0000000000000000000000000000000000000000000000000000000000000000"
  hash2="$(profile_hash)"
  [[ "$hash1" != "$hash2" ]]
  GDC_COMPOSITION_HASH=''
  load_profiles
  [[ "$GDC_COMPOSITION" == "$comp_out" ]]
  [[ -n "$GDC_COMPOSITION_HASH" ]]
)

# Positive: gdc.sh CLI accepts direct composition file path
gdc_out="$("$ROOT/gdc.sh" --composition "$comp_out" release composition verify "$comp_out")"
[[ "$gdc_out" == *"PASS composition=test-gdc-comp"* ]]

# Negative: an explicit release cannot contradict the composition core profile.
if "$ROOT/gdc.sh" --composition "$comp_out" --release v2026.07.23 \
  release composition verify "$comp_out" >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
  echo 'composition CLI accepted a conflicting release profile' >&2
  exit 1
fi
grep -Fq 'conflicts with composition core profile v2026.08.06' "$tmp/conflict.err"

# Positive: test profile_summary with composition
(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_COMPOSITION="$comp_out" load_profiles
  summary="$(profile_summary)"
  [[ "$summary" == *"composition=$comp_out"* ]]
  [[ "$summary" == *"composition_hash="* ]]
  [[ "$summary" == *"postgres_image="* ]]
)

# Positive: test CANDIDATE_LAYER=devshard lock loading base profile
printf '%s\n' \
  'LAB_CANDIDATE=true' \
  'CANDIDATE_LAYER=devshard' \
  'UPGRADE_FROM_PROFILE=v2026.08.06' \
  'DEVSHARD_PROTOCOL_VERSION=v5' \
  'CANDIDATE_DEVSHARD_PROTOCOL_VERSION=v5' \
  'CANDIDATE_DEVSHARD_SUPPORTED_PROTOCOLS="v3 v5"' \
  'DEVSHARD_V5_URL=https://example.test/devshardd-v5.zip' \
  'DEVSHARD_V5_SHA256=5555555555555555555555555555555555555555555555555555555555555555' \
  'LOCAL_GATEWAY_IMAGE=gdc/devshard-gateway:candidate' \
  'POSTGRES_IMAGE=postgres:16-alpine' > "$ROOT/profiles/releases/devshard-test-temp.lock"
(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_RELEASE_PROFILE=devshard-test-temp load_profiles
  # Assert core variable loaded from base profile v2026.08.06
  [[ -n "$INFERENCED_IMAGE" ]]
  [[ -n "$GONKA_COMMIT" ]]
  [[ "$DEVSHARD_PROTOCOL_VERSION" == "v5" ]]
  [[ "$DEVSHARD_SUPPORTED_PROTOCOLS" == "v3 v5" ]]
  [[ "$DEVSHARD_GOVERNANCE_PROTOCOLS" == "v3 v4 v5" ]]
)
rm -f "$ROOT/profiles/releases/devshard-test-temp.lock"

# Positive: a standalone core candidate also loads its declared baseline.
printf '%s\n' \
  'LAB_CANDIDATE=true' \
  'CANDIDATE_LAYER=core' \
  'UPGRADE_FROM_PROFILE=v2026.08.06' \
  'GONKA_RELEASE=0.2.16' > "$ROOT/profiles/releases/core-test-temp.lock"
(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_RELEASE_PROFILE=core-test-temp load_profiles
  [[ -n "$DEVSHARD_PROTOCOL_VERSION" ]]
  [[ -n "$LOCAL_GATEWAY_IMAGE" ]]
  [[ -n "$POSTGRES_IMAGE" ]]
)
rm -f "$ROOT/profiles/releases/core-test-temp.lock"

# A core candidate that binds an exact DevShard identity must never load as a
# standalone release profile, because that would silently inherit the baseline
# DevShard runtime. The verified composition is the only accepted path.
devshard_lock="$ROOT/profiles/releases/v2026.08.30-rc.0.lock"
devshard_definition_sha256="$(awk -F= '$1 == "CANDIDATE_DEFINITION_SHA256" {print $2}' "$devshard_lock")"
devshard_build_manifest_sha256="$(awk -F= '$1 == "CANDIDATE_BUILD_MANIFEST_SHA256" {print $2}' "$devshard_lock")"
devshard_release_lock_sha256="$(sha256sum "$devshard_lock" | awk '{print $1}')"
cp "$ROOT/profiles/releases/v2026.08.06.lock" "$required_core_lock"
{
  printf '%s\n' \
    'LAB_CANDIDATE=true' \
    'CANDIDATE_LAYER=core' \
    'UPGRADE_FROM_PROFILE=v2026.08.06' \
    'REQUIRED_DEVSHARD_PROFILE=v2026.08.30-rc.0'
  printf 'REQUIRED_DEVSHARD_DEFINITION_SHA256=%s\n' "$devshard_definition_sha256"
  printf 'REQUIRED_DEVSHARD_BUILD_MANIFEST_SHA256=%s\n' "$devshard_build_manifest_sha256"
  printf 'REQUIRED_DEVSHARD_RELEASE_LOCK_SHA256=%s\n' "$devshard_release_lock_sha256"
} >>"$required_core_lock"

if (
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_RELEASE_PROFILE=core-required-test load_profiles
) >"$tmp/direct-required.out" 2>"$tmp/direct-required.err"; then
  echo 'core profile with an exact DevShard requirement loaded without a composition' >&2
  exit 1
fi
grep -Fq 'requires a verified composition with DevShard profile v2026.08.30-rc.0' \
  "$tmp/direct-required.err"

required_comp="$tmp/core-required-composition.json"
"$ROOT/gdc.sh" release composition create \
  --core core-required-test \
  --devshard v2026.08.30-rc.0 \
  --name core-required-composition \
  --output "$required_comp" >/dev/null
(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_COMPOSITION="$required_comp" load_profiles
  [[ "$GDC_RELEASE_PROFILE" == core-required-test ]]
  [[ "$GDC_COMPOSITION_DEVSHARD_PROFILE" == v2026.08.30-rc.0 ]]
  [[ "$GDC_COMPOSITION_DEVSHARD_DEFINITION_SHA256" == "$devshard_definition_sha256" ]]
  [[ "$GDC_COMPOSITION_DEVSHARD_BUILD_MANIFEST_SHA256" == "$devshard_build_manifest_sha256" ]]
  [[ "$GDC_COMPOSITION_DEVSHARD_RELEASE_LOCK_SHA256" == "$devshard_release_lock_sha256" ]]
)

printf 'DEVSHARD_GATEWAY_IMAGE=registry.example/devshard-gateway:v5@sha256:%064d\n' 0 \
  >"$tmp/unsupported-resolved.lock"
if (
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_COMPOSITION="$required_comp" \
    GDC_RESOLVED_IMAGE_LOCK="$tmp/unsupported-resolved.lock" load_profiles
) >"$tmp/unsupported-resolved.out" 2>"$tmp/unsupported-resolved.err"; then
  echo 'resolved image lock replaced a composition DevShard image' >&2
  exit 1
fi
grep -Fq 'contains an unsupported variable: DEVSHARD_GATEWAY_IMAGE' \
  "$tmp/unsupported-resolved.err"

printf 'DAPI_IMAGE=registry.example/dapi:other@sha256:%064d\n' 0 \
  >"$tmp/conflicting-resolved.lock"
if (
  # shellcheck source=/dev/null
  source "$ROOT/scripts/profile.sh"
  GDC_COMPOSITION="$required_comp" \
    GDC_RESOLVED_IMAGE_LOCK="$tmp/conflicting-resolved.lock" load_profiles
) >"$tmp/conflicting-resolved.out" 2>"$tmp/conflicting-resolved.err"; then
  echo 'resolved image lock replaced a pinned composition core image' >&2
  exit 1
fi
grep -Fq 'conflicts with pinned profile image: DAPI_IMAGE' \
  "$tmp/conflicting-resolved.err"

# Negative: tampered manifest fails verification
echo "tampered" >> "$comp_out"
! "$ROOT/gdc.sh" release composition verify "$comp_out" >/dev/null 2>&1

printf 'PASS composition manifest CLI contract\n'
