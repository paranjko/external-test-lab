#!/usr/bin/env bash
# Exercise the installer against a strict mock transport, plus an isolated
# Docker Compose project lifecycle on a unique local network.
set -Eeuo pipefail
trap 'printf "FAIL test line=%s command=%s\\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
keep_tmp="${GDC_TEST_KEEP_TMP:-false}"
for gdc_variable in ${!GDC_@}; do unset "$gdc_variable"; done
unset CHAIN_ID
GDC_TEST_KEEP_TMP="$keep_tmp"
cleanup() { if [[ "${GDC_TEST_KEEP_TMP:-false}" == true ]]; then printf 'KEEP_TEST_TMP=%s\n' "$tmp" >&2; else rm -rf -- "$tmp"; fi; }
trap cleanup EXIT
canonical_plan_hash() {
  local compact character canonical='' in_string=false escaped=false
  jq -e '[.. | numbers | tostring | select(test("[eE]"))] | length == 0' "$1" >/dev/null || return 1
  compact="$(jq -S -c . "$1")"
  if printf '%s' "$compact" | LC_ALL=C grep -q '[^ -~]'; then return 1; fi
  while IFS= read -r -n1 character; do
    if [[ "$escaped" == true ]]; then canonical+="$character"; escaped=false
    elif [[ "$in_string" == true ]]; then
      canonical+="$character"
      if [[ "$character" == $'\\' ]]; then escaped=true
      elif [[ "$character" == '"' ]]; then in_string=false
      fi
    elif [[ "$character" == '"' ]]; then canonical+="$character"; in_string=true
    elif [[ "$character" == ',' || "$character" == ':' ]]; then canonical+="$character "
    else canonical+="$character"
    fi
  done < <(printf '%s' "$compact")
  [[ "$in_string" == false && "$escaped" == false ]] || return 1
  printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}
printf '%s\n' '{"z":"x","quote":"a\"b\\c","a":[1,1.0,1.25,true,null]}' >"$tmp/canonical-fixture.json"
[[ "$(canonical_plan_hash "$tmp/canonical-fixture.json")" == \
  'ae93c6006d4f8a0468ae16c773fc53480ab7e694cec8c19c8a391ccf4fadd4b8' ]]
printf '%s\n' '{"unicode":"é"}' >"$tmp/canonical-unicode.json"
if canonical_plan_hash "$tmp/canonical-unicode.json" >/dev/null; then
  echo 'canonical receipt hasher unexpectedly accepted non-ASCII JSON' >&2
  exit 1
fi
printf '%s\n' '{"exponent":1e-7}' >"$tmp/canonical-exponent.json"
if canonical_plan_hash "$tmp/canonical-exponent.json" >/dev/null; then
  echo 'canonical receipt hasher unexpectedly accepted exponent-form numbers' >&2
  exit 1
fi
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$kit/02-node" "$kit/../devnet/model-layouts/shared-gpu" "$tmp/bin" "$tmp/operator"
cp "$ROOT/scripts/phase-model-worker-add.sh" "$kit/scripts/"
cp "$ROOT/scripts/lib.sh" "$kit/scripts/"
cp "$ROOT/../devnet/model-layouts/shared-gpu/validate.sh" "$kit/../devnet/model-layouts/shared-gpu/"
cp "$ROOT/../devnet/model-layouts/shared-gpu/render.sh" "$kit/../devnet/model-layouts/shared-gpu/"
cp "$ROOT/02-node/sync-node-config.sh" "$kit/02-node/"

cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
GDC_HOME="${GDC_TEST_OPERATOR:?}"
GDC_DATA_ROOT="$GDC_HOME"
source "${GDC_TEST_REAL_LIB:?}"
ROOT="${GDC_TEST_KIT:?}"
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  GDC_DATA_ROOT="${GDC_TEST_OPERATOR:?}"
  GDC_HOME="${GDC_TEST_OPERATOR:?}"
  GENESIS="$GDC_TEST_OPERATOR/genesis"
  STATE="$GDC_TEST_OPERATOR/state"
}
topology_contains_node() { [[ "$1" == fixture-host ]]; }
SH
cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
command="$*"
printf '%s\n' "$command" >>"$GDC_TEST_SSH_LOG"
fixture_dapi() {
  local scope="$1"
  jq --arg scope "$scope" --arg unassigned "${GDC_TEST_PRIMARY_UNASSIGNED:-false}" \
    --arg missing_epoch_model "${GDC_TEST_NO_PRIMARY_EPOCH_MODEL:-false}" '
    map(select($scope != "primary-only" or .host == "inference")
      | . as $n
      | {node:($n + {inference_segment:"",poc_segment:"",
          hardware:(if $n.host == "inference" then [] else null end),node_num:3,registration_seq:2}),
         state:{request_count:9,lock_count:0,
          epoch_ml_nodes:(if $n.host != "inference" or $unassigned == "true" then {} else {($n.models|keys[0]):{node_id:$n.id}} end),
          epoch_models:(if $n.host == "inference" and $missing_epoch_model != "true" then {($n.models|keys[0]):{}} else {} end),
          preserved_models:{},admin_state:{enabled:true},current_status:"INFERENCE",intended_status:"INFERENCE",
          deployment_update_pending:false,reconcile_info:null,poc_current_status:"IDLE"}})
  ' "$GDC_TEST_POSTED"
}
case "$command" in
  *"sudo bash -s -- 'fixture-net'")
    cat >"$GDC_TEST_REMOTE_ROOT/bootstrap.sh"
    jq --slurpfile config "$GDC_TEST_DEPLOY/node-config.json" '.node_config=$config[0]' "$GDC_TEST_REMOTE_STATE"
    ;;
  *"sudo bash -s -- '/tmp/gdc-model-worker-"*)
    payload="$GDC_TEST_REMOTE_ROOT/apply.sh"
    cat >"$payload"
    read -r -a words <<<"$command"
    stage="$GDC_TEST_REMOTE_ROOT/stage"
    target="$GDC_TEST_REMOTE_ROOT/target"
    sed -e "s|/srv/dai/deploy|$GDC_TEST_DEPLOY|g" "$payload" >"$payload.mapped"
    args=()
    for word in "${words[@]:8}"; do args+=("${word//\'/}"); done
    bash -s -- "$stage" "$target" "${args[@]}" <"$payload.mapped"
    ;;
  *"sudo bash -s -- '/srv/dai/deploy/model-workers/"*" '/tmp/gdc-model-worker-reconcile-"*)
    payload="$GDC_TEST_REMOTE_ROOT/reconcile.sh"
    cat >"$payload"
    [[ "$(<"$payload")" == *'install -m 0600'* && "$(<"$payload")" != *'docker compose'* \
      && "$(<"$payload")" != *'curl '* ]] || exit 98
    [[ -s "$GDC_TEST_REMOTE_ROOT/reconcile-stage/reconciliation.json" \
      && -s "$GDC_TEST_REMOTE_ROOT/reconcile-stage/reconciliation-receipt.json" ]] || exit 99
    [[ ! -e "$GDC_TEST_REMOTE_ROOT/target/receipt.json" ]] || exit 100
    cp "$GDC_TEST_REMOTE_ROOT/reconcile-stage/reconciliation.json" "$GDC_TEST_REMOTE_ROOT/target/reconciliation.json"
    cp "$GDC_TEST_REMOTE_ROOT/reconcile-stage/reconciliation-receipt.json" "$GDC_TEST_REMOTE_ROOT/target/receipt.json"
    ;;
  *"sudo bash -s -- '/srv/dai/deploy/model-workers/"*)
    payload="$GDC_TEST_REMOTE_ROOT/health.sh"
    cat >"$payload"
    [[ "$(<"$payload")" == *'ps -q "$model_service"'* && "$(<"$payload")" == *'ps -q "$router_service"'* \
      && "$(<"$payload")" == *'curl -fsS'* && "$(<"$payload")" == *'/v1/models'* ]] || exit 96
    printf 'HEALTHY\n'
    ;;
  *"install -d -m 0700 '/tmp/gdc-model-worker-reconcile-"*) mkdir -p "$GDC_TEST_REMOTE_ROOT/reconcile-stage" ;;
  *"install -d -m 0700 '/tmp/gdc-model-worker-"*) mkdir -p "$GDC_TEST_REMOTE_ROOT/stage" ;;
  *"rm -rf -- '/tmp/gdc-model-worker-reconcile-"*) rm -rf -- "$GDC_TEST_REMOTE_ROOT/reconcile-stage" ;;
  *"rm -rf -- '/tmp/gdc-model-worker-"*) rm -rf -- "$GDC_TEST_REMOTE_ROOT/stage" ;;
  *"sudo cat '/srv/dai/deploy/model-workers/"*"/receipt.json'"*)
    [[ "$command" == *"sudo cat '/srv/dai/deploy/model-workers/"*"/receipt.json'"* ]]
    receipt="$GDC_TEST_REMOTE_ROOT/target/receipt.json"
    [[ -s "$receipt" ]] || exit 1
    cat "$receipt"
    ;;
  *'uncertain.json'*) cat "$GDC_TEST_REMOTE_ROOT/target/uncertain.json" ;;
  *'reconciliation.json'*) cat "$GDC_TEST_REMOTE_ROOT/target/reconciliation.json" ;;
  *'node-config.before.json'*) cat "$GDC_TEST_REMOTE_ROOT/target/node-config.before.json" ;;
  *'node-config.next.json'*) cat "$GDC_TEST_REMOTE_ROOT/target/node-config.next.json" ;;
  *'secondary-worker.json'*) cat "$GDC_TEST_REMOTE_ROOT/target/secondary-worker.json" ;;
  *'primary-before.json'*) cat "$GDC_TEST_REMOTE_ROOT/target/primary-before.json" ;;
  *'stat -c %i /srv/dai/deploy/model-workers/'*) printf '101\n' ;;
  *'stat -c %i /srv/dai/deploy/node-config.json'*) stat -c '%i' "$GDC_TEST_DEPLOY/node-config.json" ;;
  *'sudo stat -c %i '*) printf '101\n' ;;
  *'sudo jq -er .chain_id /srv/dai/shared/genesis.json'*) jq -er .chain_id "$GDC_TEST_GENESIS" ;;
  *'sudo sha256sum /srv/dai/shared/genesis.json'*) sha256sum "$GDC_TEST_GENESIS" ;;
  *'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status'*) cat "$GDC_TEST_STATUS" ;;
  *'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes'*)
    fixture_dapi all ;;
  *'sudo cat /srv/dai/deploy/node-config.json'*) cat "$GDC_TEST_DEPLOY/node-config.json" ;;
  *) echo "unexpected SSH: $command" >&2; exit 91 ;;
