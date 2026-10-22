#!/usr/bin/env bash
# Receipt-bound DAPI-driven resource retune of an already configured model.
# DAPI owns the restart; this helper never calls MLNode down/up directly.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
usage() { echo "Usage: $0 plan|apply HOST shared-gpu-descriptor.json desired-primary.json PLAN.json" >&2; }
ACTION="${1:-}"; NODE="${2:-}"; DESCRIPTOR="${3:-}"; DESIRED="${4:-}"; PLAN_PATH="${5:-}"
[[ "$ACTION" == plan || "$ACTION" == apply ]] || { usage; exit 2; }
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -s "$DESCRIPTOR" && -f "$DESCRIPTOR" && ! -L "$DESCRIPTOR" \
  && -s "$DESIRED" && -f "$DESIRED" && ! -L "$DESIRED" && "$PLAN_PATH" == /* ]] || { usage; exit 2; }
[[ ! -L "$PLAN_PATH" ]] || die 'plan path must not be a symlink'
if [[ "$ACTION" == plan ]]; then [[ ! -e "$PLAN_PATH" ]] || die 'plan output already exists'; else [[ -s "$PLAN_PATH" ]] || die 'apply requires an existing plan'; fi
topology_contains_node "$NODE" || die "resource-retune target is not in GDC_NODE_ALIASES: $NODE"
"$ROOT/../devnet/model-layouts/shared-gpu/validate.sh" "$DESCRIPTOR"
model_id="$(jq -er '.primary.model_id|select(type=="string" and length>0)' "$DESCRIPTOR")"
revision="$(jq -er '.primary.revision|select(type=="string" and length>0)' "$DESCRIPTOR")"
desired_json="$(jq -c . "$DESIRED")"
jq -e --arg model "$model_id" --slurpfile d "$DESCRIPTOR" '
  type=="object" and (keys|sort)==["args","model_id"] and .model_id==$model and .args==$d[0].primary.args and
  (.args|type)=="array"
' <<<"$desired_json" >/dev/null || die 'desired-primary must equal descriptor args and include each reviewed resource flag once'
network_locks=(); legacy_locks=()
for f in "$ROOT"/../model/*.lock; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  lock_model="$(awk -F= '$1 == "MODEL_ID" {print $2; exit}' "$f")"
  [[ "$lock_model" == "$model_id" ]] || continue
  scope="$(awk -F= '$1 == "GDC_MODEL_PROFILE_SCOPE" {print $2; exit}' "$f")"
  case "$scope" in
    network) network_locks+=("$f") ;;
    qualification-only) ;;
    '') [[ "$model_id" == "Qwen/Qwen3-0.6B" ]] && legacy_locks+=("$f") ;;
    *) die "unsupported model profile scope in ${f##*/}" ;;
  esac
