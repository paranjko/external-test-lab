#!/usr/bin/env bash
# Control existing containers only. JOIN remains the authority for first start.
set -Eeuo pipefail
action="${1:-}"
host="${2:-}"
[[ $# == 2 && "$action" =~ ^(start|stop)$ && "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$host" "sudo -n bash -s -- '$action'" <<'REMOTE'
set -Eeuo pipefail
umask 077
action="$1"
fail() { printf 'ERROR %s\n' "$*" >&2; exit 1; }
for dependency in docker jq; do command -v "$dependency" >/dev/null || fail "missing Host dependency: $dependency"; done
for path in /srv/dai /srv/dai/deploy; do
  [[ -d "$path" && ! -L "$path" ]] || fail "missing or unsafe deployment directory: $path"
done
# Inspect selected public Docker fields, never keys or container environments.
read_containers() {
  ids="$(docker ps -aq --no-trunc --filter label=com.docker.compose.project)"
  [[ -n "$ids" ]] || fail 'no installed node containers; use JOIN to deploy the Host'
  inventory='[]'
  while IFS= read -r id; do
    [[ "$id" =~ ^[a-f0-9]{64}$ ]] || fail 'invalid container ID'
    item="$(docker inspect --format '{"id":{{json .Id}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"working_dir":{{json (index .Config.Labels "com.docker.compose.project.working_dir")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}},"status":{{json .State.Status}},"running":{{json .State.Running}}}' "$id")"
    inventory="$(jq -cn --argjson old "$inventory" --argjson item "$item" '$old + [$item]')"
  done <<<"$ids"
}
discover_deployment() {
read_containers
# The SSH alias need not equal the original Compose project or directory name.
# Discover the single Core deployment, accepting both supported layouts without
# migrating files. Never guess between two installed validator deployments.
candidates="$(jq -c --arg root /srv/dai/deploy '[.[] | select(.service == "node") |
  select(.working_dir | type == "string") |
  select(.working_dir == $root or
    (.working_dir | startswith($root + "/") and
      (ltrimstr($root + "/") | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))))]' <<<"$inventory")"
[[ "$(jq length <<<"$candidates")" == 1 ]] \
  || fail 'expected one installed node deployment in the supported layouts; none or multiple found; no containers changed'
discovered="$(jq -er '.[0].working_dir' <<<"$candidates")"
[[ -z "${deploy:-}" || "$deploy" == "$discovered" ]] || fail 'deployment changed during discovery; no containers changed'
deploy="$discovered"
project="$(jq -er '.[0].project' <<<"$candidates")"
[[ -d "$deploy" && ! -L "$deploy" ]] || fail 'missing or unsafe discovered deployment directory'
inventory="$(jq -c --arg deploy "$deploy" --arg project "$project" '[.[] | select(.working_dir == $deploy or .project == $project)]' <<<"$inventory")"
jq -e --arg deploy "$deploy" 'all(.[]; .working_dir == $deploy) and
  ([.[].project] | unique | length) == 1 and ([.[] | select(.service == "node")] | length) == 1 and
  ([.[] | select(.service == "tmkms")] | length) <= 1 and
  all(.[]; .status == "running" or .status == "exited" or .status == "created")' <<<"$inventory" >/dev/null \
  || fail 'ambiguous or busy deployment; no container was changed'
}
discover_deployment
printf 'READY discovered node deployment=%s\n' "$deploy"
control="$deploy/.node-control"
[[ ! -L "$control" ]] || fail 'unsafe node control directory'
mkdir -p "$control"
[[ "$(stat -c %u "$control")" == 0 && "$(stat -c %a "$control")" == 700 ]] || fail 'node control directory must be root-owned mode 0700'
mkdir "$control/lock" 2>/dev/null || fail 'another node control operation is running; inspect the Host before removing a stale .node-control/lock'
trap 'rmdir "$control/lock"' EXIT
receipt="$control/stopped.json"
[[ ! -L "$receipt" ]] || fail 'unsafe stop receipt'
# Discovery runs before locking; refresh state under the lock so a concurrent
# completed start cannot leave stop acting on an earlier stopped snapshot.
discover_deployment

if [[ "$action" == stop && ! -e "$receipt" ]]; then
  jq '.' <<<"$inventory" >"$control/stopped.tmp"
  mv "$control/stopped.tmp" "$receipt"
fi
if [[ ! -f "$receipt" ]]; then
  # Starting a previously fenced signer is a recovery decision, not restart.
  jq -e 'all(.[]; .running or .status == "created") and any(.[]; .service == "node" and .running)' <<<"$inventory" >/dev/null \
    || fail 'no controlled-stop receipt; use the retained JOIN recovery for stopped containers, not an unverified signer restart'
  printf 'PASS node already running; no containers changed\n'
  exit 0
fi
[[ "$(stat -c %u "$receipt")" == 0 && "$(stat -c %a "$receipt")" == 600 ]] || fail 'unsafe stop receipt ownership or permissions'
jq -e --argjson current "$inventory" '
  def identities: map({id,project,working_dir,service}) | sort_by(.id);
  type == "array" and all(.[]; (.running | type) == "boolean") and
  (identities) == ($current | identities)
' "$receipt" >/dev/null || fail 'containers changed since stop; use JOIN recovery without starting a replacement signer'

if [[ "$action" == stop ]]; then
  # Signer first, Core second, then the application stack. Keep the receipt
  # through errors and repeated stops so a later start restores the same set.
  order="$(jq -r 'map(select(.running)) | sort_by(if .service == "tmkms" then 0 elif .service == "node" then 1 else 2 end) | .[].id' <<<"$inventory")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    printf 'WAIT stopping container=%s timeout=60s\n' "$id"
    docker stop --time 60 "$id" >/dev/null
    [[ "$(docker inspect --format '{{.State.Running}}' "$id")" == false ]] || fail "container did not stop: $id"
  done <<<"$order"
  printf 'PASS node stopped; containers, images, keys and signing state retained\n'
else
  jq -e 'any(.[]; .service == "node" and .running)' "$receipt" >/dev/null \
    || fail 'Core was not running before stop; use JOIN recovery rather than claiming a node restart'
  order="$(jq -r 'map(select(.running)) | sort_by(if .service == "tmkms" then 2 elif .service == "node" then 1 else 0 end) | .[].id' "$receipt")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    printf 'WAIT starting container=%s\n' "$id"
    docker start "$id" >/dev/null
  done <<<"$order"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]] || fail "container did not remain running: $id"
  done <<<"$order"
  rm "$receipt"
  printf 'PASS previously running node containers restarted; synchronization and consensus require separate verification\n'
fi
REMOTE
