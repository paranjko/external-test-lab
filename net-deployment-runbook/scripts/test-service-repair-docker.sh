#!/usr/bin/env bash
# Real container lifecycle; SSH is a closed local transport, HOME is inherited.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE='alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
temporary="$(mktemp -d)"
projects=()
cleanup() {
  local project
  local -a ids
  for project in "${projects[@]}"; do
    mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=$project")
    ((${#ids[@]} == 0)) || docker rm -f "${ids[@]}" >/dev/null
  done
  printf 'Fixture evidence: %s\n' "$temporary"
}
trap cleanup EXIT
docker info >/dev/null
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" >/dev/null
mkdir -p "$temporary/bin" "$temporary/srv/dai/deploy"
cat >"$temporary/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 7 && "$1" == -T && "$2" == -o && "$3" == BatchMode=yes &&
   "$4" == -o && "$5" == ConnectTimeout=10 && "$6" == fixture ]] || exit 91
case "$7" in
  "sudo -n bash -s -- 'repair-plan' '' '' '' 'fixture'") action=repair-plan ;;
  "sudo -n bash -s -- 'repair' '' '' '' 'fixture'") action=repair ;;
  "sudo -n bash -s -- 'stop' '' '' '' 'fixture'") action=stop ;;
  "sudo -n bash -s -- 'start' '' '' '' 'fixture'") action=start ;;
  *) exit 92 ;;
esac
sed "s|/srv/dai|$REPAIR_TEST_ROOT/srv/dai|g" >"$REPAIR_TEST_ROOT/remote.sh"
bash "$REPAIR_TEST_ROOT/remote.sh" "$action" '' '' '' fixture
SH
cat >"$temporary/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == '-c %u' ]]; then printf '0\n'; else /usr/bin/stat "$@"; fi
SH
chmod 0755 "$temporary/bin/ssh" "$temporary/bin/stat"
export REPAIR_TEST_ROOT="$temporary"
run() { PATH="$temporary/bin:$PATH" bash "$ROOT/scripts/node-container-control.sh" "$1" fixture; }
fingerprint() { docker inspect --format '{{.Id}} {{.State.Running}} {{.State.Pid}} {{.State.StartedAt}}' "$@"; }
create() {
  local name="$1" service="$2" project="$3" directory="$4"
  docker create --name "$name" --network none \
    --label "com.docker.compose.project=$project" \
    --label "com.docker.compose.project.working_dir=$directory" \
    --label "com.docker.compose.service=$service" "$IMAGE" sh -c \
    'trap "exit 0" TERM INT; while :; do sleep 1; done'
}
for layout in canonical legacy; do
  project="repair-${temporary##*/}-$layout"
  deploy="$temporary/srv/dai/deploy"
  [[ "$layout" != legacy ]] || deploy="$deploy/fixture"
  mkdir -p "$deploy"
  # Legacy discovery deliberately requires project==SSH alias.
  [[ "$layout" != legacy ]] || project=fixture
  [[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]]
  projects+=("$project" "$project-edge")
  node="$(create "$project-node" node "$project" "$deploy")"
  signer="$(create "$project-signer" tmkms "$project" "$deploy")"
  ml="$(create "$project-ml" mlnode "$project" "$deploy")"
  proxy="$(create "$project-proxy" inference "$project" "$deploy")"
  foreign="$(create "$project-edge" caddy "$project-edge" "$temporary/independent")"
  docker start "$node" "$signer" "$ml" "$proxy" "$foreign" >/dev/null
  docker stop --time 1 "$ml" "$proxy" >/dev/null
  before="$(fingerprint "$node" "$signer" "$foreign")"
  run repair-plan
  [[ "$(docker inspect --format '{{.State.Running}}' "$ml")" == false ]]
  run repair
  [[ "$(fingerprint "$node" "$signer" "$foreign")" == "$before" ]]
  [[ "$(docker inspect --format '{{.State.Running}}' "$ml")" == true ]]
  [[ "$(docker inspect --format '{{.State.Running}}' "$proxy")" == true ]]
  after="$(fingerprint "$ml" "$proxy")"
  run repair
  [[ "$(fingerprint "$ml" "$proxy")" == "$after" ]]
  docker stop --time 1 "$ml" "$signer" >/dev/null
  if run repair; then echo 'stopped signer accepted' >&2; exit 1; fi
  [[ "$(docker inspect --format '{{.State.Running}}' "$ml")" == false ]]
  docker start "$signer" >/dev/null
  for record in stopped.json lent-ml.json; do
    printf '{}\n' >"$deploy/.node-control/$record"
    if run repair; then echo 'lifecycle receipt ignored' >&2; exit 1; fi
    [[ "$(docker inspect --format '{{.State.Running}}' "$ml")" == false ]]
    rm "$deploy/.node-control/$record"
  done
  # Preserve the pre-existing receipt-bound stop/start contract too.
  foreign_before="$(fingerprint "$foreign")"
  run stop
  [[ "$(docker inspect --format '{{.State.Running}}' "$node")" == false ]]
  [[ "$(docker inspect --format '{{.State.Running}}' "$signer")" == false ]]
  run start
  [[ "$(docker inspect --format '{{.State.Running}}' "$node")" == true ]]
  [[ "$(docker inspect --format '{{.State.Running}}' "$signer")" == true ]]
  [[ "$(docker inspect --format '{{.State.Running}}' "$ml")" == false ]]
  [[ "$(fingerprint "$foreign")" == "$foreign_before" ]]
  docker rm -f "$node" "$signer" "$ml" "$proxy" "$foreign" >/dev/null
  printf 'PASS service repair layout=%s; independent service and consensus identities preserved\n' "$layout"
done
