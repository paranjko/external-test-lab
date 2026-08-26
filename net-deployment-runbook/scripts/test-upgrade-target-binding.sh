#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d /tmp/gdc-test-upgrade-target.XXXXXX)"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

export GDC_HOME="$temporary/home"
source "$ROOT/scripts/lib.sh"

target_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
profile_hash() { printf '%s\n' "$target_hash"; }
release_profile_runtime_identity() {
  [[ "$1" == v2026.08.06 ]]
  printf '0.2.15 %s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
}
GDC_RELEASE_PROFILE=v2026.08.25-rc.0
GONKA_RELEASE=0.2.16
GONKA_COMMIT=cccccccccccccccccccccccccccccccccccccccc
export GDC_RELEASE_PROFILE GONKA_RELEASE GONKA_COMMIT
INFERENCED_UPGRADE_URL=https://example.test/inferenced.zip
INFERENCED_UPGRADE_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
DAPI_UPGRADE_URL=https://example.test/dapi.zip
DAPI_UPGRADE_SHA256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

[[ "$(candidate_runtime_identity_for_marker '' v2026.08.06)" \
  == '0.2.15 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]
[[ "$(candidate_runtime_identity_for_marker "$GDC_RELEASE_PROFILE $target_hash" v2026.08.06)" \
  == '0.2.16 cccccccccccccccccccccccccccccccccccccccc' ]]
if (candidate_runtime_identity_for_marker \
  "v2026.08.24-rc.9 $target_hash" v2026.08.06) >/dev/null 2>&1; then
  echo 'a different candidate runtime marker must be rejected' >&2
  exit 1
fi

[[ "$(upgrade_marker_name_for_scope full)" == .gdc-release ]]
[[ "$(upgrade_marker_name_for_scope cosmovisor)" == .gdc-binary-upgrade ]]
[[ "$(classify_upgrade_runtime_marker true '' "$GDC_RELEASE_PROFILE $target_hash")" == target-unmarked ]]
[[ "$(classify_upgrade_runtime_marker true "$GDC_RELEASE_PROFILE $target_hash" \
  "$GDC_RELEASE_PROFILE $target_hash")" == target-marked ]]
[[ "$(classify_upgrade_runtime_marker false '' "$GDC_RELEASE_PROFILE $target_hash")" == source-or-unavailable ]]
source_marker="v2026.08.06 $target_hash"
[[ "$(classify_upgrade_runtime_marker false "$source_marker" \
  "$GDC_RELEASE_PROFILE $target_hash" "$source_marker")" == source-or-unavailable ]]
[[ "$(classify_upgrade_runtime_marker true "$source_marker" \
  "$GDC_RELEASE_PROFILE $target_hash" "$source_marker")" == target-unmarked ]]
if (classify_upgrade_runtime_marker true "v2026.08.24-rc.9 $target_hash" \
  "$GDC_RELEASE_PROFILE $target_hash") >/dev/null 2>&1; then
  echo 'target runtime with another immutable marker must be rejected' >&2
  exit 1
fi
if (classify_upgrade_runtime_marker false "$GDC_RELEASE_PROFILE $target_hash" \
  "$GDC_RELEASE_PROFILE $target_hash") >/dev/null 2>&1; then
  echo 'source runtime with a target marker must be rejected' >&2
  exit 1
fi

state="$temporary/state.env"
cat >"$state" <<EOF
state=VALIDATOR_EFFECTIVE
node=gdc-node1
proposal_id=7
plan_height=1200
genesis_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
chain_id=gonka-devnet-community
release_profile=$GDC_RELEASE_PROFILE
profile_hash=$target_hash
inferenced_url=$INFERENCED_UPGRADE_URL
inferenced_sha256=$INFERENCED_UPGRADE_SHA256
dapi_url=$DAPI_UPGRADE_URL
dapi_sha256=$DAPI_UPGRADE_SHA256
EOF
require_host_upgrade_state_target "$state" gdc-node1 7 1200 \
  ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  gonka-devnet-community

sed -i 's/^release_profile=.*/release_profile=v2026.08.24-rc.9/' "$state"
if (require_host_upgrade_state_target "$state" gdc-node1 7 1200 \
  ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  gonka-devnet-community) >/dev/null 2>&1; then
  echo 'completed state from another target profile must be rejected' >&2
  exit 1
fi

grep -Fq 'target_marker_name="$(upgrade_marker_name_for_scope "$marker_scope")"' \
  "$ROOT/scripts/phase-upgrade.sh"
grep -Fq 'target_runtime_active" == true || "$target_runtime_observed" == true' \
  "$ROOT/scripts/phase-upgrade.sh"

printf 'PASS candidate runtime and Host upgrade target binding\n'
