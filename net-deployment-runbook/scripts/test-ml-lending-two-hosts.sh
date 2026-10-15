#!/usr/bin/env bash
# Exercise lend and return between isolated Host aliases with mocked transport and canonical donor container state
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  if [[ "${GDC_TEST_KEEP_TMP:-false}" == true ]]; then
    printf 'KEEP_TEST_TMP=%s\n' "$tmp" >&2
  else
    rm -rf -- "$tmp"
  fi
}
trap cleanup EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$kit/02-node" "$kit/03-join" "$tmp/bin"
cp "$ROOT/scripts/phase-ml-lend.sh" "$ROOT/scripts/phase-node-lent-start.sh" "$ROOT/scripts/read-lent-ml-record.sh" \
  "$ROOT/scripts/detach-network-ml-host.sh" "$ROOT/scripts/node-container-control.sh" \
  "$ROOT/scripts/wait-dapi-worker-removal.sh" \
  "$ROOT/scripts/add-network-ml-endpoint.sh" "$ROOT/scripts/remove-network-ml-endpoint.sh" \
  "$kit/scripts/"
cp "$ROOT/02-node/sync-node-config.sh" "$kit/02-node/"
cat >"$kit/03-join/start-local-ml.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 9 && "$1" == "${GDC_CASE_DONOR:?}" ]]
printf 'start-local-ml:%s\n' "$*" >>"$GDC_TEST_EVENTS"
SH
chmod 0755 "$kit/03-join/start-local-ml.sh"

