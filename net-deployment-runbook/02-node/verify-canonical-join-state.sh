#!/usr/bin/env bash
# Verify the promoted canonical Core at a JOIN lifecycle boundary. This is a
# Host-local readback: the default proves a signerless pre-activation runtime,
# while completed/recovery callers explicitly require one running signer.
set -Eeuo pipefail

usage() {
  echo "Usage: $0 DEPLOY_DIR EXPECTED_CHAIN_ID EXPECTED_P2P_NODE_ID EXPECTED_CORE_VERSION EXPECTED_CORE_COMMIT EXPECTED_DAPI_VERSION EXPECTED_DAPI_COMMIT [stopped|running]" >&2
}

[[ $# -eq 7 || $# -eq 8 ]] || { usage; exit 2; }
deploy_dir="$1"
expected_chain_id="$2"
expected_p2p_node_id="$3"
expected_core_version="$4"
expected_core_commit="$5"
expected_dapi_version="$6"
expected_dapi_commit="$7"
expected_signer_state="${8:-stopped}"
[[ "$deploy_dir" =~ ^/[A-Za-z0-9_./-]+$ \
  && "$expected_chain_id" =~ ^[a-z0-9][a-z0-9-]{0,127}$ \
  && "$expected_p2p_node_id" =~ ^[0-9a-f]{40}$ \
  && "$expected_core_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ \
  && "$expected_core_commit" =~ ^[0-9a-f]{40}$ \
  && "$expected_dapi_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ \
  && "$expected_dapi_commit" =~ ^[0-9a-f]{40}$ \
  && "$expected_signer_state" =~ ^(stopped|running)$ ]] \
  || { echo 'invalid canonical JOIN verification input' >&2; exit 2; }
[[ -s "$deploy_dir/.env" && -s "$deploy_dir/compose.yaml" ]] \
  || { echo 'canonical JOIN deployment is incomplete' >&2; exit 1; }

compose=(docker compose --env-file "$deploy_dir/.env" -f "$deploy_dir/compose.yaml")
node_container="$("${compose[@]}" ps -q node)"
[[ "$node_container" =~ ^[0-9a-f]{12,64}$ ]] \
  || { echo 'canonical_core_unavailable: node container is not running' >&2; exit 1; }

# The image reference comes from the immutable generated JOIN profile through
# the rendered .env.  Bind the running container to that resolved image ID;
# mutable tags cannot satisfy this check because generated profiles require a
# digest-qualified image.
expected_image="$(awk -F= '$1 == "INFERENCED_IMAGE" {print substr($0, index($0, "=") + 1); exit}' "$deploy_dir/.env")"
[[ "$expected_image" == *@sha256:[0-9a-f]* && "$expected_image" =~ @sha256:[0-9a-f]{64}$ ]] \
  || { echo 'canonical_core_unavailable: rendered Core image is not digest-qualified' >&2; exit 1; }
expected_image_id="$(docker image inspect --format '{{.Id}}' "$expected_image")" \
  || { echo 'canonical_core_unavailable: rendered Core image is unavailable locally' >&2; exit 1; }
actual_image_id="$(docker inspect --format '{{.Image}}' "$node_container")" \
  || { echo 'canonical_core_unavailable: cannot inspect running Core image' >&2; exit 1; }
[[ "$actual_image_id" == "$expected_image_id" ]] \
  || { echo 'canonical_core_image_mismatch: running Core does not match generated profile image' >&2; exit 1; }
core_exe="$(docker exec "$node_container" readlink -f /proc/1/exe)" \
  || { echo 'canonical_core_unavailable: cannot inspect Core pid 1 executable' >&2; exit 1; }
[[ "$core_exe" == /* ]] \
  || { echo 'canonical_core_unavailable: Core pid 1 executable is not absolute' >&2; exit 1; }
core_version_output="$(docker exec "$node_container" "$core_exe" version --long 2>/dev/null)" \
  || { echo 'canonical_core_unavailable: cannot inspect running Core build metadata' >&2; exit 1; }
actual_core_commit="$(awk -F': ' '$1 == "commit" {print tolower($2); exit}' <<<"$core_version_output")"
[[ "$actual_core_commit" =~ ^[0-9a-f]{40}$ ]] \
  || { echo 'canonical_core_unavailable: running Core did not expose a valid commit' >&2; exit 1; }

# A signer service that merely exists as an exited container is harmless; a
# running TMKMS is not.  Query every Compose-known signer container directly
# rather than relying on a profile default or a human-readable table.
mapfile -t tmkms_containers < <("${compose[@]}" ps -aq tmkms | sed '/^$/d')
running_signers=0
for tmkms_container in "${tmkms_containers[@]}"; do
  running="$(docker inspect --format '{{.State.Running}}' "$tmkms_container")" \
    || { echo 'canonical_signer_state_unknown: cannot inspect TMKMS' >&2; exit 1; }
  [[ "$running" == true || "$running" == false ]] \
    || { echo 'canonical_signer_state_unknown: TMKMS reported an invalid state' >&2; exit 1; }
  [[ "$running" != true ]] || running_signers=$((running_signers + 1))
done
if [[ "$expected_signer_state" == stopped ]]; then
  (( running_signers == 0 )) \
    || { echo 'canonical_signer_running: TMKMS must remain stopped before fence verification' >&2; exit 1; }
else
  (( ${#tmkms_containers[@]} == 1 && running_signers == 1 )) \
    || { echo 'canonical_signer_unavailable: completed validator must have exactly one running TMKMS' >&2; exit 1; }
fi

status="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status)" \
  || { echo 'canonical_core_unavailable: local Core status endpoint is unavailable' >&2; exit 1; }
actual_chain_id="$(jq -er '.result.node_info.network' <<<"$status")"
actual_p2p_node_id="$(jq -er '.result.node_info.id | ascii_downcase' <<<"$status")"
catching_up="$(jq -r '.result.sync_info.catching_up' <<<"$status")"
[[ "$catching_up" == true || "$catching_up" == false ]] \
  || { echo 'canonical_core_unavailable: local Core sync status is invalid' >&2; exit 1; }
height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$status")"
abci_info="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/abci_info)" \
  || { echo 'canonical_core_unavailable: local Core abci_info endpoint is unavailable' >&2; exit 1; }
# `status.node_info.version` is the embedded CometBFT version (for example
# 0.38.19), not the Gonka Core version selected by the JOIN profile.
actual_core_version="$(jq -er '.result.response.version' <<<"$abci_info")"
[[ "$actual_chain_id" == "$expected_chain_id" ]] \
  || { echo 'canonical_chain_id_mismatch: local Core serves another chain' >&2; exit 1; }
[[ "$actual_p2p_node_id" == "$expected_p2p_node_id" ]] \
  || { echo 'canonical_identity_mismatch: local Core serves another P2P identity' >&2; exit 1; }
[[ "$actual_core_version" == "$expected_core_version" ]] \
  || { echo 'canonical_core_version_mismatch: local Core version differs from generated profile' >&2; exit 1; }
[[ "$actual_core_commit" == "$expected_core_commit" ]] \
  || { echo 'canonical_core_commit_mismatch: local Core commit differs from generated profile' >&2; exit 1; }
[[ "$catching_up" == false && "$height" =~ ^[1-9][0-9]*$ ]] \
  || { echo 'canonical_core_not_synced: local Core has not reached a synchronized positive height' >&2; exit 1; }

api_container="$("${compose[@]}" ps -q api)"
[[ "$api_container" =~ ^[0-9a-f]{12,64}$ ]] \
  || { echo 'canonical_dapi_unavailable: API container is not running' >&2; exit 1; }
expected_dapi_image="$(awk -F= '$1 == "DAPI_IMAGE" {print substr($0, index($0, "=") + 1); exit}' "$deploy_dir/.env")"
[[ "$expected_dapi_image" == *@sha256:[0-9a-f]* && "$expected_dapi_image" =~ @sha256:[0-9a-f]{64}$ ]] \
  || { echo 'canonical_dapi_unavailable: rendered DAPI image is not digest-qualified' >&2; exit 1; }
expected_dapi_image_id="$(docker image inspect --format '{{.Id}}' "$expected_dapi_image")" \
  || { echo 'canonical_dapi_unavailable: rendered DAPI image is unavailable locally' >&2; exit 1; }
actual_dapi_image_id="$(docker inspect --format '{{.Image}}' "$api_container")" \
  || { echo 'canonical_dapi_unavailable: cannot inspect running DAPI image' >&2; exit 1; }
[[ "$actual_dapi_image_id" == "$expected_dapi_image_id" ]] \
  || { echo 'canonical_dapi_image_mismatch: running API does not match generated profile image' >&2; exit 1; }
dapi_exe="$(docker exec "$api_container" readlink -f /proc/1/exe)" \
  || { echo 'canonical_dapi_unavailable: cannot inspect DAPI pid 1 executable' >&2; exit 1; }
[[ "$dapi_exe" == /* ]] \
  || { echo 'canonical_dapi_unavailable: DAPI pid 1 executable is not absolute' >&2; exit 1; }
dapi_versions="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9000/v1/versions)" \
  || { echo 'canonical_dapi_unavailable: local DAPI versions endpoint is unavailable' >&2; exit 1; }
actual_dapi_version="$(jq -er '.api_version.version' <<<"$dapi_versions")"
actual_dapi_commit="$(jq -er '.api_version.commit | ascii_downcase' <<<"$dapi_versions")"
[[ "$actual_dapi_version" == "$expected_dapi_version" ]] \
  || { echo 'canonical_dapi_version_mismatch: local DAPI version differs from generated profile' >&2; exit 1; }
[[ "$actual_dapi_commit" == "$expected_dapi_commit" ]] \
  || { echo 'canonical_dapi_commit_mismatch: local DAPI commit differs from generated profile' >&2; exit 1; }
printf 'PASS canonical runtime verified signer=%s chain_id=%s node_id=%s height=%s core=%s core_commit=%s core_exe=%s dapi=%s dapi_commit=%s dapi_exe=%s\n' \
  "$expected_signer_state" "$actual_chain_id" "$actual_p2p_node_id" "$height" "$actual_core_version" "$actual_core_commit" "$core_exe" "$actual_dapi_version" "$actual_dapi_commit" "$dapi_exe"
