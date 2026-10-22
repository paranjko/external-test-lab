#!/usr/bin/env bash
# Execute the helper's real remote Bash payload through a strict mocked SSH,
# Docker, DAPI, and ML API boundary for canonical and legacy layouts.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; project=""
cleanup() {
  if [[ -n "$project" ]] && command -v docker >/dev/null 2>&1; then
    for layout in canonical legacy; do
      deploy="$tmp/docker-$layout/deploy"; [[ "$layout" == legacy ]] && deploy="$deploy/fixture-host"
      [[ -f "$deploy/compose.yaml" ]] && docker compose --project-name "$project-$layout" -f "$deploy/compose.yaml" down --timeout 1 --remove-orphans >/dev/null 2>&1 || true
    done
  fi
  [[ "${GDC_TEST_KEEP_TMP:-false}" == true ]] && printf 'KEEP_TEST_TMP=%s\n' "$tmp" >&2 || rm -rf -- "$tmp"
}
trap cleanup EXIT
kit="$tmp/kit/net-deployment-runbook"; mockbin="$tmp/bin"; operator="$tmp/operator"; remote_root="$tmp/srv/dai"
mkdir -p "$kit/scripts" "$kit/../devnet/model-layouts/shared-gpu" "$kit/../model" "$mockbin" "$operator/genesis" "$operator/fixture-host/state/joined" "$operator/fixture-host/state/identities" "$operator/accounts"
cp "$ROOT/scripts/phase-model-primary-reconfigure.sh" "$kit/scripts/"
cp "$ROOT/../devnet/model-layouts/shared-gpu/validate.sh" "$kit/../devnet/model-layouts/shared-gpu/"
cp "$ROOT/../model/qwen2.5-7b-instruct-devnet.lock" "$kit/../model/"
cp "$ROOT/../model/qwen2.5-7b-instruct.lock" "$kit/../model/"
cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$GDC_TEST_KIT"
load_project() { GDC_HOME="$GDC_TEST_OPERATOR"; GDC_DATA_ROOT="$GDC_HOME"; GENESIS="$GDC_HOME/genesis"; }
die() { echo "$*" >&2; exit 1; }
topology_contains_node() { [[ "$1" == fixture-host ]]; }
node_identity_file() { printf '%s/fixture-host/state/identities/fixture-host.json\n' "$GDC_HOME"; }
node_account_file() { printf '%s/accounts/fixture-host-cold.json\n' "$GDC_HOME"; }
node_joined_marker() { printf '%s/fixture-host/state/joined/fixture-host\n' "$GDC_HOME"; }
runtime_id_for_participant() { printf 'runtime:%s\n' "$1"; }
genesis_sha256() {
  jq -eS 'del(.app_name,.app_version)|if has("app_hash") then .app_hash=(.app_hash//"") else . end|if has("initial_height") then .initial_height=(.initial_height|tostring) else . end|if .consensus.params? then .consensus_params=.consensus.params|del(.consensus) else . end' "$1" | sha256sum | awk '{print $1}'
}
SH
cat >"$kit/../devnet/model-layouts/shared-gpu/descriptor.schema.json" <<'JSON'
{}
JSON
cat >"$mockbin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -T && "$2" == -o && "$3" == BatchMode=yes && "$4" == -o && "$5" == ConnectTimeout=10 && "$6" == fixture-host ]] || { echo 'unexpected SSH target/options' >&2; exit 90; }
[[ "$7" == *'sudo bash -s --'* ]] || { echo 'unexpected SSH operation' >&2; exit 91; }
payload="$GDC_TEST_TMP/remote.sh"; cat >"$payload"
sed "s#/srv/dai#$GDC_TEST_REMOTE_ROOT#g" "$payload" >"$payload.mapped"
read -r -a words <<<"$7"; args=(); for word in "${words[@]:4}"; do args+=("${word//\'/}"); done
bash "$payload.mapped" "${args[@]}"
SH
cat >"$mockbin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
args=("$@"); url=''; data=''
for ((i=0;i<${#args[@]};i++)); do
  [[ "${args[i]}" == http://* ]] && url="${args[i]}"
  [[ "${args[i]}" == --data-binary ]] && data="${args[i+1]}"
done
case "$*" in
  'ps -q --filter label=com.docker.compose.service=node') printf 'node-container\n' ;;
  'ps -q --filter label=com.docker.compose.service=api') printf 'api-container\n' ;;
  'inspect --format '*working_dir*) printf '%s\n' "$GDC_TEST_DEPLOY" ;;
  'inspect --format '*compose.project*) printf 'fixture-project\n' ;;
  'inspect --format {{.Config.Image}} mlnode-container') printf '%s\n' "$GDC_TEST_IMAGE" ;;
  'inspect --format {{json .Mounts}} api-container') printf '[{"Type":"bind","Source":"%s/node-config.json","Destination":"/root/node_config.json"}]\n' "$GDC_TEST_DEPLOY" ;;
  'inspect --format {{json .HostConfig.DeviceRequests}} mlnode-container') printf '[{"Driver":"nvidia","Count":-1,"DeviceIDs":null,"Capabilities":[["gpu"]]}]\n' ;;
  'inspect --format {{json .Config.Env}} mlnode-container') printf '["NVIDIA_VISIBLE_DEVICES=all"]\n' ;;
  'compose --project-name '*ps\ -q\ mlnode*) printf 'mlnode-container\n' ;;
  'top mlnode-container -eo pid') printf 'PID\n%s\n' "$(<"$GDC_TEST_ENGINE_PID")" ;;
  'exec api-container sha256sum /root/.dapi/cosmovisor/current/bin/decentralized-api') printf '%s  decentralized-api\n' 1111111111111111111111111111111111111111111111111111111111111111 ;;
  'exec api-container curl '*http://node:26657/status) printf '{"result":{"node_info":{"network":"fixture-chain","id":"0123456789abcdef0123456789abcdef01234567"}}}\n' ;;
  'exec api-container curl '*http://127.0.0.1:9000/v1/epochs/latest)
    next=2800; [[ "${GDC_TEST_EPOCH_NEAR:-false}" == true ]] && next=2659
    printf '{"phase":"Inference","is_confirmation_poc_active":false,"block_height":2300,"epoch_stages":{"next_poc_start":%s}}\n' "$next" ;;
  'exec api-container curl '*http://127.0.0.1:9200/admin/v1/nodes*)
    if [[ "${args[*]}" == *'--data-binary'* ]]; then
      [[ "${GDC_TEST_FAIL_POST:-false}" == true ]] && exit 22
      jq --argjson body "$data" --arg runtime "$GDC_TEST_RUNTIME" --arg model "$GDC_TEST_MODEL" \
        'map(if .node.id==$runtime then .node.models[$model].args=$body.models[$model].args | .state.deployment_update_pending=true | .state.reconcile_info={"status":"INFERENCE"} else . end)' "$GDC_TEST_NODES" >"$GDC_TEST_NODES.next"
      mv "$GDC_TEST_NODES.next" "$GDC_TEST_NODES"
      printf '{"ok":true}\n'
    else
      nodes="$(<"$GDC_TEST_NODES")"; printf '%s\n' "$nodes"
      if jq -e 'any(.[];.state.deployment_update_pending==true)' <<<"$nodes" >/dev/null && [[ "${GDC_TEST_FAIL_PENDING:-false}" != true ]]; then
        jq 'map(.state.deployment_update_pending=false | .state.reconcile_info=null)' "$GDC_TEST_NODES" >"$GDC_TEST_NODES.next"
        mv "$GDC_TEST_NODES.next" "$GDC_TEST_NODES"
        if jq -e --arg m "$GDC_TEST_MODEL" 'any(.[];.node.models[$m].args|index("--kv-cache-dtype")!=null)' "$GDC_TEST_NODES" >/dev/null; then
          bash "$GDC_TEST_START_ENGINE" desired >/dev/null 2>&1
        elif jq -e --arg m "$GDC_TEST_MODEL" 'any(.[]; .node.models[$m].args as $a | ($a|index("--max-num-seqs")) as $i | $i!=null and $a[$i+1]=="1")' "$GDC_TEST_NODES" >/dev/null; then
          bash "$GDC_TEST_START_ENGINE" seq1 >/dev/null 2>&1
        else
          bash "$GDC_TEST_START_ENGINE" before >/dev/null 2>&1
        fi
      fi
    fi
    ;;
  'exec mlnode-container curl '*http://127.0.0.1:5001/api/v1/pow/status)
    if [[ "${GDC_TEST_POW_BUSY:-false}" == true ]]; then printf '{"status":"RUNNING","config":{},"stats":{}}\n'; else printf '{"status":"IDLE","config":null,"stats":null}\n'; fi ;;
  'exec mlnode-container curl '*http://127.0.0.1:5000/v1/models) cat "$GDC_TEST_MODELS" ;;
  'exec mlnode-container curl '*http://127.0.0.1:5000/v1/chat/completions*) printf '{"choices":[{"message":{"content":"GDC_OK"}}]}\n' ;;
  *) echo "unexpected docker command: $*" >&2; exit 92 ;;