esac
SH
cat >"$tmp/bin/scp" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SCP_LOG"
if [[ "$#" == 4 && "$1" == -q && "${@: -1}" == fixture-host:/tmp/gdc-model-worker-reconcile-* ]]; then
  for source in "${@:2:2}"; do cp "$source" "$GDC_TEST_REMOTE_ROOT/reconcile-stage/"; done
  exit 0
fi
[[ "$#" == 10 && "$1" == -q && "${@: -1}" == fixture-host:/tmp/gdc-model-worker-* ]] || { echo "unexpected scp: $*" >&2; exit 92; }
for source in "${@:2:$#-2}"; do cp "$source" "$GDC_TEST_REMOTE_ROOT/stage/"; done
SH
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_CURL_LOG"
url=''
for argument in "$@"; do
  case "$argument" in
    http://*|https://*) url="$argument"; break ;;
  esac
done
fixture_dapi() {
  local scope="$1"
  jq --arg scope "$scope" --arg unassigned "${GDC_TEST_PRIMARY_UNASSIGNED:-false}" \
    --arg missing_epoch_model "${GDC_TEST_NO_PRIMARY_EPOCH_MODEL:-false}" '
    map(select($scope != "primary-only" or .host == "inference")
      | . as $n
      | {node:($n + {inference_segment:"",poc_segment:"",
          hardware:(if $n.host == "inference" then [] else null end),node_num:3,registration_seq:2}),
         state:{request_count:9,lock_count:0,
          epoch_ml_nodes:(if $n.host != "inference" or $unassigned == "true" then {} else {($n.models|keys[0]):{node_id:$n.id}} end),
          epoch_models:(if $n.host == "inference" and $missing_epoch_model != "true" then {($n.models|keys[0]):{}} else {} end),
          preserved_models:{},admin_state:{enabled:true},current_status:"INFERENCE",intended_status:"INFERENCE",
          deployment_update_pending:false,reconcile_info:null,poc_current_status:"IDLE"}})
  ' "$GDC_TEST_POSTED"
}
case "$url" in
  http://172.30.0.55:8080/health)
    if [[ "${GDC_TEST_ASSIGNMENT_DRIFT_ON_HEALTH:-false}" == true ]]; then touch "$GDC_TEST_REMOTE_ROOT/assignment-drift-fired"; fi
    if [[ "${GDC_TEST_CONFIG_DRIFT_ON_HEALTH:-false}" == true ]]; then
      jq '. + [{id:"concurrent-change",host:"external",metadata:{keep:true}}]' "$GDC_TEST_DEPLOY/node-config.json" >"$GDC_TEST_DEPLOY/node-config.concurrent.tmp"
      cat "$GDC_TEST_DEPLOY/node-config.concurrent.tmp" >"$GDC_TEST_DEPLOY/node-config.json"
      rm -f "$GDC_TEST_DEPLOY/node-config.concurrent.tmp"
    fi
    [[ "${GDC_TEST_FAIL_HEALTH:-false}" != true ]] ;;
  http://172.30.0.55:8080/api/v1/inference/up/status)
    case "${GDC_TEST_MANAGER_MODE:-start}" in
      error-before) printf '{"status":"failed","is_running":false,"error":"fixture startup failure"}\n' ;;
      running-wrong-model) printf '{"status":"running","is_running":true,"error":null}\n' ;;
      *)
        if [[ -s "$GDC_TEST_MANAGER_STATUS" ]]; then
          jq -e '.status == "in_progress"' "$GDC_TEST_MANAGER_STATUS" >/dev/null 2>&1 && {
            cat "$GDC_TEST_MANAGER_STATUS"
            printf '{"status":"running","is_starting":false,"is_running":true,"error":null}\n' >"$GDC_TEST_MANAGER_STATUS"
          } || cat "$GDC_TEST_MANAGER_STATUS"
        else
          printf '{"status":"not_started","is_starting":false,"is_running":false,"error":null}\n'
        fi
        ;;
    esac
    ;;
  http://172.30.0.55:8080/api/v1/inference/up/async)
    [[ " $* " == *' -X POST '* && " $* " == *' --data-binary @- '* ]] || exit 97
    cat >"$GDC_TEST_START_REQUEST"
    printf 'POST\n' >>"$GDC_TEST_START_POSTS"
    [[ "${GDC_TEST_MANAGER_MODE:-start}" != post-fail ]] || exit 23
    printf '{"status":"in_progress","is_starting":true,"is_running":false,"error":null}\n' >"$GDC_TEST_MANAGER_STATUS"
    printf '{"accepted":true}\n'
    ;;
  http://172.30.0.55:5000/v1/models)
    [[ "${GDC_TEST_FAIL_HEALTH:-false}" != true ]] || exit 22
    if [[ "${GDC_TEST_MANAGER_MODE:-start}" == running-wrong-model ]]; then
      printf '{"data":[{"id":"wrong-model"}]}\n'
    else
      printf '{"data":[{"id":"secondary-model"}]}\n'
    fi
    ;;
  http://127.0.0.1:9200/admin/v1/nodes)
    if [[ " $* " == *' -X POST '* ]]; then
      node=''
      args=("$@")
      for ((i=0; i<${#args[@]}; i++)); do [[ "${args[i]}" == --data ]] && node="${args[i+1]}"; done
      [[ -n "$node" ]] || exit 94
      id="$(jq -er .id <<<"$node")"; host="$(jq -er .host <<<"$node")"
      if [[ "${GDC_TEST_FAIL_DAPI:-false}" != true ]]; then
        jq --argjson node "$node" '[.[] | select(.id != $node.id)] + [$node]' "$GDC_TEST_POSTED" >"$GDC_TEST_POSTED.tmp"
        mv "$GDC_TEST_POSTED.tmp" "$GDC_TEST_POSTED"
      else
        printf '{"error":"fixture DAPI POST failure"}\n500\n'
        exit 0
      fi
      printf '{"id":"%s","host":"%s"}\n200\n' "$id" "$host"
    else
      if [[ "${GDC_TEST_DRIFT_AFTER_GET:-false}" == true && ! -e "$GDC_TEST_REMOTE_ROOT/drift-fired" ]] \
        && jq -e 'any(.[]; .id | endswith("--secondary"))' "$GDC_TEST_DEPLOY/node-config.json" >/dev/null; then
        jq '. + [{id:"external-change",host:"outside",metadata:{preserve:true}}]' \
          "$GDC_TEST_DEPLOY/node-config.json" >"$GDC_TEST_DEPLOY/node-config.drift.tmp"
        mv "$GDC_TEST_DEPLOY/node-config.drift.tmp" "$GDC_TEST_DEPLOY/node-config.json"
        touch "$GDC_TEST_REMOTE_ROOT/drift-fired"
      fi
      if [[ "${GDC_TEST_ASSIGNMENT_DRIFT_ON_HEALTH:-false}" == true && -e "$GDC_TEST_REMOTE_ROOT/assignment-drift-fired" ]]; then
        jq 'map(. as $n | {node:($n + {inference_segment:"",poc_segment:"",hardware:[],node_num:3,registration_seq:2}),
          state:{request_count:9,epoch_ml_nodes:(if $n.host == "inference" then {"other-model":{node_id:$n.id}} else {} end)}})' "$GDC_TEST_POSTED"
      elif [[ -s "$GDC_TEST_REMOTE_ROOT/dapi-delay" ]] \
        && jq -e 'any(.[]; .id | endswith("--secondary"))' "$GDC_TEST_POSTED" >/dev/null; then
        delay="$(<"$GDC_TEST_REMOTE_ROOT/dapi-delay")"
        if (( delay > 0 )); then
          printf '%s\n' "$((delay - 1))" >"$GDC_TEST_REMOTE_ROOT/dapi-delay"
          fixture_dapi primary-only
        else
          fixture_dapi all
        fi
      else
        fixture_dapi all
      fi
    fi
    ;;
  *) echo "unexpected curl: $*" >&2; exit 93 ;;
