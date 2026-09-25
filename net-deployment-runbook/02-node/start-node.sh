#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
[[ -s "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
enable_signer=''; canary=false
while (($#)); do
  case "$1" in
    --enable-signer) enable_signer=true ;;
    --canary) canary=true ;;
    *) echo "Usage: $0 [--canary] [--enable-signer]" >&2; exit 2 ;;
  esac
  shift
done
# Existing Genesis, restart and HA callers predate generated JOIN profiles and
# must retain their consensus signer.  Only a generated JOIN defaults to the
# explicit signerless lifecycle; callers may still request --enable-signer.
if [[ -z "$enable_signer" ]]; then
  profile_kind="$(awk -F= '$1 == "GDC_PROFILE_KIND" {print $2; exit}' "$HERE/.env")"
  if [[ "$profile_kind" == generated_join ]]; then
    enable_signer=false
  else
    enable_signer=true
  fi
fi
[[ "$canary" == false || "$enable_signer" == false ]] || { echo 'canary must not enable signer' >&2; exit 2; }
[[ "$canary" == false ]] || enable_signer=false
run_long() {
  local label="$1" log="$2" pid elapsed=0
  shift 2
  printf 'WAIT  %s elapsed=0s\n' "$label"
  "$@" >"$log" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    kill -0 "$pid" 2>/dev/null || break
    elapsed=$((elapsed + 30))
    printf 'WAIT  %s elapsed=%ss\n' "$label" "$elapsed"
  done
  if ! wait "$pid"; then tail -100 "$log" >&2; return 1; fi
}
files=(-f "$HERE/compose.yaml")
if [[ "$(cat "$HERE/.local-ml" 2>/dev/null || echo false)" == true ]]; then
  ml_variant="$(awk -F= '$1 == "MLNODE_COMPOSE_VARIANT" {print $2}' "$ENV_FILE")"
  case "${ml_variant:-nvidia}" in
    nvidia) files+=(-f "$HERE/compose.ml-local.yaml") ;;
    amd)
      amd_kfd_group="$(awk -F= '$1 == "AMD_KFD_GROUP_ID" {print $2; exit}' "$ENV_FILE")"
      amd_render_group="$(awk -F= '$1 == "AMD_RENDER_GROUP_ID" {print $2; exit}' "$ENV_FILE")"
      if [[ -n "$amd_kfd_group" && "$amd_kfd_group" == "$amd_render_group" ]]; then
        files+=(-f "$HERE/compose.ml-amd-single-group.yaml")
      else
        files+=(-f "$HERE/compose.ml-amd.yaml")
      fi
      ;;
    *) echo "unsupported MLNode Compose variant: $ml_variant" >&2; exit 1 ;;
  esac
fi
[[ -e "$HERE/.ha-enabled" ]] && files+=(-f "$HERE/compose.devshard-ha.yaml")
profiles=()
[[ "$enable_signer" == true ]] && profiles=(--profile signer)
# Any run without the signer must also disable the Core private-validator
# listener. The canary uses an unregistered local key; without the listener
# guard Core blocks waiting for a TMKMS socket that is correctly absent and
# the supposedly signerless canonical stack crash-loops.
signerless_env=()
[[ "$enable_signer" == false ]] && signerless_env=(env CONFIG_PRIV_VALIDATOR_LADDR=)
"${signerless_env[@]}" docker compose --env-file "$HERE/.env" "${profiles[@]}" "${files[@]}" config --quiet
# Images are pinned by digest, and a portable runtime exists only on the Host.
run_long 'pull node images' "$HERE/start.log" "${signerless_env[@]}" docker compose --env-file "$HERE/.env" "${profiles[@]}" "${files[@]}" pull --policy missing
printf 'WAIT  start node services\n'
services=()
[[ "$canary" == true ]] && services=(node)
if ! "${signerless_env[@]}" docker compose --env-file "$HERE/.env" "${profiles[@]}" "${files[@]}" up -d "${services[@]}" >>"$HERE/start.log" 2>&1; then
  tail -100 "$HERE/start.log" >&2
  exit 1
fi
[[ "$canary" == true ]] || "$HERE/sync-node-config.sh"
printf 'READY node services started signer_enabled=%s canary=%s\n' "$enable_signer" "$canary"