esac
SH
cat >"$mockbin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
printf '0\n'
SH
cat >"$tmp/start-engine.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>&- # Do not let the mock long-lived engine inherit the deployment lock.
mode="$1"; model=Qwen/Qwen2.5-7B-Instruct; dtype=bfloat16
seqs=32; [[ "$mode" == seq1 ]] && seqs=1
args=(--revision a09a35458c702b33eeacc393d103063234e8bc28 --dtype bfloat16 --max-num-seqs "$seqs" --gpu-memory-utilization 0.92 --max-model-len 4096 --kv-cache-memory-bytes 1073741824)
[[ "$mode" == desired ]] && args+=(--kv-cache-dtype fp8)
if [[ -s "$GDC_TEST_ENGINE_PID" ]]; then kill "$(<"$GDC_TEST_ENGINE_PID")" 2>/dev/null || true; fi
bash -c 'sleep 1200; :' gonka_poc.entrypoint.api_router --model "$model" --dtype "$dtype" "${args[@]}" --port 5001 --host 0.0.0.0 >/dev/null 2>&1 &
printf '%s\n' "$!" >"$GDC_TEST_ENGINE_PID"
if [[ "$mode" == desired ]]; then printf '{"data":[{"id":"Qwen/Qwen2.5-7B-Instruct"}]}\n' >"$GDC_TEST_MODELS"; fi
SH
chmod 0755 "$mockbin/"* "$tmp/start-engine.sh"
export GDC_TEST_TMP="$tmp" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" GDC_TEST_REMOTE_ROOT="$remote_root"
export GDC_TEST_ENGINE_PID="$tmp/engine.pid" GDC_TEST_MODELS="$tmp/models.json" GDC_TEST_NODES="$tmp/nodes.json" GDC_TEST_START_ENGINE="$tmp/start-engine.sh"
export GDC_TEST_IMAGE='ml:1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
export GDC_TEST_RUNTIME='runtime:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' GDC_TEST_MODEL='Qwen/Qwen2.5-7B-Instruct'
mkdir -p "$operator/genesis" "$operator/fixture-host/state/identities" "$operator/accounts" "$operator/fixture-host/state/joined" "$remote_root/shared" "$remote_root/deploy" "$remote_root/deploy/fixture-host"
printf '{"chain_id":"fixture-chain"}\n' >"$operator/genesis/genesis.json"; cp "$operator/genesis/genesis.json" "$remote_root/shared/genesis.json"
printf '{"node_id":"0123456789abcdef0123456789abcdef01234567"}\n' >"$operator/fixture-host/state/identities/fixture-host.json"
printf '{"address":"gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' >"$operator/accounts/fixture-host-cold.json"; touch "$operator/fixture-host/state/joined/fixture-host"
cat >"$tmp/descriptor.json" <<'JSON'
{"gpu_device":"0","host_docker_network":"fixture-net","hf_cache_root":"/srv/hf-cache","nginx_image":"nginx:1.28@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","primary":{"model_id":"Qwen/Qwen2.5-7B-Instruct","revision":"a09a35458c702b33eeacc393d103063234e8bc28","image":"ml:1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","args":["--revision","a09a35458c702b33eeacc393d103063234e8bc28","--dtype","bfloat16","--max-num-seqs","32","--gpu-memory-utilization","0.92","--max-model-len","4096","--kv-cache-memory-bytes","1073741824","--kv-cache-dtype","fp8"],"management_port":8080,"inference_port":5000},"secondary":{"model_id":"Qwen/Qwen3-4B-Instruct-2507","revision":"secrev","image":"ml:1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","args":["--revision","secrev","--dtype","bfloat16","--gpu-memory-utilization","0.32"],"management_port":8080,"inference_port":5000}}
JSON
jq '{model_id:.primary.model_id,args:.primary.args}' "$tmp/descriptor.json" >"$tmp/desired.json"
for layout in canonical legacy; do
  deploy="$remote_root/deploy"; [[ "$layout" == legacy ]] && deploy="$remote_root/deploy/fixture-host"
  mkdir -p "$deploy"; printf 'true\n' >"$deploy/.local-ml"; printf '{}\n' >"$deploy/compose.yaml"; printf 'MLNODE_COMPOSE_VARIANT=nvidia\n' >"$deploy/.env"
  jq -n --arg id "$GDC_TEST_RUNTIME" --argjson args '["--revision","a09a35458c702b33eeacc393d103063234e8bc28","--dtype","bfloat16","--max-num-seqs","32","--gpu-memory-utilization","0.92","--max-model-len","4096","--kv-cache-memory-bytes","1073741824"]' '[{host:"inference",inference_segment:"/v1",inference_port:5000,poc_segment:"/v1",poc_port:5001,models:{"Qwen/Qwen2.5-7B-Instruct":{args:$args}},id:$id,max_concurrent:1,hardware:{}}]' >"$deploy/node-config.json"
  jq 'map(del(.inference_segment,.poc_segment,.hardware))' "$deploy/node-config.json" >"$deploy/node-config.json.next"; mv "$deploy/node-config.json.next" "$deploy/node-config.json"
  export GDC_TEST_DEPLOY="$deploy"
  initial_assignment='{"Qwen/Qwen2.5-7B-Instruct":{"node_id":"runtime:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","poc_weight":12139,"timeslot_allocation":[true,false]}}'
  [[ "$layout" == canonical ]] || initial_assignment='{}'
  jq -n --arg id "$GDC_TEST_RUNTIME" --argjson assignment "$initial_assignment" --argjson args '["--revision","a09a35458c702b33eeacc393d103063234e8bc28","--dtype","bfloat16","--max-num-seqs","32","--gpu-memory-utilization","0.92","--max-model-len","4096","--kv-cache-memory-bytes","1073741824"]' \
    '[{node:{host:"inference",inference_segment:"",inference_port:5000,poc_segment:"",poc_port:5001,models:{"Qwen/Qwen2.5-7B-Instruct":{args:$args}},id:$id,max_concurrent:1,hardware:[{type:"NVIDIA GeForce RTX 5090 | 31GB",count:1}]},state:{lock_count:0,epoch_ml_nodes:$assignment,epoch_models:{"Qwen/Qwen2.5-7B-Instruct":{}},preserved_models:{},admin_state:{enabled:true},current_status:"INFERENCE",intended_status:"INFERENCE",poc_current_status:"IDLE",deployment_update_pending:false}}]' >"$GDC_TEST_NODES"
  printf '{"data":[{"id":"Qwen/Qwen2.5-7B-Instruct"}]}\n' >"$GDC_TEST_MODELS"; "$tmp/start-engine.sh" before
  plan="$tmp/$layout.plan.json"
  run_helper() { env -i PATH="$mockbin:/usr/bin:/bin" GDC_HOME="$operator" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" GDC_TEST_REMOTE_ROOT="$remote_root" GDC_TEST_TMP="$tmp" GDC_TEST_DEPLOY="$GDC_TEST_DEPLOY" GDC_TEST_IMAGE="$GDC_TEST_IMAGE" GDC_TEST_ENGINE_PID="$GDC_TEST_ENGINE_PID" GDC_TEST_MODELS="$GDC_TEST_MODELS" GDC_TEST_NODES="$GDC_TEST_NODES" GDC_TEST_START_ENGINE="$GDC_TEST_START_ENGINE" GDC_TEST_RUNTIME="$GDC_TEST_RUNTIME" GDC_TEST_MODEL="$GDC_TEST_MODEL" GDC_NODE_ALIASES=fixture-host CHAIN_ID=fixture-chain GDC_MODEL_RECONFIGURE_TIMEOUT_SECONDS=30 bash "$kit/scripts/phase-model-primary-reconfigure.sh" "$@"; }
  if ! run_helper plan fixture-host "$tmp/descriptor.json" "$tmp/desired.json" "$plan" >"$tmp/$layout-plan.out" 2>&1; then cat "$tmp/$layout-plan.out" >&2; exit 1; fi
  [[ "$(<"$tmp/$layout-plan.out")" == *'READY model-primary-resource-retune'* ]]
  base64 -d <<<"$(jq -er .before.disk_config_raw_b64 "$plan")" | cmp - "$deploy/node-config.json"
  jq -e --arg layout "$layout" '.before.node.hardware==[{"type":"NVIDIA GeForce RTX 5090 | 31GB","count":1}] and .before.node.inference_segment=="" and .before.node.poc_segment=="" and ((.before.assignment_mode=="assigned" and .before.assignment["Qwen/Qwen2.5-7B-Instruct"].node_id=="runtime:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") or (.before.assignment_mode=="ready-unassigned" and .before.assignment=={})) and ((.before.assignment_mode=="ready-unassigned") == ($layout=="legacy"))' "$plan" >/dev/null
  inode_before="$(stat -c %i "$deploy/node-config.json")"
  if ! run_helper apply fixture-host "$tmp/descriptor.json" "$tmp/desired.json" "$plan" >"$tmp/$layout-apply.out" 2>&1; then cat "$tmp/$layout-apply.out" >&2; exit 1; fi
  [[ "$(<"$tmp/$layout-apply.out")" == *'PASS model-primary-resource-retune'* ]]
  [[ "$(stat -c %i "$deploy/node-config.json")" == "$inode_before" ]]
  jq -e --arg id "$GDC_TEST_RUNTIME" --argjson args "$(jq -c .args "$tmp/desired.json")" 'any(.[];.id==$id and .models["Qwen/Qwen2.5-7B-Instruct"].args==$args)' "$deploy/node-config.json" >/dev/null
  jq -e --arg layout "$layout" '.[0].state.deployment_update_pending==false and ((.[0].state.epoch_ml_nodes["Qwen/Qwen2.5-7B-Instruct"].node_id=="runtime:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and $layout=="canonical") or (.[0].state.epoch_ml_nodes=={} and $layout=="legacy"))' "$GDC_TEST_NODES" >/dev/null
  receipt="$(jq -r .receipt "$remote_root"/deploy/.gdc-model-resource-retunes/*/apply-result.json 2>/dev/null|tail -n1 || true)"
  [[ -n "$receipt" ]] || { echo 'missing PASS apply receipt' >&2; exit 1; }
  # A descriptor-bound inverse must remove exactly the added FP8 flag and
  # restore the original model argument vector through the same DAPI path.
  jq --argjson args '["--revision","a09a35458c702b33eeacc393d103063234e8bc28","--dtype","bfloat16","--max-num-seqs","32","--gpu-memory-utilization","0.92","--max-model-len","4096","--kv-cache-memory-bytes","1073741824"]' '.primary.args=$args' "$tmp/descriptor.json" >"$tmp/inverse-descriptor.json"
  jq '{model_id:.primary.model_id,args:.primary.args}' "$tmp/inverse-descriptor.json" >"$tmp/inverse-desired.json"
  inverse_plan="$tmp/$layout.inverse.plan.json"
  run_helper plan fixture-host "$tmp/inverse-descriptor.json" "$tmp/inverse-desired.json" "$inverse_plan" >/dev/null
  run_helper apply fixture-host "$tmp/inverse-descriptor.json" "$tmp/inverse-desired.json" "$inverse_plan" >"$tmp/$layout-inverse-apply.out"
  [[ "$(<"$tmp/$layout-inverse-apply.out")" == *'PASS model-primary-resource-retune'* ]]
  jq -e --argjson args "$(jq -c .args "$tmp/inverse-desired.json")" 'any(.[];.models["Qwen/Qwen2.5-7B-Instruct"].args==$args)' "$deploy/node-config.json" >/dev/null

  # max-num-seqs 32->1 and its exact inverse are independently planned and
  # applied in both deployment layouts; all other resource args stay fixed.
  jq '.primary.args |= (.[(index("--max-num-seqs") + 1)]="1")' "$tmp/inverse-descriptor.json" >"$tmp/seq1-descriptor.json"
  jq '{model_id:.primary.model_id,args:.primary.args}' "$tmp/seq1-descriptor.json" >"$tmp/seq1-desired.json"
  seq1_plan="$tmp/$layout.seq1.plan.json"
  run_helper plan fixture-host "$tmp/seq1-descriptor.json" "$tmp/seq1-desired.json" "$seq1_plan" >"$tmp/$layout-seq1-plan.out"
  [[ "$(<"$tmp/$layout-seq1-plan.out")" == *'READY model-primary-resource-retune'* ]]
  jq -e '.before.runtime_resources.max_num_seqs=="32" and .desired.args[(.desired.args|index("--max-num-seqs"))+1]=="1"' "$seq1_plan" >/dev/null
  run_helper apply fixture-host "$tmp/seq1-descriptor.json" "$tmp/seq1-desired.json" "$seq1_plan" >"$tmp/$layout-seq1-apply.out"
  [[ "$(<"$tmp/$layout-seq1-apply.out")" == *'PASS model-primary-resource-retune'* ]]
  jq -e --argjson args "$(jq -c .args "$tmp/seq1-desired.json")" 'any(.[];.models["Qwen/Qwen2.5-7B-Instruct"].args==$args)' "$deploy/node-config.json" >/dev/null
  jq '.primary.args |= (.[(index("--max-num-seqs")+1)]="32")' "$tmp/inverse-descriptor.json" >"$tmp/seq32-descriptor.json"
  jq '{model_id:.primary.model_id,args:.primary.args}' "$tmp/seq32-descriptor.json" >"$tmp/seq32-desired.json"
  seq32_plan="$tmp/$layout.seq32.inverse.plan.json"
  run_helper plan fixture-host "$tmp/seq32-descriptor.json" "$tmp/seq32-desired.json" "$seq32_plan" >"$tmp/$layout-seq32-plan.out"
  [[ "$(<"$tmp/$layout-seq32-plan.out")" == *'READY model-primary-resource-retune'* ]]
  jq -e '.before.runtime_resources.max_num_seqs=="1" and .desired.args[(.desired.args|index("--max-num-seqs"))+1]=="32"' "$seq32_plan" >/dev/null
  run_helper apply fixture-host "$tmp/seq32-descriptor.json" "$tmp/seq32-desired.json" "$seq32_plan" >"$tmp/$layout-seq32-apply.out"
  [[ "$(<"$tmp/$layout-seq32-apply.out")" == *'PASS model-primary-resource-retune'* ]]
  jq -e --argjson args "$(jq -c .args "$tmp/seq32-desired.json")" 'any(.[];.models["Qwen/Qwen2.5-7B-Instruct"].args==$args)' "$deploy/node-config.json" >/dev/null
done

# Stale plans and forbidden non-resource/model changes fail before mutation.
cp "$tmp/descriptor.json" "$tmp/bad-descriptor.json"; jq '.primary.args |= (.[1]="changedrev")' "$tmp/bad-descriptor.json" >"$tmp/bad.json"
if env -i PATH="$mockbin:/usr/bin:/bin" GDC_HOME="$operator" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" GDC_NODE_ALIASES=fixture-host CHAIN_ID=fixture-chain bash "$kit/scripts/phase-model-primary-reconfigure.sh" plan fixture-host "$tmp/descriptor.json" "$tmp/bad.json" "$tmp/forbidden.plan" >/dev/null 2>&1; then echo 'non-resource args unexpectedly accepted' >&2; exit 1; fi

# Recreate a ready assigned 7B state before each guard case; successful prior
# layouts leave the inverse args installed.
GDC_TEST_DEPLOY="$remote_root/deploy"
jq -n --arg id "$GDC_TEST_RUNTIME" --argjson args '["--revision","a09a35458c702b33eeacc393d103063234e8bc28","--dtype","bfloat16","--max-num-seqs","32","--gpu-memory-utilization","0.92","--max-model-len","4096","--kv-cache-memory-bytes","1073741824"]' '[{host:"inference",inference_segment:"/v1",inference_port:5000,poc_segment:"/v1",poc_port:5001,models:{"Qwen/Qwen2.5-7B-Instruct":{args:$args}},id:$id,max_concurrent:1,hardware:{}}]' >"$GDC_TEST_DEPLOY/node-config.json"
jq 'map(del(.inference_segment,.poc_segment,.hardware))' "$GDC_TEST_DEPLOY/node-config.json" >"$GDC_TEST_DEPLOY/node-config.json.next"; mv "$GDC_TEST_DEPLOY/node-config.json.next" "$GDC_TEST_DEPLOY/node-config.json"
jq -n --arg id "$GDC_TEST_RUNTIME" --argjson args '["--revision","a09a35458c702b33eeacc393d103063234e8bc28","--dtype","bfloat16","--max-num-seqs","32","--gpu-memory-utilization","0.92","--max-model-len","4096","--kv-cache-memory-bytes","1073741824"]' \
  '[{node:{host:"inference",inference_segment:"",inference_port:5000,poc_segment:"",poc_port:5001,models:{"Qwen/Qwen2.5-7B-Instruct":{args:$args}},id:$id,max_concurrent:1,hardware:[{type:"NVIDIA GeForce RTX 5090 | 31GB",count:1}]},state:{lock_count:0,epoch_ml_nodes:{"Qwen/Qwen2.5-7B-Instruct":{"node_id":"runtime:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","poc_weight":12139,"timeslot_allocation":[true,false]}},epoch_models:{"Qwen/Qwen2.5-7B-Instruct":{}},preserved_models:{},admin_state:{enabled:true},current_status:"INFERENCE",intended_status:"INFERENCE",poc_current_status:"IDLE",deployment_update_pending:false}}]' >"$GDC_TEST_NODES"
cp "$GDC_TEST_DEPLOY/node-config.json" "$tmp/base-node-config.json"
"$tmp/start-engine.sh" before
# The FP8-specific delta is exactly one flag/value pair; malformed or mixed
# resource changes must fail during planning before DAPI is called.
for scenario in kv-auto kv-duplicate kv-missing-value kv-mixed-resource seq-zero seq-31 seq-duplicate seq-missing-value seq-mixed-resource; do
  case "$scenario" in
    kv-auto) jq '.primary.args[-1]="auto"' "$tmp/descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    kv-duplicate) jq '.primary.args += ["--kv-cache-dtype","fp8"]' "$tmp/descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    kv-missing-value) jq '.primary.args += ["--kv-cache-dtype"]' "$tmp/descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    kv-mixed-resource) jq '.primary.args |= (.[(index("--gpu-memory-utilization")+1)]="0.58")' "$tmp/descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    seq-zero) jq '.primary.args |= (.[(index("--max-num-seqs")+1)]="0")' "$tmp/inverse-descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    seq-31) jq '.primary.args |= (.[(index("--max-num-seqs")+1)]="31")' "$tmp/inverse-descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    seq-duplicate) jq '.primary.args += ["--max-num-seqs","32"]' "$tmp/inverse-descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    seq-missing-value) jq '.primary.args += ["--max-num-seqs"]' "$tmp/inverse-descriptor.json" >"$tmp/invalid-descriptor.json" ;;
    seq-mixed-resource) jq '.primary.args += ["--kv-cache-dtype","fp8"] | .primary.args |= (.[(index("--max-num-seqs")+1)]="1")' "$tmp/inverse-descriptor.json" >"$tmp/invalid-descriptor.json" ;;
  esac
  jq '{model_id:.primary.model_id,args:.primary.args}' "$tmp/invalid-descriptor.json" >"$tmp/invalid-desired.json"
  if run_helper plan fixture-host "$tmp/invalid-descriptor.json" "$tmp/invalid-desired.json" "$tmp/$scenario.plan" >/dev/null 2>&1; then
    echo "$scenario retune unexpectedly planned" >&2; exit 1
  fi