esac
SH
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_DOCKER_LOG"
case "$*" in
  *' config --quiet') ;;
  *' up -d')
    case "${GDC_TEST_SIGNAL_ON_UP:-}" in
      TERM|INT) kill -s "$GDC_TEST_SIGNAL_ON_UP" "$PPID" ;;
    esac
    ;;
  *' ps -q gdc-gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ml') printf 'fixture-secondary-model\n' ;;
  *' ps -q gdc-gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-router') printf 'fixture-router\n' ;;
  *'down --remove-orphans') ;;
  'inspect --format '* ) printf '172.30.0.55\n' ;;
  *) echo "unexpected docker: $*" >&2; exit 95 ;;
esac
SH
chmod 0755 "$tmp/bin/"*

cat >"$tmp/descriptor.json" <<'JSON'
{}
JSON
participant=gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
model_service="gdc-${participant}-ml"
router_service="gdc-${participant}-router"
runtime="qwen3-0.6b:$participant"
mkdir -p "$tmp/operator/genesis" "$tmp/operator/fixture-host/state/joined" \
  "$tmp/operator/fixture-host/state/identities" "$tmp/operator/fixture-host/accounts" \
  "$tmp/operator/state/runtime-identities"
printf '{"chain_id":"fixture-chain"}\n' >"$tmp/operator/genesis/genesis.json"
touch "$tmp/operator/fixture-host/state/joined/fixture-host"
printf '{"node_id":"0123456789abcdef0123456789abcdef01234567"}\n' >"$tmp/operator/fixture-host/state/identities/fixture-host.json"
printf '{"address":"%s"}\n' "$participant" >"$tmp/operator/fixture-host/accounts/fixture-host-cold.json"
runtime_identity_file="$tmp/operator/state/runtime-identities/$(printf '%s' "$runtime" | sha256sum | awk '{print $1}').env"
printf 'node=fixture-host\nparticipant_address=%s\nruntime_id=%s\nrecorded_at=fixture\n' \
  "$participant" "$runtime" >"$runtime_identity_file"

if PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" \
  CHAIN_ID=fixture GDC_NODE_ALIASES=fixture-host bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$tmp/descriptor.json" >"$tmp/out" 2>&1; then
  echo 'invalid descriptor unexpectedly passed validation' >&2
  exit 1
fi
[[ "$(<"$tmp/out")" == *descriptor* || "$(<"$tmp/out")" == *required* ]]

if PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" \
  CHAIN_ID=fixture GDC_NODE_ALIASES=fixture-host bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$tmp/descriptor.json" --unexpected >"$tmp/out" 2>&1; then
  echo 'unsupported installer option unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(<"$tmp/out")" == *Usage:* ]]
[[ ! -e "$tmp/operator/runs" ]]

run_apply() {
  local fail_dapi="$1" output="$2" action="${3:-apply}"
  printf '{"status":"not_started","is_starting":false,"is_running":false,"error":null}\n' >"$tmp/manager-status.json"
  printf '%s\n' "${GDC_TEST_DAPI_DELAY_READS:-0}" >"$tmp/remote/dapi-delay"
  : >"$tmp/start-request.json"
  : >"$tmp/start-posts.log"
  PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" \
    GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" GDC_TEST_SSH_LOG="$tmp/ssh.log" \
    GDC_TEST_SCP_LOG="$tmp/scp.log" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
    GDC_TEST_REMOTE_ROOT="$tmp/remote" GDC_TEST_DEPLOY="$tmp/remote/srv/dai/deploy" \
    GDC_TEST_POSTED="$tmp/posted.json" GDC_TEST_REMOTE_STATE="$tmp/remote-state.json" \
    GDC_TEST_GENESIS="$tmp/remote-genesis.json" GDC_TEST_STATUS="$tmp/status.json" \
    GDC_TEST_MANAGER_STATUS="$tmp/manager-status.json" GDC_TEST_START_REQUEST="$tmp/start-request.json" \
    GDC_TEST_START_POSTS="$tmp/start-posts.log" GDC_TEST_MANAGER_MODE="${GDC_TEST_MANAGER_MODE:-start}" \
    GDC_TEST_SIGNAL_ON_UP="${GDC_TEST_SIGNAL_ON_UP:-}" \
    GDC_TEST_DAPI="$tmp/dapi.json" GDC_TEST_CONFIG="$tmp/config.json" \
    GDC_TEST_FAIL_DAPI="$fail_dapi" CHAIN_ID=fixture-chain GDC_NODE_ALIASES=fixture-host GDC_RUN_ID=fixture-run \
    GDC_TEST_DRIFT_AFTER_GET="${GDC_TEST_DRIFT_AFTER_GET:-false}" \
    GDC_TEST_ASSIGNMENT_DRIFT_ON_HEALTH="${GDC_TEST_ASSIGNMENT_DRIFT_ON_HEALTH:-false}" \
    GDC_TEST_CONFIG_DRIFT_ON_HEALTH="${GDC_TEST_CONFIG_DRIFT_ON_HEALTH:-false}" \
    GDC_TEST_PRIMARY_UNASSIGNED="${GDC_TEST_PRIMARY_UNASSIGNED:-false}" \
    GDC_TEST_NO_PRIMARY_EPOCH_MODEL="${GDC_TEST_NO_PRIMARY_EPOCH_MODEL:-false}" \
    GDC_TEST_DAPI_DELAY_READS="${GDC_TEST_DAPI_DELAY_READS:-0}" \
    bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$tmp/descriptor.json" "--$action" >"$output" 2>&1
}
run_plan_with_state() {
  local state_file="$1" output="$2" descriptor="${3:-$tmp/descriptor.json}"
  PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" \
    GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" GDC_TEST_SSH_LOG="$tmp/ssh.log" \
    GDC_TEST_SCP_LOG="$tmp/scp.log" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
    GDC_TEST_REMOTE_ROOT="$tmp/remote" GDC_TEST_DEPLOY="$tmp/remote/srv/dai/deploy" \
    GDC_TEST_POSTED="$tmp/posted.json" GDC_TEST_REMOTE_STATE="$state_file" \
    GDC_TEST_GENESIS="$tmp/remote-genesis.json" GDC_TEST_STATUS="$tmp/status.json" \
    GDC_TEST_DAPI="$tmp/dapi.json" GDC_TEST_CONFIG="$tmp/config.json" \
    CHAIN_ID=fixture-chain GDC_NODE_ALIASES=fixture-host \
    bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$descriptor" >"$output" 2>&1
}

jq -n --arg participant "$participant" --arg runtime "$runtime" '
  {gpu_device:"0",host_docker_network:"fixture-net",hf_cache_root:"/srv/hf-cache",
   nginx_image:"nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   primary:{model_id:"primary-model",revision:"primary-rev",image:"ml@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
     args:["--revision","primary-rev","--gpu-memory-utilization","0.5"],management_port:8080,inference_port:5000},
   secondary:{model_id:"secondary-model",revision:"secondary-rev",image:"ml@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
     args:["--revision","secondary-rev","--dtype","bfloat16","--served-model-name","secondary-model",
       "--gpu-memory-utilization","0.4","--max-model-len","25000"],management_port:8080,inference_port:5000}}
