#!/usr/bin/env bash
# Read back a newly enabled signer before a JOIN can record it as active.
set -Eeuo pipefail

usage() { echo "Usage: $0 DEPLOY_DIR EXPECTED_CHAIN_ID EXPECTED_CORE_VERSION" >&2; }
[[ $# -eq 3 ]] || { usage; exit 2; }
deploy_dir="$1" expected_chain_id="$2" expected_core_version="$3"
[[ "$deploy_dir" =~ ^/[A-Za-z0-9_./-]+$ && "$expected_chain_id" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$expected_core_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
  || { echo 'invalid active signer verification input' >&2; exit 2; }
[[ -s "$deploy_dir/.env" && -s "$deploy_dir/compose.yaml" ]] || { echo 'active signer deployment is incomplete' >&2; exit 1; }

compose=(docker compose --env-file "$deploy_dir/.env" -f "$deploy_dir/compose.yaml")
mapfile -t signer_containers < <("${compose[@]}" ps -q tmkms)
[[ ${#signer_containers[@]} -eq 1 && "${signer_containers[0]}" =~ ^[0-9a-f]{12,64}$ ]] \
  || { echo 'active_signer_unavailable: expected exactly one TMKMS container' >&2; exit 1; }
running="$(docker inspect --format '{{.State.Running}}' "${signer_containers[0]}")" \
  || { echo 'active_signer_unavailable: cannot inspect TMKMS container' >&2; exit 1; }
[[ "$running" == true ]] || { echo 'active_signer_unavailable: TMKMS is not running' >&2; exit 1; }

node_container="$("${compose[@]}" ps -q node)"
[[ "$node_container" =~ ^[0-9a-f]{12,64}$ ]] || { echo 'active_signer_unavailable: Core container is not running' >&2; exit 1; }
core_exe="$(docker exec "$node_container" readlink -f /proc/1/exe)" \
  || { echo 'active_signer_unavailable: cannot inspect Core executable' >&2; exit 1; }
[[ "$core_exe" == /* ]] || { echo 'active_signer_unavailable: Core executable is not absolute' >&2; exit 1; }
status="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status)" \
  || { echo 'active_signer_unavailable: local Core status endpoint is unavailable' >&2; exit 1; }
abci="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/abci_info)" \
  || { echo 'active_signer_unavailable: local Core abci_info endpoint is unavailable' >&2; exit 1; }
[[ "$(jq -er '.result.node_info.network' <<<"$status")" == "$expected_chain_id" ]] \
  || { echo 'active_signer_chain_mismatch: Core serves another chain' >&2; exit 1; }
[[ "$(jq -r '.result.sync_info.catching_up' <<<"$status")" == false ]] \
  || { echo 'active_signer_core_not_synced: Core is still catching up' >&2; exit 1; }
[[ "$(jq -er '.result.response.version' <<<"$abci")" == "$expected_core_version" ]] \
  || { echo 'active_signer_core_version_mismatch: Core differs from generated profile' >&2; exit 1; }

signer_dir="$(awk -F= '$1 == "SIGNER_DIR" {print substr($0, index($0, "=") + 1); exit}' "$deploy_dir/.env")"
[[ "$signer_dir" =~ ^/srv/dai/signer/[a-z0-9][a-z0-9_-]*$ ]] \
  || { echo 'active_signer_unavailable: rendered signer directory is invalid' >&2; exit 1; }
state="$signer_dir/tmkms/state/priv_validator_state.json"
[[ -s "$state" ]] || { echo 'active_signer_unavailable: TMKMS signing state is absent' >&2; exit 1; }
jq -e '
  type == "object" and (keys | sort) == ["block_id","height","round","step"] and
  (.height | type == "string" and test("^[0-9]+$")) and
  (.round | type == "string" and test("^[0-9]+$")) and
  (.step | type == "number" and floor == . and . >= -128 and . <= 127)
' "$state" >/dev/null || { echo 'active_signer_unavailable: TMKMS signing state is invalid' >&2; exit 1; }
printf 'PASS active signer verified chain_id=%s core=%s core_exe=%s tmkms=%s state=%s\n' \
  "$expected_chain_id" "$expected_core_version" "$core_exe" "${signer_containers[0]}" "$state"