cat >"$kit/scripts/ensure-ml-callback.sh" <<'CALLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 3 && -n "$1" && -n "$2" && -n "$3" ]]
# The real callback transport and remote apply are exercised separately in
# test-ml-callback; this fixture isolates the lending/return state machine.
CALLBACK
cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${GDC_TEST_KIT:?}"
GDC_DATA_ROOT="${GDC_TEST_OPERATOR:?}"
GDC_HOME="$GDC_DATA_ROOT/operator"
STATE="$GDC_HOME/state"
load_project() { :; }
topology_contains_node() { [[ "$1" == "${GDC_CASE_PARENT:?}" ]]; }
ssh_ready() { [[ "$1" == "${GDC_CASE_PARENT:?}" || "$1" == "${GDC_CASE_DONOR:?}" ]]; }
die() { printf '%s\n' "$*" >&2; exit 1; }
step() { printf 'step:%s\n' "$*" >>"$GDC_TEST_EVENTS"; }
SH
cat >"$kit/scripts/check-running-network-node.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == "${GDC_CASE_PARENT:?}" ]]
printf 'parent-ready:%s\n' "$1" >>"$GDC_TEST_EVENTS"
SH
chmod 0755 "$kit/scripts"/*.sh

cat >"$tmp/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == '-c %u' ]]; then printf '0\n'; else /usr/bin/stat "$@"; fi
SH
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
state="$CONTROL_TEST_ROOT/containers.json"
set_state() { jq "$1" "$state" >"$state.tmp" && mv "$state.tmp" "$state"; }
case "$1" in
  ps) jq -r '.[].id' "$state" ;;
  inspect)
    id="${*: -1}"
    if [[ "$3" == '{{.State.Running}}' ]]; then
      jq -er --arg id "$id" '.[] | select(.id == $id) | .running | tostring' "$state"
    else
      jq -ce --arg id "$id" '.[] | select(.id == $id)' "$state"
    fi
    ;;
  stop|start)
    id="${*: -1}"
    if [[ "$1" == stop ]]; then
      set_state "map(if .id == \"$id\" then .running=false | .status=\"exited\" else . end)"
    else
      set_state "map(if .id == \"$id\" then .running=true | .status=\"running\" else . end)"
    fi
    ;;
  compose)
    command=" $* "
    if [[ "$command" == *' config '* ]]; then exit 0; fi
    if [[ "$command" == *' stop mlnode inference '* ]]; then
      set_state 'map(if .service == "mlnode" or .service == "inference" then .running=false | .status="exited" else . end)'
      exit 0
    fi
    if [[ "$command" == *' up '* ]]; then
      replacement="$(printf '%064d' 9)"
      set_state "map(if .service == \"inference\" then .id=\"$replacement\" | .running=true | .status=\"running\" elif .service == \"mlnode\" then .running=true | .status=\"running\" else . end)"
      exit 0
    fi
    echo "unexpected docker compose: $*" >&2; exit 97
    ;;
  *) echo "unexpected docker command: $*" >&2; exit 98 ;;
esac
SH
chmod 0755 "$tmp/bin/stat" "$tmp/bin/docker"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == -G ]]; then
  [[ "${2:-}" == "${GDC_CASE_DONOR:?}" && "${GDC_CASE_DISCOVERY_ALLOWED:?}" == true ]] || exit 91
  printf 'hostname %s\n' "$GDC_CASE_DISCOVERED_ENDPOINT"
  exit 0
fi
host=''
for arg in "$@"; do
  [[ "$arg" == "$GDC_CASE_PARENT" || "$arg" == "$GDC_CASE_DONOR" ]] && { host="$arg"; break; }
done
[[ -n "$host" ]] || exit 92
args="$*"
printf '%s|%s\n' "$host" "$args" >>"$GDC_TEST_SSH_LOG"

run_donor_control() {
  local action parent endpoint node_id remote root deploy
  case "$args" in
    *"'stop'"*) action=stop; parent=''; endpoint=''; node_id='' ;;
    *"'reclaim'"*) action=reclaim; parent=''; endpoint=''; node_id='' ;;
    *"'start'"*) action=start; parent=''; endpoint=''; node_id='' ;;
    *"'lend'"*)
      action=lend
      parent="${GDC_CASE_PARENT:?}"; endpoint="${GDC_CASE_ENDPOINT:?}"; node_id="${GDC_CASE_NODE_ID:?}"
      ;;
    *) exit 93 ;;
  esac
  root="${GDC_TEST_DONOR_ROOT:?}"; deploy="${GDC_TEST_DONOR_DEPLOY:?}"
  remote="$root/control-remote.sh"
  cat >"$remote"
  sed -i "s@/srv/dai/deploy@__GDC_TEST_DEPLOY__@g; s@/srv/dai@$root/srv/dai@g; s@__GDC_TEST_DEPLOY__@$deploy@g" "$remote"
  CONTROL_TEST_ROOT="$root" CONTROL_TEST_DEPLOY="$deploy" PATH="$(dirname "$0"):$PATH" \
    bash "$remote" "$action" "$parent" "$endpoint" "$node_id"
}

if [[ "$host" == "$GDC_CASE_DONOR" && "$args" == *'sudo -n bash -s --'* && "$args" != *gdc-lent-ml-record* ]]; then
  run_donor_control
  exit 0
fi

case "$host:$args" in
  "$GDC_CASE_DONOR":*'gdc-lent-ml-record'*)
    record="${GDC_TEST_DONOR_DEPLOY:?}/.node-control/lent-ml.json"
    [[ -f "$record" && ! -L "$record" ]] && cat "$record"
    ;;
  "$GDC_CASE_DONOR":*'test -s /srv/dai/identity/p2p/node_key.json'*)
    [[ "$args" != *'/srv/dai/deploy/compose.yaml'* ]] || exit 96
    exit 0
    ;;
  "$GDC_CASE_DONOR":*'lent-ml.json'*)
    record="${GDC_TEST_DONOR_DEPLOY:?}/.node-control/lent-ml.json"
    [[ -f "$record" ]] && cat "$record" || exit 10
    ;;
  "$GDC_CASE_DONOR":*'cat /srv/dai/deploy/node-config.json'*) cat "$GDC_TEST_DONOR_CONFIG" ;;
  "$GDC_CASE_PARENT":*'-o ConnectionAttempts=1 '*) exit 0 ;;
  "$GDC_CASE_PARENT":*'getent ahostsv4'*)
    if [[ "$GDC_CASE_ENDPOINT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$GDC_CASE_ENDPOINT"
    else
      printf '192.0.2.17\n'
    fi
    ;;
  "$GDC_CASE_PARENT":*'cat /srv/dai/deploy/node-config.json'*) cat "$GDC_TEST_PARENT_CONFIG" ;;
  "$GDC_CASE_PARENT":*'cat /srv/dai/deploy/gdc-ml-link.json'*) cat "$GDC_TEST_PARENT_LINK" ;;
  "$GDC_CASE_PARENT":*'/v1/models'*) printf '{"data":[]}' ;;
  "$GDC_CASE_PARENT":*'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes'*) jq '[.[] | {node:.}]' "$GDC_TEST_PARENT_DAPI" ;;
  "$GDC_CASE_PARENT":*'rm -rf'*'&& mkdir -p'*'gdc-ml-'*) rm -rf -- "$GDC_TEST_PARENT_STAGE"; mkdir -p "$GDC_TEST_PARENT_STAGE" ;;
  "$GDC_CASE_PARENT":*'install_path=/srv/dai/deploy/gdc-ml-link.json'*) cat >"$GDC_TEST_PARENT_LINK" ;;
  "$GDC_CASE_PARENT":*'node-config.json.tmp'*)
    cp "$GDC_TEST_PARENT_STAGE/node-config.json" "$GDC_TEST_PARENT_CONFIG"
    jq '[.[]]' "$GDC_TEST_PARENT_CONFIG" >"$GDC_TEST_PARENT_DAPI"
    if [[ -f "$GDC_TEST_PARENT_STAGE/gdc-ml-link.json" ]]; then
      cp "$GDC_TEST_PARENT_STAGE/gdc-ml-link.json" "$GDC_TEST_PARENT_LINK"
    fi
    ;;
  *) echo "unexpected ssh: $host $args" >&2; exit 96 ;;
esac
SH

cat >"$tmp/bin/scp" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -q && "$#" == 3 && "$3" == "${GDC_CASE_PARENT:?}":/tmp/gdc-ml-* ]] || exit 94
mkdir -p "$GDC_TEST_PARENT_STAGE"
cp "$2" "$GDC_TEST_PARENT_STAGE/$(basename "${3#*:}")"
SH
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/scp"

has_text() {
  local file="$1" expected="$2"
  [[ "$(<"$file")" == *"$expected"* ]]
}

setup_donor() {
  local root="$1" deploy="$2" project="$3" node signer mlnode inference
  mkdir -p "$deploy"
  printf '%s\n' true >"$deploy/.local-ml"
  printf '%s\n' 'MLNODE_COMPOSE_VARIANT=nvidia' >"$deploy/.env"
  : >"$deploy/compose.yaml"; : >"$deploy/compose.ml-local.yaml"
  printf 'identity-%s\n' "$project" >"$root/srv/dai/identity-sentinel"
  printf 'chain-%s\n' "$project" >"$root/srv/dai/data-sentinel"
  node="$(printf '%064d' 1)"; signer="$(printf '%064d' 2)"
  mlnode="$(printf '%064d' 3)"; inference="$(printf '%064d' 4)"
  jq -n --arg dir "$deploy" --arg project "$project" --arg node "$node" --arg signer "$signer" --arg mlnode "$mlnode" --arg inference "$inference" '[
    {id:$node,project:$project,working_dir:$dir,service:"node",running:true,status:"running"},
    {id:$signer,project:$project,working_dir:$dir,service:"tmkms",running:true,status:"running"},
    {id:$mlnode,project:$project,working_dir:$dir,service:"mlnode",running:true,status:"running"},
    {id:$inference,project:$project,working_dir:$dir,service:"inference",running:true,status:"running"}
  ]' >"$root/containers.json"
}

run_case() {
  local layout="$1" label="$2" parent="$3" donor="$4" endpoint="$5" discovered="$6" explicit="$7"
  local work operator donor_root donor_deploy donor_config parent_config parent_link parent_dapi parent_stage events ssh_log scp_log base node_id before_identity before_data
  work="$tmp/$layout-$label"; operator="$work/operator"; donor_root="$work/donor"
  donor_deploy="$donor_root/srv/dai/deploy"
  donor_config="$work/donor-node-config.json"
  parent_config="$work/node-config.json"; parent_link="$work/gdc-ml-link.json"; parent_dapi="$work/dapi.json"; parent_stage="$work/parent-stage"
  events="$work/events"; ssh_log="$work/ssh.log"; scp_log="$work/scp.log"
  mkdir -p "$operator" "$donor_root/srv/dai" "$parent_stage"
  setup_donor "$donor_root" "$donor_deploy" "project-$layout-$label"
  printf '%s\n' '{"id":"qwen3-0.6b:donor","host":"inference","models":{"Qwen/Qwen3-0.6B":{"args":["--tensor-parallel-size","1","--dtype","float16","--revision","c1899de289a04d12100db370d81485cdf75e47ca","--max-num-seqs","32","--gpu-memory-utilization","0.45","--max-model-len","2048","--kv-cache-dtype","auto","--kv-cache-memory-bytes","4294967296","--enforce-eager"]}}}' | jq -s . >"$donor_config"
  before_identity="$(sha256sum "$donor_root/srv/dai/identity-sentinel" | awk '{print $1}')"
  before_data="$(sha256sum "$donor_root/srv/dai/data-sentinel" | awk '{print $1}')"
  base="qwen3-4b:gonka-$layout-$label"; node_id="qwen3-0.6b:gonka-$layout-$label--$donor"
  printf '%s\n' "[{\"id\":\"$base\",\"host\":\"inference\",\"inference_port\":5000,\"poc_port\":5000,\"max_concurrent\":32,\"models\":{\"Qwen/Qwen3-4B-Instruct-2507\":{\"args\":[\"--revision\",\"4b-parent-revision\",\"--dtype\",\"half\",\"--max-num-seqs\",\"8\"]}}},{\"id\":\"$base--baseline\",\"host\":\"baseline.$label.test\",\"inference_port\":5000,\"poc_port\":5000}]" >"$parent_config"
  cp "$parent_config" "$parent_dapi"
  printf '%s\n' "{\"schema_version\":2,\"validator_alias\":\"$parent\",\"ml_hosts\":[{\"ssh_alias\":\"baseline-$label\",\"endpoint\":\"baseline.$label.test\",\"node_id\":\"$base--baseline\"}]}" >"$parent_link"
  : >"$events"; : >"$ssh_log"; : >"$scp_log"
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" GDC_TEST_EVENTS="$events" GDC_TEST_SSH_LOG="$ssh_log" GDC_TEST_SCP_LOG="$scp_log" \
    GDC_TEST_DONOR_ROOT="$donor_root" GDC_TEST_DONOR_DEPLOY="$donor_deploy" GDC_TEST_DONOR_CONFIG="$donor_config" GDC_TEST_PARENT_CONFIG="$parent_config" GDC_TEST_PARENT_LINK="$parent_link" GDC_TEST_PARENT_DAPI="$parent_dapi" GDC_TEST_PARENT_STAGE="$parent_stage" \
    GDC_CASE_PARENT="$parent" GDC_CASE_DONOR="$donor" GDC_CASE_ENDPOINT="$endpoint" GDC_CASE_NODE_ID="$node_id" GDC_CASE_DISCOVERED_ENDPOINT="$discovered" GDC_CASE_DISCOVERY_ALLOWED="$([[ -z "$explicit" ]] && printf true || printf false)" GDC_RUN_ID="fixture-$layout-$label" \
    bash "$kit/scripts/phase-ml-lend.sh" "$parent" "$explicit" "$donor" >"$work/lend.out"
  jq -e --arg id "$node_id" --arg host "$endpoint" 'any(.[]; .id == $id and .host == $host)' "$parent_dapi" >/dev/null
  jq -e --arg id "$node_id" --arg host "$endpoint" --slurpfile donor "$donor_config" '
    any(.[]; .id == $id and .host == $host and .models == $donor[0][0].models and .max_concurrent == 32)
    and any(.[]; .id | startswith("qwen3-4b:"))
    and any(.[]; .host | startswith("baseline."))
  ' "$parent_config" >/dev/null
  has_text "$events" "start-local-ml:$donor Qwen/Qwen3-0.6B c1899de289a04d12100db370d81485cdf75e47ca float16 1 32 0.45 2048 [\"--tensor-parallel-size\",\"1\",\"--dtype\",\"float16\",\"--revision\",\"c1899de289a04d12100db370d81485cdf75e47ca\",\"--max-num-seqs\",\"32\",\"--gpu-memory-utilization\",\"0.45\",\"--max-model-len\",\"2048\",\"--kv-cache-dtype\",\"auto\",\"--kv-cache-memory-bytes\",\"4294967296\",\"--enforce-eager\"]"
  jq -e 'all(.[]; if .service == "mlnode" or .service == "inference" then .running else (.running | not) end)' "$donor_root/containers.json" >/dev/null
  [[ -f "$donor_deploy/.node-control/lent-ml.json" ]]
  # Operator-side association files are caches only. The remote donor record
  # and the parent deployment record remain the two authorities needed to
  # return a lent validator after an operator-state loss.
  rm -f -- "$operator/operator/state/ml-attached/$parent.json" "$operator/$donor/state/ml-parent.json"
  [[ ! -e "$operator/operator/state/ml-attached/$parent.json" && ! -e "$operator/$donor/state/ml-parent.json" ]]
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" GDC_TEST_EVENTS="$events" GDC_TEST_SSH_LOG="$ssh_log" GDC_TEST_SCP_LOG="$scp_log" \
    GDC_TEST_DONOR_ROOT="$donor_root" GDC_TEST_DONOR_DEPLOY="$donor_deploy" GDC_TEST_DONOR_CONFIG="$donor_config" GDC_TEST_PARENT_CONFIG="$parent_config" GDC_TEST_PARENT_LINK="$parent_link" GDC_TEST_PARENT_DAPI="$parent_dapi" GDC_TEST_PARENT_STAGE="$parent_stage" \
    GDC_CASE_PARENT="$parent" GDC_CASE_DONOR="$donor" GDC_CASE_ENDPOINT="$endpoint" GDC_CASE_NODE_ID="$node_id" GDC_CASE_DISCOVERED_ENDPOINT="$discovered" GDC_CASE_DISCOVERY_ALLOWED=false GDC_RUN_ID="fixture-$layout-$label" \
    bash "$kit/scripts/phase-node-lent-start.sh" "$donor" >"$work/start.out"
  jq -e --arg id "$node_id" 'all(.[]; .id != $id)' "$parent_dapi" >/dev/null
  jq -e --arg baseline "baseline-$label" '([.ml_hosts[].ssh_alias] | sort) == [$baseline]' "$parent_link" >/dev/null
  jq -e 'all(.[]; .running)' "$donor_root/containers.json" >/dev/null
  [[ ! -e "$donor_deploy/.node-control/lent-ml.json" && ! -e "$donor_deploy/.node-control/stopped.json" ]]
  [[ "$(sha256sum "$donor_root/srv/dai/identity-sentinel" | awk '{print $1}')" == "$before_identity" ]]
  [[ "$(sha256sum "$donor_root/srv/dai/data-sentinel" | awk '{print $1}')" == "$before_data" ]]
  has_text "$ssh_log" "$parent|"; has_text "$ssh_log" "$donor|"
  [[ -z "$explicit" ]] || ! has_text "$ssh_log" '-G '
}

run_case flat alpha controller.alpha accelerator-west_2 gpu-west.alpha.test gpu-west.alpha.test ''
run_case flat beta validator-z9 gpu-borrower 198.51.100.37 ignored.test 198.51.100.37
printf 'PASS two-Host ML lending and return preserve validator identity/data in the canonical directory\n'