' >"$tmp/descriptor.json"
jq -n --arg runtime "$runtime" \
  --arg image "ml@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  --arg participant "$participant" '
  {mlnode:{Config:{Image:$image}},api:{Mounts:[{Destination:"/root/node_config.json",Type:"bind",Source:"/srv/dai/deploy/node-config.json"}]},
   primary_models:{data:[{id:"primary-model"}]},
   networks:{"fixture-net":{}},api_networks:{"fixture-net":{}},
   mounts:[{Destination:"/root/.cache",Type:"bind",Source:"/srv/hf-cache"}],devices:[{DeviceIDs:["0"]}],
   network:{Name:"fixture-net",Containers:{one:{Name:"primary",EndpointID:"id",IPv4Address:"172.30.0.2"}}},
   endpoints:[{id:"one",aliases:["primary"]}],
   node_config:[{id:$runtime,host:"inference",models:{"primary-model":{args:["--revision","primary-rev","--gpu-memory-utilization","0.5"]}}},
     {id:"unrelated-record",host:"external",max_concurrent:3,metadata:{keep:true}}]}
' >"$tmp/remote-state.json"
jq -n --arg runtime "$runtime" --arg model "primary-model" '
  [{node:{id:$runtime,host:"inference",models:{($model):{args:["--revision","primary-rev","--gpu-memory-utilization","0.5"]}}}},
   {node:{id:"unrelated-record",host:"external",max_concurrent:3,metadata:{keep:true}}}]
' >"$tmp/dapi.json"
printf '{"result":{"node_info":{"network":"fixture-chain","id":"0123456789abcdef0123456789abcdef01234567"}}}\n' >"$tmp/status.json"
printf '[{"id":"%s","host":"inference","models":{"primary-model":{"args":["--revision","primary-rev","--gpu-memory-utilization","0.5"]}}},{"id":"unrelated-record","host":"external","max_concurrent":3,"metadata":{"keep":true}}]\n' "$runtime" >"$tmp/config.json"
cp "$tmp/operator/genesis/genesis.json" "$tmp/remote-genesis.json"
mkdir -p "$tmp/remote/srv/dai/deploy"
printf '{}\n' >"$tmp/remote/srv/dai/deploy/compose.yaml"
printf '{}\n' >"$tmp/remote/srv/dai/deploy/.env"
cat "$tmp/config.json" >"$tmp/remote/srv/dai/deploy/node-config.json"
mkdir -p "$tmp/remote/srv/dai/deploy/model-workers"
printf '[{"id":"%s","host":"inference","models":{"primary-model":{"args":["--revision","primary-rev","--gpu-memory-utilization","0.5"]}}},{"id":"unrelated-record","host":"external","max_concurrent":3,"metadata":{"keep":true}}]\n' "$runtime" >"$tmp/posted.json"
mkdir -p "$tmp/remote"
: >"$tmp/ssh.log"
if ! PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" \
  GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_SCP_LOG="$tmp/scp.log" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
  GDC_TEST_REMOTE_ROOT="$tmp/remote" GDC_TEST_DEPLOY="$tmp/remote/srv/dai/deploy" GDC_TEST_POSTED="$tmp/posted.json" \
  GDC_TEST_REMOTE_STATE="$tmp/remote-state.json" \
  GDC_TEST_GENESIS="$tmp/remote-genesis.json" GDC_TEST_STATUS="$tmp/status.json" \
  GDC_TEST_DAPI="$tmp/dapi.json" GDC_TEST_CONFIG="$tmp/config.json" \
  CHAIN_ID=fixture-chain GDC_NODE_ALIASES=fixture-host \
  bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$tmp/descriptor.json" >"$tmp/out" 2>&1; then
  cat "$tmp/out" >&2
  exit 1
fi
[[ "$(<"$tmp/out")" == *'READY model-worker plan'* ]]
[[ "$(<"$tmp/ssh.log")" != *'sudo install -d'* ]]
[[ "$(<"$tmp/ssh.log")" != *'up -d'* ]]
[[ ! -e "$tmp/operator/runs" ]]

# A supported runtime replacement changes the ID prefix while retaining the
# same participant lineage. Resolve 4B from the exact primary config and DAPI
# records; the original JOIN identity remains the legacy 0.6B lineage.
replacement_runtime="qwen3-4b:$participant"
cp "$tmp/config.json" "$tmp/config.before-runtime-id.json"
cp "$tmp/posted.json" "$tmp/posted.before-runtime-id.json"
cp "$tmp/remote/srv/dai/deploy/node-config.json" "$tmp/node-config.before-runtime-id.json"
set_replacement_runtime() {
  jq --arg old "$runtime" --arg new "$replacement_runtime" \
    'map(if .id == $old then .id=$new else . end)' "$tmp/config.before-runtime-id.json" >"$tmp/config.json"
  cp "$tmp/config.json" "$tmp/remote/srv/dai/deploy/node-config.json"
  jq --arg old "$runtime" --arg new "$replacement_runtime" \
    'map(if .id == $old then .id=$new else . end)' \
    "$tmp/posted.before-runtime-id.json" >"$tmp/posted.json"
  jq --arg legacy "$runtime" --arg replacement "$replacement_runtime" '
    .model_transitions = [{
      plan:{schema_version:1,kind:"gdc-host-models",host:"fixture-host",
        node_id:$legacy,replace_id:$replacement,
        identity:{container:"fixture-api",chain_id:"fixture-chain",
          config_path:"/srv/dai/deploy/node-config.json",dapi_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        models:{"primary-model":{args:["--revision","primary-rev","--gpu-memory-utilization","0.5"]}},
        before:{id:$legacy,host:"inference",models:{"primary-model":{args:["--revision","primary-rev","--gpu-memory-utilization","0.5"]}}}},
      result:{status:"transitioned",receipt:"",identity:{container:"fixture-api",chain_id:"fixture-chain",
          config_path:"/srv/dai/deploy/node-config.json",dapi_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        retired_worker:$legacy,worker:$replacement,models:["primary-model"],serving_verified:false},
      receipt_dir:""
    }]
  ' "$tmp/remote-state.json" >"$tmp/remote-state.transition.json"
  jq -c '.model_transitions[0].plan' "$tmp/remote-state.transition.json" >"$tmp/model-transition-plan.json"
  plan_key="$(canonical_plan_hash "$tmp/model-transition-plan.json")"
  receipt_dir="/srv/dai/deploy/.gdc-model-updates/$plan_key"
  jq --arg receipt "$receipt_dir" \
    '.model_transitions[0].receipt_dir=$receipt | .model_transitions[0].result.receipt=$receipt' \
    "$tmp/remote-state.transition.json" >"$tmp/remote-state.json"
}
restore_legacy_runtime() {
  cp "$tmp/config.before-runtime-id.json" "$tmp/config.json"
  cp "$tmp/posted.before-runtime-id.json" "$tmp/posted.json"
  cp "$tmp/node-config.before-runtime-id.json" "$tmp/remote/srv/dai/deploy/node-config.json"
}
set_replacement_runtime
awk '/# BEGIN receipt scan test boundary/{inside=1;next} /# END receipt scan test boundary/{inside=0} inside' \
  "$tmp/remote/bootstrap.sh" >"$tmp/receipt-reader.sh"
[[ -s "$tmp/receipt-reader.sh" ]]
sed -i "s|^ledger=/srv/dai/deploy/.gdc-model-updates$|ledger=$tmp/receipt-ledger|" "$tmp/receipt-reader.sh"
jq -c '.model_transitions[0].plan' "$tmp/remote-state.json" >"$tmp/model-transition-plan.json"
plan_key="$(canonical_plan_hash "$tmp/model-transition-plan.json")"
mkdir -p "$tmp/receipt-ledger/$plan_key"
cp "$tmp/model-transition-plan.json" "$tmp/receipt-ledger/$plan_key/plan.json"
receipt_path="$tmp/receipt-ledger/$plan_key"
jq --arg receipt "$receipt_path" \
  '.model_transitions[0].result | .receipt=$receipt' "$tmp/remote-state.json" \
  >"$tmp/receipt-ledger/$plan_key/transition-result.json"
{
  printf '%s\n' 'set -Eeuo pipefail'
  cat "$tmp/receipt-reader.sh"
  printf '%s\n' 'printf "%s\n" "$model_transitions"'
} >"$tmp/run-receipt-reader.sh"
bash "$tmp/run-receipt-reader.sh" >"$tmp/receipt-reader.out"
[[ "$(jq 'length' "$tmp/receipt-reader.out")" == 1 ]]
mkdir -p "$tmp/receipt-ledger/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
cp "$tmp/model-transition-plan.json" "$tmp/receipt-ledger/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/plan.json"
jq --arg receipt "$tmp/receipt-ledger/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
  '.model_transitions[0].result | .receipt=$receipt' "$tmp/remote-state.json" \
  >"$tmp/receipt-ledger/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/transition-result.json"
if bash "$tmp/run-receipt-reader.sh" >"$tmp/receipt-reader-bad-path.out" 2>&1; then
  echo 'transition receipt under a directory with a mismatched plan digest unexpectedly passed' >&2
  exit 1
fi
if ! run_plan_with_state "$tmp/remote-state.json" "$tmp/runtime-replacement.out"; then
  cat "$tmp/runtime-replacement.out" >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-replacement.out")" == *'READY model-worker plan'* ]]