done
if ((${#network_locks[@]} == 1)); then
  model_lock="${network_locks[0]}"
elif ((${#network_locks[@]} > 1)); then
  die 'multiple network model locks match the selected model'
elif ((${#legacy_locks[@]} == 1)); then
  model_lock="${legacy_locks[0]}"
else
  die 'no unique network model lock matches the selected model'
fi
lock_revision="$(awk -F= '$1 == "MODEL_SOURCE_REVISION" {print $2; found=1; exit} $1 == "MODEL_REVISION" {fallback=$2} END {if (!found && fallback) print fallback}' "$model_lock")"
[[ "$lock_revision" == "$revision" ]] || die 'selected network model lock revision differs from the descriptor'
lock_sha="$(sha256sum "$model_lock"|awk '{print $1}')"; script_sha="$(sha256sum "$0"|awk '{print $1}')"
descriptor_sha="$(sha256sum "$DESCRIPTOR"|awk '{print $1}')"; desired_sha="$(printf '%s' "$desired_json"|sha256sum|awk '{print $1}')"
chain_id="${CHAIN_ID:?CHAIN_ID is required}"; genesis_sha="$(genesis_sha256 "$GENESIS/genesis.json")" || die 'local Genesis unavailable'
timeout="${GDC_MODEL_RECONFIGURE_TIMEOUT_SECONDS:-900}"
[[ "$timeout" =~ ^[1-9][0-9]{0,3}$ && "$timeout" -le 1800 ]] || die 'timeout must be 1..1800 seconds'
identity="$(node_identity_file "$NODE")"; account="$(node_account_file "$NODE")"
[[ -s "$identity" && ! -L "$identity" && -s "$account" && ! -L "$account" && -e "$(node_joined_marker "$NODE")" ]] || die 'safe completed JOIN identity required'
core_id="$(jq -er '.node_id|select(test("^[a-f0-9]{40}$"))' "$identity")"
participant="$(jq -er '.address|select(test("^gonka1[0-9a-z]{20,90}$"))' "$account")"
runtime_id="$(runtime_id_for_participant "$participant")"
descriptor_b64="$(base64 -w0 <"$DESCRIPTOR")"; desired_b64="$(printf '%s' "$desired_json"|base64 -w0)"; plan_b64=''
if [[ "$ACTION" == apply ]]; then
  jq -e --arg h "$NODE" --arg s "$script_sha" --arg d "$descriptor_sha" --arg r "$desired_sha" --arg l "$lock_sha" --arg c "$chain_id" --arg g "$genesis_sha" '
    .schema_version==1 and .kind=="gdc-model-primary-resource-retune" and .host==$h and
    .pins.script_sha256==$s and .pins.descriptor_sha256==$d and .pins.desired_sha256==$r and .pins.model_lock_sha256==$l and
    .identity.chain_id==$c and .identity.genesis_sha256==$g and ((now|floor)-.created_at)>=0 and ((now|floor)-.created_at)<=600
  ' "$PLAN_PATH" >/dev/null || die 'plan expired or input/source pins changed'
  plan_b64="$(base64 -w0 <"$PLAN_PATH")"
fi
remote_rc=0
result="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$NODE" \
  "sudo bash -s -- '$ACTION' '$NODE' '$chain_id' '$genesis_sha' '$core_id' '$runtime_id' '$descriptor_b64' '$desired_b64' '$plan_b64' '$script_sha' '$descriptor_sha' '$desired_sha' '$lock_sha' '$timeout'" <<'REMOTE'
set -Eeuo pipefail
action="$1"; host="$2"; chain="$3"; genesis="$4"; core="$5"; runtime="$6"
descriptor="$(printf '%s' "$7"|base64 -d)"; desired="$(printf '%s' "$8"|base64 -d)"; plan=''
[[ -z "$9" ]] || plan="$(printf '%s' "$9"|base64 -d)"
script_sha="${10}"; descriptor_sha="${11}"; desired_sha="${12}"; lock_sha="${13}"; timeout="${14}"
model="$(jq -er .primary.model_id <<<"$descriptor")"; revision="$(jq -er .primary.revision <<<"$descriptor")"
image="$(jq -er .primary.image <<<"$descriptor")"; gpu="$(jq -er .gpu_device <<<"$descriptor")"
args="$(jq -ce .args <<<"$desired")"; served_model="$(jq -r --arg m "$model" '([range(0;(.args|length)) as $i|select(.args[$i]=="--served-model-name")|.args[$i+1]]|last)//$m' <<<"$desired")"
fail() { echo "$1" >&2; exit 1; }
  resources() {
  jq -ce 'def v($f):([range(0;length) as $i|select(.[ $i ]==$f)|.[ $i+1]]|if length==0 then null elif length==1 then .[0] else error("duplicate flag") end);
    {gpu:v("--gpu-memory-utilization"),batch:v("--max-num-batched-tokens"),kv:v("--kv-cache-memory-bytes"),kv_dtype:v("--kv-cache-dtype"),max_num_seqs:v("--max-num-seqs")}' <<<"$1"
}
strip_resources() {
  jq -c '. as $a|reduce range(0;($a|length)) as $i ({out:[],skip:false}; if .skip then .skip=false
    elif (["--gpu-memory-utilization","--max-num-batched-tokens","--kv-cache-memory-bytes","--kv-cache-dtype","--max-num-seqs"]|index($a[$i]))!=null then .skip=true
    else .out += [$a[$i]] end)|.out' <<<"$1"
}
resource_valid() {
  jq -e 'def count($f):[range(0;length) as $i|select(.[$i]==$f)]|length;
    (count("--gpu-memory-utilization")<=1 and count("--max-num-batched-tokens")<=1 and count("--kv-cache-memory-bytes")<=1 and count("--kv-cache-dtype")<=1 and count("--max-num-seqs")<=1)' <<<"$1" >/dev/null || return 1
  jq -e 'def val($f):([range(0;length) as $i|select(.[$i]==$f)|.[$i+1]]|if length==0 then null elif length==1 then .[0] else error("duplicate") end);
    def pair($f): . as $a | ([range(0;($a|length)) as $i|select($a[$i]==$f)|$i]) as $p |
      if ($p|length)==0 then true elif ($p|length)==1 then $p[0]+1<($a|length) else false end;
    ((val("--gpu-memory-utilization")==null or (val("--gpu-memory-utilization")|test("^0\\.[0-9]+$"))) and
     (val("--max-num-batched-tokens")==null or (val("--max-num-batched-tokens")|test("^[1-9][0-9]*$"))) and
     (val("--kv-cache-memory-bytes")==null or (val("--kv-cache-memory-bytes")|test("^[1-9][0-9]*$"))) and
     (val("--kv-cache-dtype")==null or val("--kv-cache-dtype")=="fp8") and
     (val("--max-num-seqs")==null or val("--max-num-seqs")=="1" or val("--max-num-seqs")=="32") and
     pair("--gpu-memory-utilization") and pair("--max-num-batched-tokens") and
     pair("--kv-cache-memory-bytes") and pair("--kv-cache-dtype") and pair("--max-num-seqs"))' <<<"$1" >/dev/null
}
assignment_valid() {
  local live="$1" mode="${2:-}"
  jq -e --arg m "$model" --arg r "$runtime" --arg mode "$mode" '
    (.state.epoch_ml_nodes|type)=="object" and
    (if $mode=="assigned" then
       ((.state.epoch_ml_nodes|keys)==[$m] and .state.epoch_ml_nodes[$m].node_id==$r)
     elif $mode=="ready-unassigned" then
       (.state.epoch_ml_nodes=={} and .node.id==$r and
        (.state.epoch_models|type)=="object" and (.state.epoch_models|has($m)))
     else
       (((.state.epoch_ml_nodes|keys)==[$m] and .state.epoch_ml_nodes[$m].node_id==$r) or
        (.state.epoch_ml_nodes=={} and .node.id==$r and
         (.state.epoch_models|type)=="object" and (.state.epoch_models|has($m))))
     end)
  ' <<<"$live" >/dev/null
}
engine() {
  local pids line pid n=0 argv models e
  ENGINE_PID=''; ENGINE_ARGV=''
  pids="$(docker top "$MLNODE" -eo pid|tail -n +2)"
  while IFS= read -r line; do
    [[ "$line" =~ ^[1-9][0-9]*$ ]] || continue; pid="$line"; [[ -r "/proc/$pid/cmdline" ]] || continue
    argv="$(jq -Rs 'split("\u0000")|map(select(length>0))' "/proc/$pid/cmdline")"
    if jq -e 'index("gonka_poc.entrypoint.api_router")!=null' <<<"$argv" >/dev/null; then ENGINE_PID="$pid"; ENGINE_ARGV="$argv"; ((n+=1)); fi
  done <<<"$pids"
  [[ "$n" == 1 ]] || return 1
  models="$(docker exec "$MLNODE" curl -fsS --connect-timeout 5 --max-time 10 http://127.0.0.1:5000/v1/models)"
  e="$(jq -c '
    . as $a|([range(0;length) as $i|select($a[$i]=="--model")|$a[$i+1]]|last) as $m
    |([range(0;length) as $i|select($a[$i]=="--dtype")|$a[$i+1]]|last//"auto") as $d
    |([range(0;length) as $i|select($a[$i]=="--revision")|$a[$i+1]]|last//null) as $r
    |([range(0;length) as $i|select($a[$i]=="gonka_poc.entrypoint.api_router")|$i]|first) as $at
    |if $m==null or $at==null then error("invalid engine argv") else . end|.[($at+1):] as $x
    |(reduce range(0;($x|length)) as $i ({out:[],skip:false};if .skip then .skip=false
      elif (["--model","--dtype","--port","--host","--gpu-memory-utilization","--max-num-batched-tokens","--kv-cache-memory-bytes","--kv-cache-dtype","--max-num-seqs"]|index($x[$i]))!=null then .skip=true
      else .out += [$x[$i]] end)) as $base
    |{model:$m,dtype:$d,revision:$r,base:$base.out,resources:{gpu:([range(0;($x|length)) as $i|select($x[$i]=="--gpu-memory-utilization")|$x[$i+1]]|last//null),
      batch:([range(0;($x|length)) as $i|select($x[$i]=="--max-num-batched-tokens")|$x[$i+1]]|last//null),
      kv:([range(0;($x|length)) as $i|select($x[$i]=="--kv-cache-memory-bytes")|$x[$i+1]]|last//null),
      kv_dtype:([range(0;($x|length)) as $i|select($x[$i]=="--kv-cache-dtype")|$x[$i+1]]|last//null),
      max_num_seqs:([range(0;($x|length)) as $i|select($x[$i]=="--max-num-seqs")|$x[$i+1]]|last//null)}}' <<<"$ENGINE_ARGV")"
  jq -cn --argjson engine "$e" --arg served "$served_model" --argjson models "$models" '{engine:$engine,served:$served,models:$models}'
}

snapshot() {
  local nodec apic deploy project ml mounts source devices envs indices status coreid nodes live disk dnode dapi epoch pow eng dsha
  nodec="$(docker ps -q --filter label=com.docker.compose.service=node)"; apic="$(docker ps -q --filter label=com.docker.compose.service=api)"
  [[ "$(wc -l <<<"$nodec"|tr -d ' ')" == 1 && "$(wc -l <<<"$apic"|tr -d ' ')" == 1 ]] || fail 'expected one Core and one DAPI container'
  deploy_label="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$nodec")"
  if [[ "$deploy_label" == /srv/dai/deploy ]]; then deploy=/srv/dai/deploy; elif [[ "$deploy_label" == "/srv/dai/deploy/$host" ]]; then deploy="/srv/dai/deploy/$host"; else fail 'unsupported validator deployment layout'; fi
  for f in .env compose.yaml node-config.json; do [[ -s "$deploy/$f" && ! -L "$deploy/$f" ]] || fail "missing/unsafe $f"; done
  [[ "$(cat "$deploy/.local-ml" 2>/dev/null||true)" == true ]] || fail 'deployment is not the reviewed local ML layout'
  project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$nodec")"
  MLNODE="$(docker compose --project-name "$project" --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" ps -q mlnode)"
  [[ -n "$MLNODE" && "$(docker inspect --format '{{.Config.Image}}' "$MLNODE")" == "$image" ]] || fail 'ML image differs from descriptor'
  mounts="$(docker inspect --format '{{json .Mounts}}' "$apic")"
  source="$(jq -er '[.[]|select(.Destination=="/root/node_config.json" and .Type=="bind")|.Source]|if length==1 then .[0] else error("ambiguous bind") end' <<<"$mounts")"
  [[ "$source" == "$deploy/node-config.json" && -s "$source" && ! -L "$source" ]] || fail 'DAPI config mount path mismatch'
  CONFIG="$source"; devices="$(docker inspect --format '{{json .HostConfig.DeviceRequests}}' "$MLNODE")"; envs="$(docker inspect --format '{{json .Config.Env}}' "$MLNODE")"
  indices="$(nvidia-smi --query-gpu=index --format=csv,noheader|jq -Rsc 'split("\n")|map(select(length>0))')"
  jq -e --arg g "$gpu" --argjson d "$devices" --argjson e "$envs" --argjson i "$indices" '($d|length)==1 and $d[0].Count==-1 and (($d[0].DeviceIDs//[])|length)==0 and any($d[0].Capabilities[];.==["gpu"]) and ($e|index("NVIDIA_VISIBLE_DEVICES=all")!=null) and $i==[$g]' <<<"{}" >/dev/null || fail 'GPU binding differs from descriptor'
  status="$(docker exec "$apic" curl -fsS --connect-timeout 5 --max-time 15 http://node:26657/status)"
  jq -e --arg c "$chain" --arg id "$core" '.result.node_info.network==$c and (.result.node_info.id|ascii_downcase)==$id' <<<"$status" >/dev/null || fail 'chain or Core node identity mismatch'
  deployed_genesis="$(jq -eS 'del(.app_name,.app_version)|if has("app_hash") then .app_hash=(.app_hash//"") else . end|if has("initial_height") then .initial_height=(.initial_height|tostring) else . end|if .consensus.params? then .consensus_params=.consensus.params|del(.consensus) else . end' /srv/dai/shared/genesis.json|sha256sum|awk '{print $1}')"
  [[ "$deployed_genesis" == "$genesis" ]] || fail 'deployed Genesis differs from reviewed canonical hash'
  nodes="$(docker exec "$apic" curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes)"
  live="$(jq -ce --arg id "$runtime" '[.[]|select(.node.id==$id)]|if length==1 then .[0] else error("DAPI identity missing/duplicate") end' <<<"$nodes")"
  dapi="$(docker exec "$apic" sha256sum /root/.dapi/cosmovisor/current/bin/decentralized-api|awk '{print $1}')"; [[ "$dapi" =~ ^[a-f0-9]{64}$ ]] || fail 'DAPI binary digest unavailable'
  disk="$(jq -ce . "$CONFIG")"; dnode="$(jq -ce --arg id "$runtime" '[.[]|select(.id==$id)]|if length==1 then .[0] else error("disk identity missing/duplicate") end' <<<"$disk")"
  jq -e --argjson n "$(jq -c .node <<<"$live")" '
    def config_fields: ["host","inference_segment","inference_port","poc_segment","poc_port","models","id","max_concurrent","hardware"];
    def live_fields: config_fields + ["node_num","registration_seq"];
    . as $cfg |
    (($cfg|keys-config_fields)|length)==0 and (($n|keys-live_fields)|length)==0 and
    ([$cfg|to_entries[]|select($n[.key]!=.value)]|length)==0 and
    (($n.inference_segment//"")==($cfg.inference_segment//"")) and
    (($n.poc_segment//"")==($cfg.poc_segment//"")) and
    (if ($cfg|has("hardware")) then $cfg.hardware==$n.hardware else true end)
  ' <<<"$dnode" >/dev/null || fail 'mounted config differs from DAPI on user-controlled fields'
  jq -e --arg m "$model" --arg r "$runtime" '.node.host=="inference" and .node.id==$r and .node.inference_port==5000 and (.node.models|keys)==[$m] and .state.lock_count==0 and ((.state.preserved_models//{})|length)==0 and .state.admin_state.enabled==true and .state.current_status=="INFERENCE" and .state.intended_status=="INFERENCE" and (.state.deployment_update_pending//false)==false and .state.reconcile_info==null and .state.poc_current_status=="IDLE"' <<<"$live" >/dev/null || fail 'DAPI is not an enabled, stable single-model INFERENCE worker with zero locks/preserved obligations and idle PoC'
  assignment_mode=assigned
  if ! assignment_valid "$live" assigned; then
    assignment_valid "$live" ready-unassigned || fail 'DAPI has neither the exact model assignment nor a ready single-model unassigned state'
    assignment_mode=ready-unassigned
  fi
  before_args="$(jq -ce --arg m "$model" '.node.models[$m].args' <<<"$live")"; disk_args="$(jq -ce --arg m "$model" '.models[$m].args' <<<"$dnode")"
  [[ "$before_args" == "$disk_args" ]] || fail 'disk and DAPI primary args differ'
  resource_valid "$before_args" && resource_valid "$args" || fail 'resource flags are duplicated or malformed'
  [[ "$(strip_resources "$before_args")" == "$(strip_resources "$args")" ]] || fail 'retune changes non-resource model arguments'
  before_resources="$(resources "$before_args")"; desired_resources="$(resources "$args")"
  [[ "$before_resources" != "$desired_resources" ]] || fail 'desired resource args are unchanged'
  jq -e --argjson before "$before_resources" --argjson desired "$desired_resources" '
    def only_seq_delta: $before.gpu==$desired.gpu and $before.batch==$desired.batch and
      $before.kv==$desired.kv and $before.kv_dtype==$desired.kv_dtype;
    def only_dtype_delta: $before.gpu==$desired.gpu and $before.batch==$desired.batch and
      $before.kv==$desired.kv and $before.max_num_seqs==$desired.max_num_seqs;
    if $before.max_num_seqs != $desired.max_num_seqs then
      (($before.max_num_seqs=="1" or $before.max_num_seqs=="32") and
       ($desired.max_num_seqs=="1" or $desired.max_num_seqs=="32") and only_seq_delta)
    elif $before.kv_dtype != $desired.kv_dtype then only_dtype_delta
    else true end
  ' <<<"{}" >/dev/null || fail 'KV dtype/max-num-seqs retune must change only its supported resource flag'
  epoch="$(docker exec "$apic" curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9000/v1/epochs/latest)"
  jq -e '.phase=="Inference" and .is_confirmation_poc_active==false and ((.epoch_stages.next_poc_start|tonumber)-(.block_height|tonumber)>=360)' <<<"$epoch" >/dev/null || fail 'chain PoC is open or fewer than 360 blocks from next PoC'
  pow="$(docker exec "$MLNODE" curl -fsS --connect-timeout 5 --max-time 10 http://127.0.0.1:5001/api/v1/pow/status)"
  jq -e '.status=="IDLE" and .config==null and .stats==null' <<<"$pow" >/dev/null || fail 'independent ML PoC backend is not idle'
  eng="$(engine)" || fail 'cannot verify current engine process/served model'
  expected_dtype="$(jq -r '([range(0;(.args|length)) as $i|select(.args[$i]=="--dtype")|.args[$i+1]]|last)//"auto"' <<<"$desired")"
  jq -e --arg m "$model" --arg s "$served_model" --arg d "$expected_dtype" --arg rev "$revision" --argjson r "$(resources "$before_args")" '.engine.model==$m and .served==$s and (.models.data|any(.[];.id==$s)) and .engine.dtype==$d and .engine.revision==$rev and .engine.resources==$r' <<<"$eng" >/dev/null || fail 'current engine model, revision, dtype, served ID or resource args differ from DAPI/descriptor'
  dsha="$(sha256sum "$CONFIG"|awk '{print $1}')"
  jq -cn --arg host "$host" --arg chain "$chain" --arg genesis "$deployed_genesis" --arg core "$core" --arg runtime "$runtime" --arg deploy "$deploy" --arg config "$CONFIG" --arg mlnode "$MLNODE" --arg dsha "$dsha" --arg raw "$(base64 -w0 <"$CONFIG")" --arg inode "$(stat -c %i "$CONFIG")" --arg mode "$(stat -c %a "$CONFIG")" --arg owner "$(stat -c %u:%g "$CONFIG")" --arg dapi "$dapi" --arg image "$image" --arg gpu "$gpu" --arg model "$model" --arg rev "$revision" --arg base "$(jq -c .engine.base <<<"$eng"|sha256sum|awk '{print $1}')" --arg dtype "$(jq -r .engine.dtype <<<"$eng")" --arg assignment_mode "$assignment_mode" --argjson node "$(jq -c .node <<<"$live")" --argjson dapi_state "$(jq -c .state <<<"$live")" --argjson assignment "$(jq -c .state.epoch_ml_nodes <<<"$live")" --argjson args "$before_args" --argjson res "$(jq -c .engine.resources <<<"$eng")" --argjson desired "$desired" --argjson epoch "$epoch" '{host:$host,chain_id:$chain,genesis_sha256:$genesis,core_node_id:$core,runtime_id:$runtime,deployment:$deploy,config_path:$config,mlnode:$mlnode,disk_sha256:$dsha,disk_config_raw_b64:$raw,config_inode:$inode,config_mode:$mode,config_owner:$owner,dapi_binary_sha256:$dapi,image:$image,gpu_device:$gpu,model_id:$model,revision:$rev,before_node:$node,dapi_state:$dapi_state,assignment:$assignment,assignment_mode:$assignment_mode,before_args:$args,runtime_base_sha256:$base,runtime_dtype:$dtype,runtime_resources:$res,desired:$desired,epoch:$epoch}'
}
state="$(snapshot)"
CONFIG="$(jq -er .config_path <<<"$state")"; MLNODE="$(jq -er .mlnode <<<"$state")"
if [[ "$action" == plan ]]; then
  jq -cn --arg host "$host" --arg s "$script_sha" --arg d "$descriptor_sha" --arg r "$desired_sha" --arg l "$lock_sha" --argjson time "$(date +%s)" --argjson x "$state" '{schema_version:1,kind:"gdc-model-primary-resource-retune",host:$host,created_at:$time,pins:{script_sha256:$s,descriptor_sha256:$d,desired_sha256:$r,model_lock_sha256:$l},identity:{chain_id:$x.chain_id,genesis_sha256:$x.genesis_sha256,core_node_id:$x.core_node_id,runtime_id:$x.runtime_id,deployment:$x.deployment,config_path:$x.config_path,dapi_binary_sha256:$x.dapi_binary_sha256,image:$x.image,gpu_device:$x.gpu_device},before:{disk_sha256:$x.disk_sha256,disk_config_raw_b64:$x.disk_config_raw_b64,config_inode:$x.config_inode,config_mode:$x.config_mode,config_owner:$x.config_owner,node:$x.before_node,dapi_state:$x.dapi_state,assignment:$x.assignment,assignment_mode:$x.assignment_mode,args:$x.before_args,runtime_base_sha256:$x.runtime_base_sha256,runtime_dtype:$x.runtime_dtype,runtime_resources:$x.runtime_resources},desired:$x.desired,epoch_at_plan:$x.epoch}'
  exit 0
fi
deploy_for_lock="$(jq -r .deployment <<<"$state")"
umask 077
exec 9>"$deploy_for_lock/.gdc-models.lock"
flock -n 9 || fail 'another host-model operation holds the deployment lock'
state="$(snapshot)"
CONFIG="$(jq -er .config_path <<<"$state")"; MLNODE="$(jq -er .mlnode <<<"$state")"
plan_checks="$(jq -cn --arg host "$host" --arg s "$script_sha" --arg d "$descriptor_sha" --arg r "$desired_sha" --arg l "$lock_sha" --argjson x "$state" --argjson p "$plan" '{schema:($p.schema_version==1 and $p.kind=="gdc-model-primary-resource-retune" and $p.host==$host),pins:($p.pins.script_sha256==$s and $p.pins.descriptor_sha256==$d and $p.pins.desired_sha256==$r and $p.pins.model_lock_sha256==$l),identity:($p.identity.chain_id==$x.chain_id and $p.identity.genesis_sha256==$x.genesis_sha256 and $p.identity.core_node_id==$x.core_node_id and $p.identity.runtime_id==$x.runtime_id and $p.identity.deployment==$x.deployment and $p.identity.config_path==$x.config_path and $p.identity.dapi_binary_sha256==$x.dapi_binary_sha256 and $p.identity.image==$x.image and $p.identity.gpu_device==$x.gpu_device),disk:($p.before.disk_sha256==$x.disk_sha256 and $p.before.disk_config_raw_b64==$x.disk_config_raw_b64 and $p.before.config_inode==$x.config_inode and $p.before.config_mode==$x.config_mode and $p.before.config_owner==$x.config_owner),dapi:($p.before.node==$x.before_node and $p.before.assignment==$x.assignment and $p.before.assignment_mode==$x.assignment_mode),runtime:($p.before.args==$x.before_args and $p.before.runtime_base_sha256==$x.runtime_base_sha256 and $p.before.runtime_dtype==$x.runtime_dtype and $p.before.runtime_resources==$x.runtime_resources),desired:($p.desired==$x.desired)}')"
jq -e 'all(.[]; .==true)' <<<"$plan_checks" >/dev/null || fail "plan mismatch: $(jq -r '[to_entries[]|select(.value!=true)|.key]|join(",")' <<<"$plan_checks")"
created="$(jq -er .created_at <<<"$plan")"; now="$(date +%s)"; ((now>=created && now-created<=600)) || fail 'plan expired'
key="$(printf '%s' "$plan"|sha256sum|awk '{print $1}')"; receipt="$(jq -r .identity.deployment <<<"$plan")/.gdc-model-resource-retunes/$key"
mkdir -p "${receipt%/*}"; [[ ! -L "${receipt%/*}" && ! -e "$receipt" ]] || fail 'receipt path occupied/unsafe'
umask 077; mkdir -m 0700 "$receipt"; cp -- "$CONFIG" "$receipt/before-node-config.json"
jq -cS --arg id "$runtime" --arg m "$model" --argjson a "$args" 'map(if .id==$id then .models[$m].args=$a else . end)' "$CONFIG" >"$receipt/after-node-config.json"
chmod 0600 "$receipt/before-node-config.json" "$receipt/after-node-config.json"
before_sha="$(sha256sum "$receipt/before-node-config.json"|awk '{print $1}')"; after_sha="$(sha256sum "$receipt/after-node-config.json"|awk '{print $1}')"
[[ "$before_sha" == "$(jq -r .before.disk_sha256 <<<"$plan")" ]] || fail 'receipt backup hash differs from plan'
jq -cn --arg key "$key" --arg before "$before_sha" --arg after "$after_sha" --arg inode "$(stat -c %i "$CONFIG")" '{plan_sha256:$key,before_sha256:$before,after_sha256:$after,config_inode:$inode}' >"$receipt/apply-intent.json"
chmod 0600 "$receipt/apply-intent.json"
apic="$(docker ps -q --filter label=com.docker.compose.service=api)"
target="$(jq -c --arg m "$model" --argjson a "$args" '{host,inference_segment,inference_port,poc_segment,poc_port,models,id,max_concurrent,hardware}|.models[$m].args=$a' <<<"$(jq -c .before.node <<<"$plan")")"
if ! docker exec "$apic" curl -fsS --connect-timeout 5 --max-time 20 -X POST http://127.0.0.1:9200/admin/v1/nodes -H 'Content-Type: application/json' --data-binary "$target" >/dev/null; then
  jq -cn --arg key "$key" --arg receipt "$receipt" '{outcome:"UNCERTAIN",phase:"dapi-upsert",plan_sha256:$key,receipt:$receipt,reason:"DAPI request failed; inspect live state before retry"}' >"$receipt/uncertain.json"; cat "$receipt/uncertain.json"; exit 4
fi
size="$(wc -c <"$receipt/after-node-config.json"|tr -d ' ')"; inode="$(jq -r .before.config_inode <<<"$plan")"
current_disk_sha="$(sha256sum "$CONFIG"|awk '{print $1}')"
if [[ "$current_disk_sha" == "$before_sha" ]]; then
  write_config=true
elif [[ "$current_disk_sha" == "$after_sha" ]]; then
  write_config=false
else
  write_config=unsafe
fi
if [[ "$write_config" == unsafe ]] || { [[ "$write_config" == true ]] && { ! cat "$receipt/after-node-config.json" >"$CONFIG" || ! truncate -s "$size" "$CONFIG" || ! sync -f "$CONFIG"; }; } \
  || [[ "$(stat -c %i "$CONFIG")" != "$inode" || "$(stat -c %a "$CONFIG")" != "$(jq -r .before.config_mode <<<"$plan")" || "$(stat -c %u:%g "$CONFIG")" != "$(jq -r .before.config_owner <<<"$plan")" ]]; then
  jq -cn --arg key "$key" --arg receipt "$receipt" '{outcome:"UNCERTAIN",phase:"disk-write",plan_sha256:$key,receipt:$receipt,reason:"DAPI accepted update but bind-mounted node-config persistence failed"}' >"$receipt/uncertain.json"; cat "$receipt/uncertain.json"; exit 4
fi
deadline=$((SECONDS+timeout)); while ((SECONDS<deadline)); do
  live="$(docker exec "$apic" curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes 2>/dev/null||true)"
  entry="$(jq -ce --arg id "$runtime" '[.[]|select(.node.id==$id)]|if length==1 then .[0] else empty end' <<<"$live" 2>/dev/null||true)"
    if [[ -n "$entry" ]] && jq -e --arg m "$model" --arg r "$runtime" --argjson a "$args" --argjson assignment "$(jq -c .before.assignment <<<"$plan")" --argjson epoch_models "$(jq -c '.before.dapi_state.epoch_models // null' <<<"$plan")" '.node.id==$r and .node.models[$m].args==$a and .state.lock_count==0 and .state.epoch_ml_nodes==$assignment and (.state.epoch_models//null)==$epoch_models and ((.state.preserved_models//{})|length)==0 and .state.admin_state.enabled==true and .state.current_status=="INFERENCE" and .state.intended_status=="INFERENCE" and .state.deployment_update_pending==false and .state.reconcile_info==null and .state.poc_current_status=="IDLE"' <<<"$entry" >/dev/null 2>&1 \
      && assignment_valid "$entry" "$(jq -r .before.assignment_mode <<<"$plan")"; then
    running="$(engine 2>/dev/null||true)"; epoch="$(docker exec "$apic" curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9000/v1/epochs/latest 2>/dev/null||true)"; pow="$(docker exec "$MLNODE" curl -fsS --connect-timeout 5 --max-time 10 http://127.0.0.1:5001/api/v1/pow/status 2>/dev/null||true)"
    if [[ -n "$running" ]] && jq -e --arg m "$model" --arg s "$served_model" --arg rev "$revision" --argjson r "$(resources "$args")" '.engine.model==$m and .engine.revision==$rev and .served==$s and .engine.resources==$r' <<<"$running" >/dev/null 2>&1 \
      && [[ "$(sha256sum "$CONFIG"|awk '{print $1}')" == "$after_sha" ]] \
      && [[ "$(jq -c .engine.base <<<"$running"|sha256sum|awk '{print $1}')" == "$(jq -r .before.runtime_base_sha256 <<<"$plan")" ]] \
      && [[ "$(jq -r .engine.dtype <<<"$running")" == "$(jq -r .before.runtime_dtype <<<"$plan")" ]] \
      && jq -e --arg s "$served_model" '.models.data|any(.[];.id==$s)' <<<"$running" >/dev/null 2>&1 \
      && jq -e '.phase=="Inference" and .is_confirmation_poc_active==false and ((.epoch_stages.next_poc_start|tonumber)-(.block_height|tonumber)>=360)' <<<"$epoch" >/dev/null 2>&1 \
      && jq -e '.status=="IDLE" and .config==null and .stats==null' <<<"$pow" >/dev/null 2>&1; then
      probe="$(jq -cn --arg m "$served_model" '{model:$m,messages:[{role:"user",content:"Reply exactly GDC_OK"}],max_tokens:16,temperature:0}')"
      answer="$(docker exec "$MLNODE" curl -fsS --connect-timeout 5 --max-time 60 http://127.0.0.1:5000/v1/chat/completions -H 'Content-Type: application/json' --data-binary "$probe" 2>/dev/null||true)"
      if jq -e '.choices[0].message.content|type=="string" and length>0' <<<"$answer" >/dev/null 2>&1; then
        jq -cn --arg key "$key" --arg receipt "$receipt" --arg model "$model" --arg sha "$after_sha" '{outcome:"PASS",plan_sha256:$key,receipt:$receipt,model:$model,node_config_sha256:$sha,rollback:"fresh-plan-required-on-observed-failure"}' >"$receipt/apply-result.json"; chmod 0600 "$receipt/apply-result.json"; cat "$receipt/apply-result.json"; exit 0
      fi
    fi
  fi
  sleep 2
done
jq -cn --arg key "$key" --arg receipt "$receipt" '{outcome:"UNCERTAIN",plan_sha256:$key,receipt:$receipt,reason:"DAPI/controller or runtime verification did not reach the desired stable state; no automatic rollback"}' >"$receipt/uncertain.json"; cat "$receipt/uncertain.json"; exit 4
REMOTE
)" || remote_rc=$?
if [[ "$ACTION" == plan ]]; then
  [[ "$remote_rc" == 0 ]] || die "$NODE resource-retune plan failed"
  jq -e '.schema_version==1 and .kind=="gdc-model-primary-resource-retune"' <<<"$result" >/dev/null || die 'invalid remote plan'
  mkdir -p "$(dirname "$PLAN_PATH")"; (umask 077; set -o noclobber; printf '%s\n' "$result" >"$PLAN_PATH") || die 'could not create private plan'
  printf 'READY model-primary-resource-retune host=%s model=%s plan=%s plan_sha256=%s; no remote files changed\n' "$NODE" "$model_id" "$PLAN_PATH" "$(sha256sum "$PLAN_PATH"|awk '{print $1}')"
elif [[ "$remote_rc" == 0 ]] && jq -e '.outcome=="PASS"' <<<"$result" >/dev/null 2>&1; then
  printf 'PASS model-primary-resource-retune host=%s model=%s receipt=%s\n' "$NODE" "$model_id" "$(jq -r .receipt <<<"$result")"
elif jq -e '.outcome=="UNCERTAIN"' <<<"$result" >/dev/null 2>&1; then
  printf 'UNCERTAIN model-primary-resource-retune host=%s receipt=%s; do not retry or blindly roll back\n' "$NODE" "$(jq -r .receipt <<<"$result")" >&2; exit 4
else die "$NODE resource-retune failed before verified PASS (ssh exit=$remote_rc)"; fi
