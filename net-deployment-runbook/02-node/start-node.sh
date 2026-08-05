#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -s "$HERE/.env" ]] || { echo "Missing $HERE/.env" >&2; exit 1; }
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
docker compose --env-file "$HERE/.env" "${files[@]}" config --quiet
run_long 'pull node images' "$HERE/start.log" docker compose --env-file "$HERE/.env" "${files[@]}" pull
printf 'WAIT  start node services\n'
if ! docker compose --env-file "$HERE/.env" "${files[@]}" up -d >>"$HERE/start.log" 2>&1; then
  tail -100 "$HERE/start.log" >&2
  exit 1
fi
"$HERE/sync-node-config.sh"
printf 'READY node services started\n'