# 4B requires an exact successful replace-id receipt, not merely a familiar
# runtime ID or the legacy JOIN lineage.
cp "$tmp/remote-state.json" "$tmp/remote-state.valid-transition.json"
jq '.model_transitions=[]' "$tmp/remote-state.json" >"$tmp/remote-state.no-transition.json"
if run_plan_with_state "$tmp/remote-state.no-transition.json" "$tmp/runtime-no-transition.out"; then
  echo 'replacement runtime without a recorded replace-id receipt unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-no-transition.out")" == *'no unique matching successful replace-id receipt'* ]]
jq '.model_transitions[0].plan.host="other-host"' "$tmp/remote-state.valid-transition.json" >"$tmp/remote-state.foreign-transition.json"
if run_plan_with_state "$tmp/remote-state.foreign-transition.json" "$tmp/runtime-foreign-transition.out"; then
  echo 'replace-id receipt for another Host unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-foreign-transition.out")" == *'no unique matching successful replace-id receipt'* ]]
jq '.model_transitions[0].result.status="uncertain"' "$tmp/remote-state.valid-transition.json" >"$tmp/remote-state.uncertain-transition.json"
if run_plan_with_state "$tmp/remote-state.uncertain-transition.json" "$tmp/runtime-uncertain-transition.out"; then
  echo 'uncertain replace-id receipt unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-uncertain-transition.out")" == *'no unique matching successful replace-id receipt'* ]]

# Two configured primary entries matching the reviewed model/args are
# ambiguous, even when one has a familiar runtime-ID prefix.
jq --arg legacy "$runtime" '. + [.[0] | .id=$legacy]' \
  "$tmp/config.json" >"$tmp/config.ambiguous.json"
cp "$tmp/config.ambiguous.json" "$tmp/remote/srv/dai/deploy/node-config.json"
if run_plan_with_state "$tmp/remote-state.json" "$tmp/runtime-ambiguous.out"; then
  echo 'ambiguous configured primary runtime IDs unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-ambiguous.out")" == *'do not resolve to exactly one configured runtime identity'* ]]

# A model-matching record under another participant ID is foreign, not a
# candidate primary identity.
foreign_participant=gonka1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq --arg replacement "$replacement_runtime" \
   --arg foreign "qwen3-4b:$foreign_participant" \
  'map(if .id == $replacement then .id=$foreign else . end)' \
  "$tmp/config.json" >"$tmp/config.foreign-runtime.json"
cp "$tmp/config.foreign-runtime.json" "$tmp/remote/srv/dai/deploy/node-config.json"
if run_plan_with_state "$tmp/remote-state.json" "$tmp/runtime-foreign.out"; then
  echo 'foreign participant runtime ID unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-foreign.out")" == *'unsupported or belongs to another participant'* ]]

# A valid current config cannot override stale or unrelated live DAPI data.
cp "$tmp/config.json" "$tmp/remote/srv/dai/deploy/node-config.json"
jq --arg replacement "$replacement_runtime" --arg legacy "$runtime" \
  'map(if .id == $replacement then .id=$legacy else . end)' \
  "$tmp/posted.before-runtime-id.json" >"$tmp/posted.json"
if run_plan_with_state "$tmp/remote-state.json" "$tmp/runtime-dapi-mismatch.out"; then
  echo 'DAPI runtime ID differing from configured primary unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-dapi-mismatch.out")" == *'DAPI does not have the expected primary validator model registered'* ]]

# The account address must still bind to this GDC Host in the recorded local
# lineage; a matching ID suffix alone is not sufficient.
cp "$tmp/remote/srv/dai/deploy/node-config.json" "$tmp/node-config.replacement.json"
cp "$runtime_identity_file" "$tmp/runtime-identity.before-host-mismatch.env"
sed 's/^node=fixture-host$/node=other-host/' "$runtime_identity_file" >"$tmp/runtime-identity.host-mismatch.env"
cp "$tmp/runtime-identity.host-mismatch.env" "$runtime_identity_file"
set_replacement_runtime
if run_plan_with_state "$tmp/remote-state.json" "$tmp/runtime-lineage-host-mismatch.out"; then
  echo 'participant lineage recorded for another GDC Host unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/runtime-lineage-host-mismatch.out")" == *'recorded for another GDC Host'* ]]
cp "$tmp/runtime-identity.before-host-mismatch.env" "$runtime_identity_file"
restore_legacy_runtime

jq '.secondary.args=["--revision","secondary-rev","--gpu-memory-utilization","0.4"]' \
  "$tmp/descriptor.json" >"$tmp/missing-dtype.json"
ssh_before="$(sha256sum "$tmp/ssh.log" | awk '{print $1}')"
if run_plan_with_state "$tmp/remote-state.json" "$tmp/missing-dtype.out" "$tmp/missing-dtype.json"; then
  echo 'secondary descriptor without an explicit dtype unexpectedly passed startup validation' >&2
  exit 1
fi
[[ "$(<"$tmp/missing-dtype.out")" == *'exactly one --dtype'* ]]
[[ "$(sha256sum "$tmp/ssh.log" | awk '{print $1}')" == "$ssh_before" ]]
jq '.secondary.args += ["--dtype","float16"]' "$tmp/descriptor.json" >"$tmp/duplicate-dtype.json"
if run_plan_with_state "$tmp/remote-state.json" "$tmp/duplicate-dtype.out" "$tmp/duplicate-dtype.json"; then
  echo 'secondary descriptor with duplicate dtype unexpectedly passed startup validation' >&2
  exit 1
fi
[[ "$(<"$tmp/duplicate-dtype.out")" == *'exactly one --dtype'* ]]
[[ "$(sha256sum "$tmp/ssh.log" | awk '{print $1}')" == "$ssh_before" ]]

# Retired nested deployment layouts remain a hard refusal.
jq '.api.Mounts[0].Source="/srv/dai/node/node-config.json"' "$tmp/remote-state.json" >"$tmp/remote-state.legacy.json"
: >"$tmp/scp.log"
: >"$tmp/docker.log"
legacy_scp_before="$(sha256sum "$tmp/scp.log" | awk '{print $1}')"
legacy_docker_before="$(sha256sum "$tmp/docker.log" | awk '{print $1}')"
if PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" \
  GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_SCP_LOG="$tmp/scp.log" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
  GDC_TEST_REMOTE_ROOT="$tmp/remote" GDC_TEST_DEPLOY="$tmp/remote/srv/dai/deploy" GDC_TEST_POSTED="$tmp/posted.json" \
  GDC_TEST_REMOTE_STATE="$tmp/remote-state.legacy.json" GDC_TEST_GENESIS="$tmp/remote-genesis.json" GDC_TEST_STATUS="$tmp/status.json" \
  GDC_TEST_DAPI="$tmp/dapi.json" GDC_TEST_CONFIG="$tmp/config.json" CHAIN_ID=fixture-chain GDC_NODE_ALIASES=fixture-host \
  bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$tmp/descriptor.json" >"$tmp/legacy.out" 2>&1; then
  echo 'legacy nested deployment layout unexpectedly passed worker qualification' >&2
  exit 1
