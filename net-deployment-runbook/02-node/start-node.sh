#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -s "$HERE/.env" ]] || { echo "Missing $HERE/.env" >&2; exit 1; }
enable_signer=false; canary=false
while (($#)); do
  case "$1" in
    --enable-signer) enable_signer=true ;;
    --canary) canary=true ;;
    *) echo "Usage: $0 [--canary] [--enable-signer]" >&2; exit 2 ;;
  esac
  shift
done
[[ "$canary" == false || "$enable_signer" == false ]] || { echo 'canary must not enable signer' >&2; exit 2; }
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
[[ "$(cat "$HERE/.local-ml" 2>/dev/null || echo false)" == true ]] && files+=(-f "$HERE/compose.ml-local.yaml")
[[ -e "$HERE/.ha-enabled" ]] && files+=(-f "$HERE/compose.devshard-ha.yaml")
profiles=()
[[ "$enable_signer" == true ]] && profiles=(--profile signer)
canary_env=()
# CometBFT needs a validator key even while state-syncing.  The image creates
# an unregistered local key; blanking the remote listener ensures it cannot
# access the restored TMKMS signer before the post-sync checks pass.
[[ "$canary" == true ]] && canary_env=(env CONFIG_PRIV_VALIDATOR_LADDR=)
"${canary_env[@]}" docker compose --env-file "$HERE/.env" "${profiles[@]}" "${files[@]}" config --quiet
run_long 'pull node images' "$HERE/start.log" "${canary_env[@]}" docker compose --env-file "$HERE/.env" "${profiles[@]}" "${files[@]}" pull
printf 'WAIT  start node services\n'
services=()
[[ "$canary" == true ]] && services=(node)
if ! "${canary_env[@]}" docker compose --env-file "$HERE/.env" "${profiles[@]}" "${files[@]}" up -d "${services[@]}" >>"$HERE/start.log" 2>&1; then
  tail -100 "$HERE/start.log" >&2
  exit 1
fi
[[ "$canary" == true ]] || "$HERE/sync-node-config.sh"
printf 'READY node services started signer_enabled=%s canary=%s\n' "$enable_signer" "$canary"