done
# A lock, broken assignment, preserved obligation, disabled state, short PoC
# window, or busy independent backend must reject before any mutation.
for scenario in lock assignment preserved disabled poc-window poc-status unassigned-missing-model backend-busy segment-drift hardware-drift; do
  cp "$tmp/base-node-config.json" "$GDC_TEST_DEPLOY/node-config.json"
  original="$(<"$GDC_TEST_NODES")"
  case "$scenario" in
    lock) jq '.[0].state.lock_count=1' "$GDC_TEST_NODES" >"$tmp/state.json" ;;
    assignment) jq '.[0].state.epoch_ml_nodes={"other":{"node_id":"runtime:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","poc_weight":12139,"timeslot_allocation":[true,false]}}' "$GDC_TEST_NODES" >"$tmp/state.json" ;;
    preserved) jq '.[0].state.preserved_models={"other":true}' "$GDC_TEST_NODES" >"$tmp/state.json" ;;
    disabled) jq '.[0].state.admin_state.enabled=false' "$GDC_TEST_NODES" >"$tmp/state.json" ;;
    poc-window) export GDC_TEST_EPOCH_NEAR=true ;;
    poc-status) jq '.[0].state.poc_current_status="VALIDATING"' "$GDC_TEST_NODES" >"$tmp/state.json" ;;
    unassigned-missing-model) jq '.[0].state.epoch_ml_nodes={} | .[0].state.epoch_models={"Qwen/other":{}}' "$GDC_TEST_NODES" >"$tmp/state.json" ;;
    backend-busy) export GDC_TEST_POW_BUSY=true ;;
    segment-drift) jq '.[0].node.inference_segment="unexpected"' "$GDC_TEST_NODES" >"$tmp/state.json" ;;
    hardware-drift) jq '.[0].hardware=[{"type":"wrong GPU","count":1}]' "$GDC_TEST_DEPLOY/node-config.json" >"$tmp/node-config.json"; mv "$tmp/node-config.json" "$GDC_TEST_DEPLOY/node-config.json" ;;
  esac
  if [[ -f "$tmp/state.json" ]]; then cp "$tmp/state.json" "$GDC_TEST_NODES"; fi
  if env -i PATH="$mockbin:/usr/bin:/bin" GDC_HOME="$operator" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" GDC_TEST_REMOTE_ROOT="$remote_root" GDC_TEST_DEPLOY="$GDC_TEST_DEPLOY" GDC_TEST_IMAGE="$GDC_TEST_IMAGE" GDC_TEST_ENGINE_PID="$GDC_TEST_ENGINE_PID" GDC_TEST_MODELS="$GDC_TEST_MODELS" GDC_TEST_NODES="$GDC_TEST_NODES" GDC_TEST_START_ENGINE="$GDC_TEST_START_ENGINE" GDC_TEST_RUNTIME="$GDC_TEST_RUNTIME" GDC_TEST_MODEL="$GDC_TEST_MODEL" GDC_TEST_EPOCH_NEAR="${GDC_TEST_EPOCH_NEAR:-false}" GDC_TEST_POW_BUSY="${GDC_TEST_POW_BUSY:-false}" GDC_NODE_ALIASES=fixture-host CHAIN_ID=fixture-chain GDC_MODEL_RECONFIGURE_TIMEOUT_SECONDS=1 bash "$kit/scripts/phase-model-primary-reconfigure.sh" plan fixture-host "$tmp/descriptor.json" "$tmp/desired.json" "$tmp/$scenario.plan" >/dev/null 2>&1; then echo "$scenario guard unexpectedly passed" >&2; exit 1; fi
  printf '%s\n' "$original" >"$GDC_TEST_NODES"; rm -f "$tmp/state.json"; unset GDC_TEST_EPOCH_NEAR GDC_TEST_POW_BUSY 2>/dev/null || true
done
printf 'PASS real embedded Bash plan/apply, DAPI pending-to-complete reconciliation, same-inode config persistence, canonical+legacy FP8 and max-num-seqs inverse layouts, and resource guard rejection fixtures\n'
