#!/usr/bin/env bash
# Read-only health evidence for a normal JOIN re-entry after a retained COMPLETE.
set -Eeuo pipefail

usage() { echo "Usage: $0 NODE JOIN_PROFILE RECEIPT_HEAD" >&2; }
[[ $# -eq 3 ]] || { usage; exit 2; }
node="$1"; profile="$2"; receipt="$3"
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && -r "$profile" && -f "$receipt" && ! -L "$receipt" && "$(stat -c %a "$receipt")" == 600 ]] || {
  echo 'invalid completed JOIN readback input' >&2; exit 2;
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# This is a post-mutation readback. The profile's immutable spec and
# profile_id remain mandatory, but its short preflight TTL may have elapsed.
"$ROOT/scripts/join-profile.sh" validate --allow-expired "$profile" >/dev/null
chain_id="$(jq -er '.spec.network.chain_id' "$profile")"
core_version="$(jq -er '.spec.components.core.expected_runtime.version' "$profile")"
core_commit="$(jq -er '.spec.components.core.expected_runtime.commit' "$profile")"
dapi_version="$(jq -er '.spec.components.dapi.expected_runtime.version' "$profile")"
dapi_commit="$(jq -er '.spec.components.dapi.expected_runtime.commit' "$profile")"
dapi_image="$(jq -er '.spec.components.dapi.installation.image | .repository + "@" + .digest' "$profile")"
profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
p2p_node_id="$(jq -er '.identity_fingerprints.p2p_node_id | select(test("^[a-f0-9]{40}$"))' "$receipt")"
[[ "$chain_id" =~ ^[a-z0-9][a-z0-9-]{0,127}$ \
  && "$core_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ \
  && "$core_commit" =~ ^[0-9a-f]{40}$ \
  && "$dapi_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ \
  && "$dapi_commit" =~ ^[0-9a-f]{40}$ \
  && "$dapi_image" =~ ^[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}$ \
  && "$profile_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'completed JOIN readback has invalid retained identity or profile' >&2; exit 1;
}

# All values interpolated below have a closed grammar above.  This remote
# command performs only Docker/curl/JQ readback and cannot start or stop a
# service.  An unavailable or stale target is not a no-op.
ssh -T "$node" "set -Eeuo pipefail
deploy='/srv/dai/deploy/$node'
test -s \"\$deploy/.env\" && test -s \"\$deploy/compose.yaml\"
test -s \"\$deploy/.gdc-join-profile\"
test \"\$(cat \"\$deploy/.gdc-join-profile\")\" = '$profile_sha256' \\
  || { echo 'completed_join_profile_mismatch: remote generated JOIN marker differs from the retained profile' >&2; exit 1; }
rendered_dapi_image=\"\$(awk -F= '\$1 == \"DAPI_IMAGE\" {print substr(\$0, index(\$0, \"=\") + 1); exit}' \"\$deploy/.env\")\"
test \"\$rendered_dapi_image\" = '$dapi_image' \\
  || { echo 'completed_dapi_image_mismatch: remote DAPI image differs from the retained generated profile' >&2; exit 1; }
test -x \"\$deploy/verify-canonical-join-state.sh\" \\
  || { echo 'completed_join_verifier_unavailable: canonical JOIN verifier is not installed' >&2; exit 1; }
cd \"\$deploy\"
./verify-canonical-join-state.sh \"\$deploy\" '$chain_id' '$p2p_node_id' '$core_version' '$core_commit' '$dapi_version' '$dapi_commit' running
printf 'PASS completed JOIN remote state is healthy and bound to generated profile=%s dapi_image=%s dapi=%s dapi_commit=%s\\n' \\
  '$profile_sha256' '$dapi_image' '$dapi_version' '$dapi_commit'"
