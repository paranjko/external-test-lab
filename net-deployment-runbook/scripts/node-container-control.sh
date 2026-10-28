#!/usr/bin/env bash
# Control existing containers only. JOIN remains the authority for first start.
set -Eeuo pipefail
action="${1:-}"
host="${2:-}"
case "$action" in
  start|stop|reclaim|repair-plan|repair)
    [[ $# == 2 ]]
    ;;
  lend)
    [[ $# == 5 && "${3:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${4:-}" =~ ^[A-Za-z0-9.-]+$ && "${5:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
    ;;
  *) exit 2 ;;
esac
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$host" "sudo -n bash -s -- '$action' '${3:-}' '${4:-}' '${5:-}' '$host'" <<'REMOTE'
set -Eeuo pipefail
umask 077
action="$1"
parent="${2:-}"
endpoint="${3:-}"
node_id="${4:-}"
node_alias="${5:-}"
fail() { printf 'ERROR %s\n' "$*" >&2; exit 1; }
[[ "$node_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 'invalid Host alias'
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
# Accept the canonical layout or this Host's exact legacy per-alias directory.
# Other nested deployments and mixed layouts are refused before any container
# is selected or changed.
jq -e --arg root /srv/dai/deploy --arg alias "$node_alias" '
  all(.[]; .service != "node" or (.working_dir | type == "string")) and
  all(.[] | select(.service == "node");
    .working_dir == $root or .working_dir == ($root + "/" + $alias)) and
  all(.[] | select(.service == "node"); .working_dir != "/srv/dai/node" and
    ((.working_dir | startswith("/srv/dai/node/")) | not))
' <<<"$inventory" >/dev/null || fail 'unsupported or mixed validator deployment directories; no containers changed'
candidates="$(jq -c --arg root /srv/dai/deploy --arg alias "$node_alias" '[.[] | select(.service == "node") |
  select(.working_dir == $root or .working_dir == ($root + "/" + $alias))]' <<<"$inventory")"
[[ "$(jq length <<<"$candidates")" == 1 ]] \
  || fail 'expected exactly one installed node deployment in a supported layout; none or multiple found; no containers changed'
discovered="$(jq -er '.[0].working_dir' <<<"$candidates")"
[[ -z "${deploy:-}" || "$deploy" == "$discovered" ]] || fail 'deployment changed during discovery; no containers changed'
deploy="$discovered"
project="$(jq -r '.[0].project' <<<"$candidates")"
[[ "$project" != null && -n "$project" ]] || fail 'Core deployment has no Compose project label; no containers changed'
if [[ "$deploy" == "/srv/dai/deploy/$node_alias" && "$project" != "$node_alias" ]]; then
  fail 'legacy Host deployment project must match its SSH alias; no containers changed'
fi
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
repair_selection() {
  [[ ! -e "$control/stopped.json" && ! -L "$control/stopped.json" &&
     ! -e "$control/lent-ml.json" && ! -L "$control/lent-ml.json" ]] \
    || fail 'controlled stop or ML lending is recorded; use its ordinary lifecycle'
  jq -e '
    ([.[] | select(.service == "tmkms")] | length) == 1 and
    all(.[]; ((.service == "node" or .service == "tmkms") | not) or .running)
  ' <<<"$inventory" >/dev/null || fail 'service repair requires an already running Core and signer'
  repair_targets="$(jq -c '[.[] | select(.status == "exited") |
    select(.service == "mlnode" or .service == "inference" or .service == "proxy" or
      .service == "versiond-router" or .service == "edge-api" or .service == "explorer")] |
    sort_by(if .service == "mlnode" then 0 elif .service == "inference" then 1 else 2 end)' <<<"$inventory")"
}
if [[ "$action" == repair-plan ]]; then
  repair_selection
  jq -r '.[] | "PLAN start service=\(.service) container=\(.id)"' <<<"$repair_targets"
  printf 'PLAN existing containers only; Core, signer, configurations and independent services remain unchanged\n'
  exit 0
fi
mkdir -p "$control"
[[ "$(stat -c %u "$control")" == 0 && "$(stat -c %a "$control")" == 700 ]] || fail 'node control directory must be root-owned mode 0700'
mkdir "$control/lock" 2>/dev/null || fail 'another node control operation is running; inspect the Host before removing a stale .node-control/lock'
trap 'rmdir "$control/lock"' EXIT
receipt="$control/stopped.json"
[[ ! -L "$receipt" ]] || fail 'unsafe stop receipt'
lent="$control/lent-ml.json"
overlay="$control/lent-ml-port.yaml"
[[ ! -L "$lent" && ! -L "$overlay" ]] || fail 'unsafe lending control record'
compose_files() {
  compose=(-f "$deploy/compose.yaml")
  [[ "$(cat "$deploy/.local-ml" 2>/dev/null || printf false)" == true ]] || fail 'installed validator has no local ML runtime to lend'
  variant="$(awk -F= '$1 == "MLNODE_COMPOSE_VARIANT" {print $2; exit}' "$deploy/.env")"
  case "${variant:-nvidia}" in
    nvidia) compose+=(-f "$deploy/compose.ml-local.yaml") ;;
    amd)
      kfd="$(awk -F= '$1 == "AMD_KFD_GROUP_ID" {print $2; exit}' "$deploy/.env")"
      render="$(awk -F= '$1 == "AMD_RENDER_GROUP_ID" {print $2; exit}' "$deploy/.env")"
      if [[ -n "$kfd" && "$kfd" == "$render" ]]; then
        compose+=(-f "$deploy/compose.ml-amd-single-group.yaml")
      else
        compose+=(-f "$deploy/compose.ml-amd.yaml")
      fi
      ;;
    *) fail 'installed validator has an unsupported local ML runtime variant' ;;
  esac
  for ((compose_index = 1; compose_index < ${#compose[@]}; compose_index += 2)); do
    file="${compose[$compose_index]}"
    [[ -f "$file" ]] || fail 'installed validator local ML compose file is unavailable'
  done
}

capture_stopped_receipt() {
  jq '.' <<<"$inventory" >"$control/stopped.tmp"
  chmod 600 "$control/stopped.tmp"
  mv -f "$control/stopped.tmp" "$receipt"
}

stop_receipted_containers() {
  local order id
  order="$(jq -r 'map(select(.running)) | sort_by(if .service == "tmkms" then 0 elif .service == "node" then 1 else 2 end) | .[].id' <<<"$inventory")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    printf 'WAIT stopping container=%s timeout=60s\n' "$id"
    docker stop --time 60 "$id" >/dev/null
    [[ "$(docker inspect --format '{{.State.Running}}' "$id")" == false ]] || fail "container did not stop: $id"
  done <<<"$order"
}

# Discovery runs before locking; refresh state under the lock so a concurrent
# completed start cannot leave stop acting on an earlier stopped snapshot.
discover_deployment

if [[ "$action" == repair ]]; then
  repair_selection
  consensus_ids="$(jq -r '.[] | select(.service == "node" or .service == "tmkms") | .id' <<<"$inventory")"
  consensus_identity() {
    local consensus_id
    while IFS= read -r consensus_id; do
      docker inspect --format '{{.Id}} {{.State.Running}} {{.State.Pid}} {{.State.StartedAt}}' "$consensus_id"
    done <<<"$consensus_ids"
  }
  consensus_before="$(consensus_identity)"
  repair_receipt="$(mktemp "$control/service-repair.XXXXXXXX.json")"
  jq -n --arg deployment "$deploy" --arg consensus "$consensus_before" \
    --argjson targets "$repair_targets" \
    '{kind:"gdc-service-repair",deployment:$deployment,consensus_before:$consensus,targets:$targets}' >"$repair_receipt"
  printf 'RECEIPT %s\n' "$repair_receipt"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$(consensus_identity)" == "$consensus_before" ]] || fail 'consensus changed during service repair; remaining starts cancelled'
    printf 'WAIT starting non-consensus container=%s\n' "$id"
    docker start "$id" >/dev/null
    [[ "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]] || fail "service did not remain running: $id"
  done < <(jq -r '.[].id' <<<"$repair_targets")
  [[ "$(consensus_identity)" == "$consensus_before" ]] || fail 'consensus changed during service repair; inspect receipt'
  printf 'PASS existing service containers started without restarting Core or signer; readiness requires separate verification\n'
  exit 0
fi

# Lending owns the controlled stop.  Validate the local ML runtime while the
# validator is still running; otherwise a missing overlay or ML container
# would leave a usable validator unnecessarily stopped before this phase can
# tell the operator why it cannot lend.
if [[ "$action" == lend && ! -f "$receipt" ]]; then
  [[ ! -e "$lent" ]] || fail 'lent validator ML record exists without a controlled-stop receipt'
  compose_files
  jq -e '
    any(.[]; .service == "node" and .running) and
    any(.[]; .service == "tmkms" and .running) and
    ([.[] | select(.service == "mlnode" or .service == "inference")] | length) == 2 and
    all(.[]; ((.service == "mlnode" or .service == "inference") | not) or .running)
  ' <<<"$inventory" >/dev/null || fail 'installed validator has no running local ML runtime to lend'
  capture_stopped_receipt
  stop_receipted_containers
fi

if [[ "$action" == stop && ! -e "$receipt" ]]; then
  capture_stopped_receipt
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

replace_ml_receipt_entries() {
  local replacement
  replacement="$(jq -c --argjson current "$inventory" '
    def identity: map({id,project,working_dir,service}) | sort_by(.id);
    def without_ml: map(select(.service != "mlnode" and .service != "inference"));
    ($current | without_ml | identity) as $current_non_ml |
    (without_ml | identity) as $receipt_non_ml |
    ($current | map(select(.service == "mlnode" or .service == "inference"))) as $current_ml |
    if $receipt_non_ml != $current_non_ml or ($current_ml | length) != 2 or
       ([ $current_ml[].service ] | sort) != ["inference", "mlnode"] then error("unexpected container replacement")
    else map(. as $prior | if .service == "mlnode" or .service == "inference"
             then (($current_ml[] | select(.service == $prior.service))
                   | .running = $prior.running | .status = $prior.status)
             else . end)
    end
  ' "$receipt")" || fail 'lending changed a non-ML container or ML container set'
  jq -e --argjson current "$inventory" '
    def identities: map({id,project,working_dir,service}) | sort_by(.id);
    identities == ($current | identities)
  ' <<<"$replacement" >/dev/null || fail 'lending receipt does not bind the running container set'
  printf '%s\n' "$replacement" >"$control/stopped.tmp"
  chmod 600 "$control/stopped.tmp"
  mv -f "$control/stopped.tmp" "$receipt"
}

require_controlled_validator_stopped() {
  local message="$1"
  # A retained receipt proves the state captured during stop, not the state
  # after an operator has bypassed the controller. Re-read Core and TMKMS
  # before either exposing or reclaiming the ML runtime.
  read_containers
  inventory="$(jq -c --arg deploy "$deploy" --arg project "$project" '[.[] | select(.working_dir == $deploy or .project == $project)]' <<<"$inventory")"
  jq -e 'all(.[]; ((.service == "node" or .service == "tmkms") | not) or (.running | not))' <<<"$inventory" >/dev/null \
    || fail "$message"
}

if [[ "$action" == lend ]]; then
  [[ -f "$receipt" ]] || fail 'lending requires a controlled stopped validator receipt'
  if [[ -f "$lent" ]]; then
    jq -e --arg parent "$parent" --arg endpoint "$endpoint" --arg node_id "$node_id" --arg deploy "$deploy" '
      .schema_version == 1 and .kind == "gdc-lent-validator-ml" and
      .parent_alias == $parent and .endpoint == $endpoint and .node_id == $node_id and .deployment == $deploy
    ' "$lent" >/dev/null && {
      printf 'PASS validator ML runtime is already lent to %s\n' "$parent"
      exit 0
    }
    fail 'validator ML runtime is already lent to another parent'
  fi
  # An interrupted lend may be retried, but only while the stopped validator
  # is still actually stopped. A manual Core or TMKMS start after the receipt
  # is created invalidates that transition; do not expose ML to a parent while
  # the same validator may be signing or serving locally.
  require_controlled_validator_stopped 'controlled validator is no longer stopped; refuse lending after an interrupted transition'
  jq -e 'all(.[]; ((.service == "mlnode" or .service == "inference") | not) or .running) and
    ([.[] | select(.service == "mlnode" or .service == "inference")] | length) == 2' "$receipt" >/dev/null \
    || fail 'controlled validator receipt has no running local ML runtime to lend'
  compose_files
  cat >"$overlay" <<'EOF'
services:
  inference:
    ports:
      - "0.0.0.0:5000:5000/tcp"
EOF
  chmod 600 "$overlay"
  docker compose --env-file "$deploy/.env" "${compose[@]}" -f "$overlay" config --quiet
  docker compose --env-file "$deploy/.env" "${compose[@]}" -f "$overlay" up --pull never -d mlnode inference
  read_containers
  inventory="$(jq -c --arg deploy "$deploy" --arg project "$project" '[.[] | select(.working_dir == $deploy or .project == $project)]' <<<"$inventory")"
  replace_ml_receipt_entries
  jq -cn --arg parent "$parent" --arg endpoint "$endpoint" --arg node_id "$node_id" --arg deploy "$deploy" \
    --arg receipt_sha256 "$(sha256sum "$receipt" | awk '{print $1}')" \
    '{schema_version:1,kind:"gdc-lent-validator-ml",parent_alias:$parent,endpoint:$endpoint,node_id:$node_id,deployment:$deploy,stopped_receipt_sha256:$receipt_sha256}' \
    >"$control/lent-ml.tmp"
  chmod 600 "$control/lent-ml.tmp"
  mv -f "$control/lent-ml.tmp" "$lent"
  printf 'PASS stopped validator ML runtime is lent to %s\n' "$parent"
  exit 0
fi

if [[ "$action" == reclaim ]]; then
  [[ -f "$lent" ]] || fail 'no retained lent validator ML runtime exists'
  jq -e --arg deploy "$deploy" '
    .schema_version == 1 and .kind == "gdc-lent-validator-ml" and .deployment == $deploy and
    (.parent_alias | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.endpoint | test("^[A-Za-z0-9.-]+$")) and
    (.node_id | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))
  ' "$lent" >/dev/null || fail 'invalid lent validator ML record'
  require_controlled_validator_stopped 'controlled validator is no longer stopped; refuse reclaim while the validator may be signing'
  compose_files
  [[ -f "$overlay" ]] || fail 'lent validator ML overlay is unavailable'
  docker compose --env-file "$deploy/.env" "${compose[@]}" -f "$overlay" stop mlnode inference
  rm -f "$overlay"
  docker compose --env-file "$deploy/.env" "${compose[@]}" up --pull never --force-recreate -d mlnode inference
  docker compose --env-file "$deploy/.env" "${compose[@]}" stop mlnode inference
  read_containers
  inventory="$(jq -c --arg deploy "$deploy" --arg project "$project" '[.[] | select(.working_dir == $deploy or .project == $project)]' <<<"$inventory")"
  replace_ml_receipt_entries
  rm -f "$lent"
  printf 'PASS lent validator ML runtime is reclaimed and remains stopped for node start\n'
  exit 0
fi

[[ ! -e "$lent" ]] || fail 'validator ML runtime is lent; detach its recorded parent before starting the validator'

if [[ "$action" == stop ]]; then
  # Signer first, Core second, then the application stack. Keep the receipt
  # through errors and repeated stops so a later start restores the same set.
  stop_receipted_containers
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
