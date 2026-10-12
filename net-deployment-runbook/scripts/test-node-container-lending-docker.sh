#!/usr/bin/env bash
# Run the shipped container control against a real local Docker Compose
# project. This is intentionally Host-free: SSH is a closed local transport
# adapter and cleanup addresses only the fixture's random Compose projects.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE='alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
tmp="$(mktemp -d)"
projects=()

cleanup() {
  local project network
  local -a ids
  for project in "${projects[@]:-}"; do
    mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
    if ((${#ids[@]})); then
      docker rm -f "${ids[@]}" >/dev/null 2>&1 || true
    fi
    network="${project}_default"
    if docker network inspect "$network" >/dev/null 2>&1; then
      docker network rm "$network" >/dev/null 2>&1 || true
    fi
  done
  if [[ "${GDC_TEST_KEEP_TMP:-false}" == true ]]; then
    printf 'KEEP_TEST_TMP=%s\n' "$tmp" >&2
  else
    rm -rf -- "$tmp"
  fi
}
trap cleanup EXIT

command -v docker >/dev/null || { echo 'Docker is required for the local lending lifecycle fixture' >&2; exit 1; }
docker info >/dev/null || { echo 'local Docker daemon is unavailable for the lending lifecycle fixture' >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" >/dev/null
port_5000_state="$(ss -ltn 'sport = :5000')"
if [[ "$port_5000_state" == *':5000'* ]]; then
  echo 'local TCP port 5000 is occupied; cannot run the isolated lending lifecycle fixture' >&2
  exit 1
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == '-c %u' ]]; then
  printf '0\n'
else
  /usr/bin/stat "$@"
fi
SH
cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
command_text="${*: -1}"
quoted=()
while [[ "$command_text" =~ \'[^\']*\' ]]; do
  quoted_match="${BASH_REMATCH[0]}"
  quoted+=("${quoted_match:1:${#quoted_match}-2}")
  command_text="${command_text#*"$quoted_match"}"
done
[[ "${#quoted[@]}" == 4 ]] || { echo "unexpected fixture SSH command: $command_text" >&2; exit 91; }
remote="$GDC_TEST_ROOT/remote-${quoted[0]}.sh"
sed -e 's|/srv/dai/deploy|__GDC_TEST_DEPLOY__|g' \
  -e "s|/srv/dai|$GDC_TEST_ROOT/srv/dai|g" \
  -e "s|__GDC_TEST_DEPLOY__|$GDC_TEST_DEPLOY|g" >"$remote"
bash "$remote" "${quoted[@]}"
SH
chmod 0755 "$tmp/bin/stat" "$tmp/bin/ssh"

write_compose() {
  local deploy="$1" project="$2"
  mkdir -p "$deploy"
  chmod 0700 "$deploy"
  cat >"$deploy/compose.yaml" <<YAML
services:
  node:
    image: $IMAGE
    command: ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
  tmkms:
    image: $IMAGE
    command: ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
  mlnode:
    image: $IMAGE
    command: ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
  inference:
    image: $IMAGE
    command: ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
YAML
  cat >"$deploy/compose.ml-local.yaml" <<'YAML'
services:
  mlnode: {}
  inference: {}
YAML
  printf 'COMPOSE_PROJECT_NAME=%s\nMLNODE_COMPOSE_VARIANT=nvidia\n' "$project" >"$deploy/.env"
  printf 'true\n' >"$deploy/.local-ml"
}

docker_compose() {
  local log="$tmp/docker-compose.log"
  if ! docker compose "$@" >"$log" 2>&1; then
    sed -n '1,160p' "$log" >&2
    return 1
  fi
}

container_running() {
  local deploy="$1" service="$2" id state
  id="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" -f "$deploy/compose.ml-local.yaml" ps -aq "$service")"
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] || { echo "missing fixture container service=$service" >&2; return 1; }
  state="$(docker inspect --format '{{.State.Running}}' "$id")"
  [[ "$state" == true ]]
}

assert_state() {
  local deploy="$1" expected="$2" service
  for service in node tmkms mlnode inference; do
    if [[ "$(container_running "$deploy" "$service" && printf running || printf stopped)" != "$expected" ]]; then
      echo "unexpected fixture state service=$service expected=$expected" >&2
      return 1
    fi
  done
}

run_control() {
  local root="$1" deploy="$2" action="$3" log
  log="$tmp/node-control-${action}.log"
  shift 3
  if ! PATH="$tmp/bin:$PATH" GDC_TEST_ROOT="$root" GDC_TEST_DEPLOY="$deploy" \
    bash "$ROOT/scripts/node-container-control.sh" "$action" donor "$@" >"$log" 2>&1; then
    sed -n '1,200p' "$log" >&2
    return 1
  fi
}

run_case() {
  local layout="$1" root deploy project before_identity before_data inference_id
  root="$tmp/$layout"
  deploy="$root/srv/dai/deploy"
  [[ "$layout" == flat ]] || deploy="$deploy/legacy-donor"
  project="gdc-lending-${layout}-${RANDOM}${RANDOM}"
  projects+=("$project")
  mkdir -p "$root/srv/dai"
  printf 'identity-%s\n' "$layout" >"$root/srv/dai/identity-sentinel"
  printf 'chain-%s\n' "$layout" >"$root/srv/dai/data-sentinel"
  before_identity="$(sha256sum "$root/srv/dai/identity-sentinel" | awk '{print $1}')"
  before_data="$(sha256sum "$root/srv/dai/data-sentinel" | awk '{print $1}')"
  write_compose "$deploy" "$project"
  (
    cd "$deploy"
    docker_compose --env-file .env -f compose.yaml -f compose.ml-local.yaml up --pull never -d
  )
  assert_state "$deploy" running

  run_control "$root" "$deploy" stop
  assert_state "$deploy" stopped
  run_control "$root" "$deploy" lend parent.fixture 127.0.0.1 fixture-node
  container_running "$deploy" mlnode
  container_running "$deploy" inference
  if container_running "$deploy" node || container_running "$deploy" tmkms; then
    echo 'validator services remained running while its ML runtime was lent' >&2
    return 1
  fi
  jq -e --arg deploy "$deploy" '
    .schema_version == 1 and .kind == "gdc-lent-validator-ml" and
    .parent_alias == "parent.fixture" and .endpoint == "127.0.0.1" and
    .node_id == "fixture-node" and .deployment == $deploy
  ' "$deploy/.node-control/lent-ml.json" >/dev/null
  inference_id="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" -f "$deploy/compose.ml-local.yaml" ps -aq inference)"
  published_port="$(docker port "$inference_id" 5000)"
  [[ "$published_port" == *'0.0.0.0:5000'* || "$published_port" == *'[::]:5000'* ]]

  run_control "$root" "$deploy" reclaim
  assert_state "$deploy" stopped
  [[ ! -e "$deploy/.node-control/lent-ml.json" && ! -e "$deploy/.node-control/lent-ml-port.yaml" ]]
  run_control "$root" "$deploy" start
  assert_state "$deploy" running
  [[ ! -e "$deploy/.node-control/stopped.json" ]]
  [[ "$(sha256sum "$root/srv/dai/identity-sentinel" | awk '{print $1}')" == "$before_identity" ]]
  [[ "$(sha256sum "$root/srv/dai/data-sentinel" | awk '{print $1}')" == "$before_data" ]]
  docker_compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" -f "$deploy/compose.ml-local.yaml" down --volumes --remove-orphans
}

case "${1:-all}" in
  all)
    run_case flat
    run_case legacy
    coverage='flat and legacy'
    ;;
  flat|legacy)
    run_case "$1"
    coverage="$1"
    ;;
  *) echo "Usage: $0 [flat|legacy]" >&2; exit 2 ;;
esac
printf 'PASS real local Docker Compose lending lifecycle preserves %s validator state\n' "$coverage"