fi
[[ "$(<"$tmp/legacy.out")" == *'not the expected joined validator/runtime'* ]]
[[ "$(sha256sum "$tmp/scp.log" | awk '{print $1}')" == "$legacy_scp_before" ]]
[[ "$(sha256sum "$tmp/docker.log" | awk '{print $1}')" == "$legacy_docker_before" ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" && ! -e "$tmp/remote/target/receipt.json" ]]

# Participant-specific implicit Compose aliases must not already exist on
# the primary network; otherwise Docker DNS could route the renderer's
# unique service names to an unrelated container.
cp "$tmp/remote-state.json" "$tmp/remote-state.before-collision.json"
: >"$tmp/scp.log"
: >"$tmp/docker.log"
for occupied_alias in "$model_service" "$router_service" "gdc-shared-${participant}-ml" "gdc-shared-${participant}-router"; do
  jq --arg alias "$occupied_alias" '.endpoints[0].aliases += [$alias]' \
    "$tmp/remote-state.before-collision.json" >"$tmp/remote-state.collision.json"
  if run_plan_with_state "$tmp/remote-state.collision.json" "$tmp/collision.out"; then
    echo "occupied secondary Docker alias unexpectedly passed preflight: $occupied_alias" >&2
    exit 1
  fi
  [[ "$(<"$tmp/collision.out")" == *'not the expected joined validator/runtime'* ]]
done
[[ ! -s "$tmp/scp.log" && ! -s "$tmp/docker.log" ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" && ! -e "$tmp/remote/target/receipt.json" ]]

# The canonical local ML compose requests all visible NVIDIA devices. Accept
# that only when the host proves the descriptor's selected index is its sole
# physical GPU; an all-device request on a multi-GPU host is ambiguous.
jq '.devices=[{Driver:"nvidia",Count:-1,DeviceIDs:null,Capabilities:[["gpu"]]}]
  | .mlnode.Config.Env=["NVIDIA_VISIBLE_DEVICES=all"] | .gpu_indices=["0"]' \
  "$tmp/remote-state.json" >"$tmp/remote-state.all-gpu.json"
cp "$tmp/remote-state.json" "$tmp/remote-state.explicit.json"
cp "$tmp/remote-state.all-gpu.json" "$tmp/remote-state.json"
if ! PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" \
  GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_SCP_LOG="$tmp/scp.log" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
  GDC_TEST_REMOTE_ROOT="$tmp/remote" GDC_TEST_DEPLOY="$tmp/remote/srv/dai/deploy" GDC_TEST_POSTED="$tmp/posted.json" \
  GDC_TEST_REMOTE_STATE="$tmp/remote-state.json" GDC_TEST_GENESIS="$tmp/remote-genesis.json" GDC_TEST_STATUS="$tmp/status.json" \
  GDC_TEST_DAPI="$tmp/dapi.json" GDC_TEST_CONFIG="$tmp/config.json" CHAIN_ID=fixture-chain GDC_NODE_ALIASES=fixture-host \
  bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$tmp/descriptor.json" >"$tmp/all-gpu.out" 2>&1; then
  cat "$tmp/all-gpu.out" >&2
  exit 1
fi
[[ "$(<"$tmp/all-gpu.out")" == *'READY model-worker plan'* ]]
jq '.gpu_indices=["0","1"]' "$tmp/remote-state.json" >"$tmp/remote-state.multi-gpu.json"
cp "$tmp/remote-state.multi-gpu.json" "$tmp/remote-state.json"
if PATH="$tmp/bin:/usr/bin:/bin" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" GDC_TEST_REAL_LIB="$ROOT/scripts/lib.sh" \
  GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_SCP_LOG="$tmp/scp.log" GDC_TEST_CURL_LOG="$tmp/curl.log" GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
  GDC_TEST_REMOTE_ROOT="$tmp/remote" GDC_TEST_DEPLOY="$tmp/remote/srv/dai/deploy" GDC_TEST_POSTED="$tmp/posted.json" \
  GDC_TEST_REMOTE_STATE="$tmp/remote-state.json" GDC_TEST_GENESIS="$tmp/remote-genesis.json" GDC_TEST_STATUS="$tmp/status.json" \
  GDC_TEST_DAPI="$tmp/dapi.json" GDC_TEST_CONFIG="$tmp/config.json" CHAIN_ID=fixture-chain GDC_NODE_ALIASES=fixture-host \
  bash "$kit/scripts/phase-model-worker-add.sh" fixture-host "$tmp/descriptor.json" >"$tmp/multi-gpu.out" 2>&1; then
  echo 'all-device GPU request on a multi-GPU host unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/multi-gpu.out")" == *'descriptor does not match its primary model, image, cache, GPU and Docker network'* ]]
cp "$tmp/remote-state.explicit.json" "$tmp/remote-state.json"
original_config_sha="$(sha256sum "$tmp/config.json" | awk '{print $1}')"
original_config_inode="$(stat -c %i "$tmp/remote/srv/dai/deploy/node-config.json")"
runtime_identity_sha="$(sha256sum "$runtime_identity_file" | awk '{print $1}')"
if run_apply true "$tmp/rollback.out"; then
  echo 'DAPI registration mismatch unexpectedly passed the apply phase' >&2
  exit 1
fi
[[ "$(<"$tmp/rollback.out")" == *'model-worker apply is UNCERTAIN'* ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" != "$original_config_sha" ]]
[[ "$(sha256sum "$runtime_identity_file" | awk '{print $1}')" == "$runtime_identity_sha" ]]
[[ "$(stat -c %i "$tmp/remote/srv/dai/deploy/node-config.json")" == "$original_config_inode" ]]
[[ "$(jq 'length' "$tmp/posted.json")" == 2 && "$(jq -r '.[0].id' "$tmp/posted.json")" == "$runtime" ]]
[[ -s "$tmp/remote/target/secondary-compose.json" && -s "$tmp/remote/target/uncertain.json" ]]
[[ "$(<"$tmp/docker.log")" != *'down --remove-orphans'* ]]
# A failed DAPI sync can be partial; remove only this isolated fixture state
# before later independent cases.
rm -rf "$tmp/remote/target"
cat "$tmp/config.json" >"$tmp/remote/srv/dai/deploy/node-config.json"
cp "$tmp/config.json" "$tmp/posted.json"

# The same deployment lock serializes this writer with primary model retunes.
: >"$tmp/docker.log"
: >"$tmp/ssh.log"
exec 8>"$tmp/remote/srv/dai/deploy/.gdc-models.lock"
flock -n 8
if run_apply false "$tmp/locked.out"; then
  echo 'model-worker apply ignored the shared model-operation lock' >&2
  exit 1
fi
[[ "$(<"$tmp/locked.out")" == *'model-worker apply failed'* ]]
[[ ! -s "$tmp/docker.log" ]]
flock -u 8
exec 8>&-

# Startup can take minutes, so a config update during worker health checks
# must be preserved rather than overwritten at the delayed write boundary.
: >"$tmp/docker.log"
: >"$tmp/ssh.log"
if GDC_TEST_CONFIG_DRIFT_ON_HEALTH=true run_apply false "$tmp/config-drift.out"; then
  echo 'worker apply overwrote a node-config update made during startup' >&2
  exit 1
fi
[[ "$(<"$tmp/config-drift.out")" == *'apply failed'* ]]
jq -e 'any(.[]; .id == "concurrent-change" and .metadata.keep == true)' "$tmp/remote/srv/dai/deploy/node-config.json" >/dev/null
[[ "$(jq 'length' "$tmp/posted.json")" == 2 ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" ]]
[[ "$(<"$tmp/docker.log")" == *'down --remove-orphans'* ]]
cat "$tmp/config.json" >"$tmp/remote/srv/dai/deploy/node-config.json"
: >"$tmp/docker.log"
: >"$tmp/ssh.log"
rm -f "$tmp/remote/assignment-drift-fired"
if GDC_TEST_ASSIGNMENT_DRIFT_ON_HEALTH=true run_apply false "$tmp/assignment-drift.out"; then
  echo 'worker apply accepted a primary DAPI assignment change during startup' >&2
  exit 1
fi
[[ "$(<"$tmp/assignment-drift.out")" == *'primary DAPI registration or assignment changed during worker startup'* ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" == "$original_config_sha" ]]
[[ "$(jq 'length' "$tmp/posted.json")" == 2 ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" ]]
[[ "$(<"$tmp/docker.log")" == *'down --remove-orphans'* ]]
rm -f "$tmp/remote/assignment-drift-fired"

# A healthy API manager with no inference engine is not model readiness. The
# helper must request the reviewed model exactly once before any DAPI handoff.
: >"$tmp/docker.log"
: >"$tmp/ssh.log"
cat "$tmp/config.json" >"$tmp/remote/srv/dai/deploy/node-config.json"
cp "$tmp/config.json" "$tmp/posted.json"
if GDC_TEST_MANAGER_MODE=error-before run_apply false "$tmp/manager-error.out"; then
  echo 'secondary manager startup error unexpectedly passed the model-worker lifecycle' >&2
  exit 1
fi
[[ "$(<"$tmp/manager-error.out")" == *'secondary ML manager reported an inference startup error'* ]]
[[ ! -s "$tmp/start-posts.log" ]]
[[ "$(jq 'length' "$tmp/posted.json")" == 2 ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" == "$original_config_sha" ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" ]]
[[ "$(<"$tmp/docker.log")" == *'down --remove-orphans'* ]]

: >"$tmp/docker.log"
: >"$tmp/ssh.log"
if GDC_TEST_MANAGER_MODE=post-fail run_apply false "$tmp/manager-post-fail.out"; then
  echo 'rejected secondary manager startup request unexpectedly passed' >&2
  exit 1
fi
[[ "$(<"$tmp/manager-post-fail.out")" == *'secondary ML manager rejected the reviewed inference startup request'* ]]
[[ "$(wc -l <"$tmp/start-posts.log" | tr -d ' ')" == 1 ]]
[[ "$(jq 'length' "$tmp/posted.json")" == 2 ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" == "$original_config_sha" ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" ]]
[[ "$(<"$tmp/docker.log")" == *'down --remove-orphans'* ]]

: >"$tmp/docker.log"
: >"$tmp/ssh.log"
if GDC_TEST_MANAGER_MODE=running-wrong-model run_apply false "$tmp/wrong-model.out"; then
  echo 'secondary manager serving the wrong model unexpectedly passed readiness' >&2
  exit 1
fi
[[ "$(<"$tmp/wrong-model.out")" == *'secondary ML manager is running a different model'* ]]
[[ ! -s "$tmp/start-posts.log" ]]
[[ "$(jq 'length' "$tmp/posted.json")" == 2 ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" ]]
[[ "$(<"$tmp/docker.log")" == *'down --remove-orphans'* ]]

# A TERM during compose startup must enter the same scoped rollback as an
# ordinary command failure instead of leaving containers behind.
: >"$tmp/docker.log"
: >"$tmp/ssh.log"
if GDC_TEST_SIGNAL_ON_UP=TERM run_apply false "$tmp/term-cleanup.out"; then
  echo 'terminated model-worker apply unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(<"$tmp/term-cleanup.out")" == *'model-worker apply failed'* ]]
[[ "$(<"$tmp/docker.log")" == *'down --remove-orphans'* ]]
[[ "$(jq 'length' "$tmp/posted.json")" == 2 ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" == "$original_config_sha" ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" ]]

: >"$tmp/docker.log"
: >"$tmp/ssh.log"
if GDC_TEST_SIGNAL_ON_UP=INT run_apply false "$tmp/int-cleanup.out"; then
  echo 'interrupted model-worker apply unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(<"$tmp/int-cleanup.out")" == *'model-worker apply failed'* ]]
[[ "$(<"$tmp/docker.log")" == *'down --remove-orphans'* ]]
[[ "$(jq 'length' "$tmp/posted.json")" == 2 ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" == "$original_config_sha" ]]
[[ ! -e "$tmp/remote/target/secondary-compose.json" ]]

: >"$tmp/docker.log"
: >"$tmp/ssh.log"
cat "$tmp/config.json" >"$tmp/remote/srv/dai/deploy/node-config.json"
cp "$tmp/config.json" "$tmp/posted.json"
original_config_inode="$(stat -c %i "$tmp/remote/srv/dai/deploy/node-config.json")"
if ! GDC_TEST_DAPI_DELAY_READS=2 run_apply false "$tmp/apply.out"; then
  cat "$tmp/apply.out" >&2
  exit 1
fi
[[ "$(<"$tmp/apply.out")" == *'PASS model-worker host=fixture-host'* ]]
[[ "$(wc -l <"$tmp/remote/dapi-delay" | tr -d ' ')" == 1 ]]
[[ "$(<"$tmp/remote/dapi-delay")" == 0 ]]
[[ -s "$tmp/remote/target/receipt.json" ]]
[[ "$(wc -l <"$tmp/start-posts.log" | tr -d ' ')" == 1 ]]
jq -e --arg model secondary-model --arg dtype bfloat16 --argjson args \
  '["--revision","secondary-rev","--served-model-name","secondary-model","--gpu-memory-utilization","0.4","--max-model-len","25000"]' \
  '.model==$model and .dtype==$dtype and .additional_args==$args' "$tmp/start-request.json" >/dev/null
startup_post_line="$(awk '/\/api\/v1\/inference\/up\/async/ {print NR; exit}' "$tmp/curl.log")"
models_line="$(awk '/:5000\/v1\/models/ {print NR; exit}' "$tmp/curl.log")"
dapi_post_line="$(awk '/-X POST/ && /9200\/admin\/v1\/nodes/ {print NR; exit}' "$tmp/curl.log")"
[[ "$startup_post_line" =~ ^[0-9]+$ && "$models_line" =~ ^[0-9]+$ && "$dapi_post_line" =~ ^[0-9]+$ \
  && "$startup_post_line" -lt "$models_line" && "$models_line" -lt "$dapi_post_line" ]]
jq -e --arg before "$original_config_sha" '.outcome == "PASS" and .node_config_before_sha256 == $before and .node_config_after_sha256 != $before' "$tmp/remote/target/receipt.json" >/dev/null
jq -e --arg runtime "$runtime" --arg worker "secondary-model:$participant--secondary" '
  length == 3 and any(.[]; .id == $runtime) and any(.[]; .id == $worker)
  and any(.[]; .id == "unrelated-record" and .metadata.keep == true and .max_concurrent == 3)
' "$tmp/remote/srv/dai/deploy/node-config.json" >/dev/null
jq -e --arg runtime "$runtime" --arg worker "secondary-model:$participant--secondary" \
  'length == 3 and any(.[]; .id == $runtime) and any(.[]; .id == $worker)
   and any(.[]; .id == "unrelated-record" and .metadata.keep == true and .max_concurrent == 3)' "$tmp/posted.json" >/dev/null
primary_expected="$(jq -c '.[0]' "$tmp/config.json")"
primary_after="$(jq -c --arg runtime "$runtime" '.[] | select(.id == $runtime)' "$tmp/remote/srv/dai/deploy/node-config.json")"
[[ "$primary_after" == "$primary_expected" ]]
unrelated_before="$(jq -c '.[1]' "$tmp/config.json")"
unrelated_after="$(jq -c '.[] | select(.id == "unrelated-record")' "$tmp/remote/srv/dai/deploy/node-config.json")"
[[ "$unrelated_after" == "$unrelated_before" ]]
applied_config_inode="$(stat -c %i "$tmp/remote/srv/dai/deploy/node-config.json")"
[[ "$applied_config_inode" == "$original_config_inode" ]]

: >"$tmp/ssh.log"
scp_before="$(sha256sum "$tmp/scp.log" | awk '{print $1}')"
docker_before="$(sha256sum "$tmp/docker.log" | awk '{print $1}')"
if ! run_apply false "$tmp/idempotent.out"; then
  cat "$tmp/idempotent.out" >&2
  exit 1
fi
[[ "$(<"$tmp/idempotent.out")" == *'NO_CHANGE model-worker already applied'* ]]
[[ "$(sha256sum "$tmp/scp.log" | awk '{print $1}')" == "$scp_before" ]]
[[ "$(sha256sum "$tmp/docker.log" | awk '{print $1}')" == "$docker_before" ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" == "$(jq -r .node_config_after_sha256 "$tmp/remote/target/receipt.json")" ]]
[[ "$(stat -c %i "$tmp/remote/srv/dai/deploy/node-config.json")" == "$applied_config_inode" ]]

# DAPI may enrich registered records, but explicit candidate fields remain
# exact: a changed max_concurrent is not an idempotent match.
jq 'map(if .id == "secondary-model:'"$participant"'--secondary" then .max_concurrent=2 else . end)' \
  "$tmp/posted.json" >"$tmp/posted.drift.json"
cp "$tmp/posted.drift.json" "$tmp/posted.json"
if run_apply false "$tmp/drift.out"; then
  echo 'managed worker with runtime max_concurrent drift was accepted as idempotent' >&2
  exit 1
fi
[[ "$(<"$tmp/drift.out")" == *'managed worker DAPI registration differs from the reviewed candidate'* ]]
jq 'map(if .id == "secondary-model:'"$participant"'--secondary" then .max_concurrent=1 else . end)' \
  "$tmp/posted.json" >"$tmp/posted.restore.json"
cp "$tmp/posted.restore.json" "$tmp/posted.json"

# If another writer replaces the bind file after DAPI registers the worker,
# retain the worker and durable reconciliation evidence rather than rolling
# back through unknown state.
rm -rf "$tmp/remote/target"
cat "$tmp/config.json" >"$tmp/remote/srv/dai/deploy/node-config.json"
cp "$tmp/config.json" "$tmp/posted.json"
: >"$tmp/docker.log"
rm -f "$tmp/remote/drift-fired"
if GDC_TEST_DRIFT_AFTER_GET=true run_apply false "$tmp/uncertain.out"; then
  echo 'concurrent node-config drift unexpectedly produced a PASS receipt' >&2
  exit 1
fi
[[ "$(<"$tmp/uncertain.out")" == *'apply is UNCERTAIN'* ]]
jq -e '.outcome == "UNCERTAIN" and .phase == "config-drift"' "$tmp/remote/target/uncertain.json" >/dev/null
[[ -s "$tmp/remote/target/secondary-compose.json" && -s "$tmp/remote/target/secondary-worker.json" ]]
[[ "$(<"$tmp/docker.log")" != *'down --remove-orphans'* ]]

# A delayed DAPI readback is retained as uncertainty, then reconciled without
# Compose lifecycle or DAPI/config writes once the registration is visible.
rm -rf "$tmp/remote/target"
cat "$tmp/config.json" >"$tmp/remote/srv/dai/deploy/node-config.json"
cp "$tmp/config.json" "$tmp/posted.json"
: >"$tmp/docker.log"
: >"$tmp/ssh.log"
if GDC_TEST_PRIMARY_UNASSIGNED=true GDC_TEST_DAPI_DELAY_READS=100 run_apply false "$tmp/readback-timeout.out"; then
  echo 'permanently delayed DAPI readback unexpectedly produced a PASS receipt' >&2
  exit 1
fi
[[ "$(<"$tmp/readback-timeout.out")" == *'apply is UNCERTAIN'* ]]
jq -e '.outcome == "UNCERTAIN" and .phase == "dapi-readback" and .dapi_readback_attempts > 1 and .descriptor_sha256 != null' \
  "$tmp/remote/target/uncertain.json" >/dev/null
jq -e --arg worker "secondary-model:$participant--secondary" \
  'type == "array" and any(.[]; .node.host == "inference")
   and all(.[]; .node.id != $worker)' "$tmp/remote/target/dapi-readback.last.json" >/dev/null
[[ -s "$tmp/remote/target/primary-before.json" ]]
uncertain_sha="$(sha256sum "$tmp/remote/target/uncertain.json" | awk '{print $1}')"
config_sha_before_reconcile="$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')"
config_inode_before_reconcile="$(stat -c %i "$tmp/remote/srv/dai/deploy/node-config.json")"
: >"$tmp/docker.log"
: >"$tmp/curl.log"
cp "$tmp/remote-state.json" "$tmp/remote-state.before-reconcile.json"
jq '.primary_models.data[0].id="wrong-primary-model"' "$tmp/remote-state.before-reconcile.json" \
  >"$tmp/remote-state.wrong-engine.json"
cp "$tmp/remote-state.wrong-engine.json" "$tmp/remote-state.json"
if GDC_TEST_PRIMARY_UNASSIGNED=true run_apply false "$tmp/reconcile-wrong-engine.out" reconcile-uncertain; then
  echo 'uncertain reconciliation accepted a different loaded primary engine model' >&2
  exit 1
fi
[[ "$(<"$tmp/reconcile-wrong-engine.out")" == *'primary ML engine is not serving exactly the reviewed model'* ]]
cp "$tmp/remote-state.before-reconcile.json" "$tmp/remote-state.json"
if GDC_TEST_PRIMARY_UNASSIGNED=true GDC_TEST_NO_PRIMARY_EPOCH_MODEL=true \
  run_apply false "$tmp/reconcile-missing-epoch-model.out" reconcile-uncertain; then
  echo 'uncertain reconciliation accepted an unassigned primary absent from epoch_models' >&2
  exit 1
fi
[[ "$(<"$tmp/reconcile-missing-epoch-model.out")" == *'neither the exact assignment nor ready-unassigned'* ]]
if ! GDC_TEST_PRIMARY_UNASSIGNED=true run_apply false "$tmp/reconcile.out" reconcile-uncertain; then
  cat "$tmp/reconcile.out" >&2
  exit 1
fi
[[ "$(<"$tmp/reconcile.out")" == *'PASS model-worker current-state reconciliation'* ]]
jq -e '.outcome == "PASS" and .scope == "current-state-only" and .primary_preapply_snapshot_compared == true' \
  "$tmp/remote/target/reconciliation.json" >/dev/null
[[ "$(sha256sum "$tmp/remote/target/uncertain.json" | awk '{print $1}')" == "$uncertain_sha" ]]
[[ "$(sha256sum "$tmp/remote/srv/dai/deploy/node-config.json" | awk '{print $1}')" == "$config_sha_before_reconcile" ]]
[[ "$(stat -c %i "$tmp/remote/srv/dai/deploy/node-config.json")" == "$config_inode_before_reconcile" ]]
[[ "$(<"$tmp/curl.log")" != *'-X POST'* ]]
[[ "$(<"$tmp/docker.log")" != *'up -d'* && "$(<"$tmp/docker.log")" != *'down --remove-orphans'* ]]

command -v docker >/dev/null || { echo 'Docker is required for the isolated model-worker lifecycle fixture' >&2; exit 1; }
docker info >/dev/null || { echo 'local Docker daemon is unavailable for the model-worker lifecycle fixture' >&2; exit 1; }
fixture_network="gdc-model-worker-fixture-$(printf '%s' "$tmp" | sha256sum | cut -c1-10)"
fixture_image='alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40'
base_project="$fixture_network-base"
worker_project="$fixture_network-worker"
base_compose="$tmp/base-compose.yaml"
worker_compose="$tmp/worker-compose.yaml"
fixture_config="$tmp/node-config.json"
printf '[{"id":"primary:fixture","host":"inference"}]\n' >"$fixture_config"
config_before="$(sha256sum "$fixture_config" | awk '{print $1}')"
cleanup_docker() {
  docker compose --project-name "$worker_project" -f "$worker_compose" down --remove-orphans >/dev/null 2>&1 || true
  docker compose --project-name "$base_project" -f "$base_compose" down --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$fixture_network" >/dev/null 2>&1 || true
}
trap 'cleanup_docker; cleanup' EXIT
docker network create "$fixture_network" >/dev/null
docker pull "$fixture_image" >/dev/null
cat >"$base_compose" <<YAML
services:
  validator:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    networks: [fixture]
  mlnode:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    networks: [fixture]
  router:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    networks: [fixture]
  api:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    networks: [fixture]
networks:
  fixture:
    external: true
    name: $fixture_network
YAML
cat >"$worker_compose" <<YAML
services:
  $model_service:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    networks:
      fixture:
        aliases: [fixture-secondary-model]
  $router_service:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    healthcheck:
      test: ["CMD", "sh", "-c", "kill -0 1"]
      interval: 1s
      timeout: 2s
      retries: 15
    networks:
      fixture:
        aliases: [fixture-secondary-router]
networks:
  fixture:
    external: true
    name: $fixture_network
YAML
docker compose --project-name "$base_project" -f "$base_compose" up -d --pull never --wait >/dev/null
docker compose --project-name "$worker_project" -f "$worker_compose" up -d --pull never --wait >/dev/null
router_id="$(docker compose --project-name "$worker_project" -f "$worker_compose" ps -q "$router_service")"
model_id="$(docker compose --project-name "$worker_project" -f "$worker_compose" ps -q "$model_service")"
[[ -n "$router_id" ]]
[[ -n "$model_id" ]]
docker exec "$router_id" sh -c 'kill -0 1'
primary_model_id="$(docker compose --project-name "$base_project" -f "$base_compose" ps -q mlnode)"
primary_router_id="$(docker compose --project-name "$base_project" -f "$base_compose" ps -q router)"
primary_model_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$primary_model_id")"
primary_router_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$primary_router_id")"
secondary_model_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$model_id")"
secondary_router_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$router_id")"
assert_dns_only() {
  local hostname=$1 expected=$2 forbidden=$3 result
  # Query the Docker alias as absolute; CI hosts may supply a DNS search suffix.
  result="$(docker exec "$router_id" nslookup "$hostname." 2>&1)" || {
    printf 'DNS lookup failed for %s: %s\n' "$hostname" "$result" >&2
    return 1
  }
  grep -Fq "$expected" <<<"$result" && ! grep -Fq "$forbidden" <<<"$result" || {
    printf 'DNS name %s did not resolve exclusively to %s (excluded %s):\n%s\n' \
      "$hostname" "$expected" "$forbidden" "$result" >&2
    return 1
  }
}
assert_dns_only mlnode "$primary_model_ip" "$secondary_model_ip"
assert_dns_only router "$primary_router_ip" "$secondary_router_ip"
assert_dns_only "$model_service" "$secondary_model_ip" "$primary_model_ip"
assert_dns_only fixture-secondary-model "$secondary_model_ip" "$primary_model_ip"
assert_dns_only "$router_service" "$secondary_router_ip" "$primary_router_ip"
assert_dns_only fixture-secondary-router "$secondary_router_ip" "$primary_router_ip"
docker compose --project-name "$worker_project" -f "$worker_compose" down --remove-orphans >/dev/null
for service in validator api mlnode router; do
  container_id="$(docker compose --project-name "$base_project" -f "$base_compose" ps -q "$service")"
  [[ -n "$container_id" && "$(docker inspect -f '{{.State.Running}}' "$container_id")" == true ]]
done
[[ "$(sha256sum "$fixture_config" | awk '{print $1}')" == "$config_before" ]]
printf 'PASS invalid-input, mocked plan/apply, DAPI rollback, repeat-apply idempotency, byte-preserved primary config, canonical GDC lineage, and isolated Docker worker teardown\n'
