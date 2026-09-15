#!/usr/bin/env bash
# Disposable Docker regression for the deleted-network failure. No SSH, real
# chain, validator keys, image downloads or deployment directories are used.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_image="$(docker image inspect -f '{{.Id}}' gdc-runbook-bats:local)"
scratch="$(mktemp -d)"
export GDC_HOME="$scratch/operator"
unset GDC_INTERNAL_DATA_ROOT GDC_ENV
source "$ROOT/scripts/recover-incident.sh"
project="gdc-services-${scratch##*.}"
project="${project,,}"
deploy="$scratch/deploy"; saved="$scratch/saved"
mkdir -p "$deploy/data" "$saved"
touch "$deploy/.env"
fixture_compose() { command docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" "$@"; }
cleanup() {
  fixture_compose -f "$deploy/compose.worker.yaml" down --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT
jq -cn --arg name "$project" --arg image "$fixture_image" '{name:$name,services:{
  node:{image:$image,entrypoint:["/bin/sh"],command:["-c","sleep 300","--","--priv_validator_laddr","tcp://0.0.0.0:26658"]},
  tmkms:{image:$image,entrypoint:["/bin/sh"],command:["-c","sleep 300"]}}}' >"$deploy/compose.yaml"
jq -cn --arg image "$fixture_image" '{services:{
  worker:{image:$image,entrypoint:["/bin/sh"],command:["-c","sleep 300"],volumes:["./data:/data"]},
  gateway:{image:$image,entrypoint:["/bin/sh"],command:["-c","sleep 300"],depends_on:{worker:{condition:"service_started"}}}}}' >"$deploy/compose.worker.yaml"
printf 'preserved auxiliary data\n' >"$deploy/data/fixture"
fixture_compose -f "$deploy/compose.worker.yaml" up -d --pull never >/dev/null
fixture_compose -f "$deploy/compose.worker.yaml" ps -q worker gateway >"$saved/orphans.running"
original_network="$(command docker network inspect -f '{{.Id}}' "$project"_default)"
fixture_compose -f "$deploy/compose.worker.yaml" stop >/dev/null
fixture_compose down >/dev/null
fixture_compose up -d --pull never >/dev/null
new_network="$(command docker network inspect -f '{{.Id}}' "$project"_default)"
[[ "$original_network" != "$new_network" ]]
old_worker="$(head -n 1 "$saved/orphans.running")"
if command docker start "$old_worker" >"$scratch/start-error" 2>&1; then
  echo 'fixture did not reproduce the deleted-network failure' >&2; exit 1
fi
grep -Fq 'not found' "$scratch/start-error"
mapfile -t chain_containers < <(fixture_compose ps -q node tmkms)
chain_before="$(command docker inspect "${chain_containers[@]}" | jq -c 'map({Id,started:.State.StartedAt}) | sort_by(.Id)')"
recovered_compose() { fixture_compose "$@"; }
start_services() { start_orphans; }
touch "$saved/enable.started" "$saved/import.complete"
# Lose the controller response after the actual replacement. The retry must
# work from the saved recipe, not from the now-deleted original container IDs.
docker() {
  command docker "$@"
  if [[ "$1" == compose && " $* " == *' up '* && ! -e "$saved/allow-retry" ]]; then return 73; fi
}
if (resume_enabled_services) >"$scratch/partial-error" 2>&1; then
  echo 'injected service failure was ignored' >&2; exit 1
fi
[[ -e "$saved/orphans.compose.json" && ! -e "$saved/enable.complete" ]]
! command docker inspect "$old_worker" >/dev/null 2>&1
touch "$saved/allow-retry"
resume_enabled_services
resume_enabled_services
[[ -e "$saved/enable.complete" && -e "$saved/orphans.complete" ]]
mapfile -t chain_containers < <(fixture_compose ps -q node tmkms)
[[ "$chain_before" == "$(command docker inspect "${chain_containers[@]}" | jq -c 'map({Id,started:.State.StartedAt}) | sort_by(.Id)')" ]]
mapfile -t workers < <(fixture_compose -f "$deploy/compose.worker.yaml" ps -q worker gateway)
[[ ${#workers[@]} == 2 ]]
command docker inspect "${workers[@]}" | jq -e --arg network "$new_network" --arg image "$fixture_image" \
  'all(.[]; .State.Running == true and .Image == $image
    and any(.NetworkSettings.Networks[]; .NetworkID == $network))' >/dev/null
[[ "$(<"$deploy/data/fixture")" == 'preserved auxiliary data' ]]
printf 'PASS real deleted-network recovery and interrupted service retry; chain containers and data unchanged\n'
