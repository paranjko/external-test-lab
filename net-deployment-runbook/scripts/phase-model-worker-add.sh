#!/usr/bin/env bash
# Add one secondary model worker to a joined validator that has the shared
# NVIDIA GPU deployment layout. Plan mode is read-only on the remote Host.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

usage() { echo "Usage: $0 HOST DESCRIPTOR.json [--apply|--reconcile-uncertain]" >&2; }
NODE="${1:-}"; DESCRIPTOR="${2:-}"; ACTION=plan
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -s "$DESCRIPTOR" ]] || { usage; exit 2; }
if (($# > 3)); then usage; exit 2; fi
if (($# == 3)); then
  case "$3" in
    --apply) ACTION=apply ;;
    --reconcile-uncertain) ACTION=reconcile ;;
    *) usage; exit 2 ;;
  esac
fi
topology_contains_node "$NODE" || die "model-worker target is not in GDC_NODE_ALIASES: $NODE"
[[ -f "$DESCRIPTOR" && ! -L "$DESCRIPTOR" ]] || die 'model-worker descriptor must be a regular non-symlink file'
"$ROOT/../devnet/model-layouts/shared-gpu/validate.sh" "$DESCRIPTOR"
startup_request_json="$(jq -ce '
  .secondary as $secondary | $secondary.args as $args
  | [range(0; ($args|length)) as $i | select($args[$i] == "--dtype") | $i] as $dtype_indices
  | if ($dtype_indices|length) != 1 then error("secondary args must contain exactly one --dtype")
    elif ($dtype_indices[0] + 1) >= ($args|length) then error("secondary --dtype value is missing")
    elif (($args[$dtype_indices[0] + 1]|type) != "string"
      or ($args[$dtype_indices[0] + 1]|length) == 0
      or ($args[$dtype_indices[0] + 1]|startswith("--"))) then error("secondary --dtype value is invalid")
    elif ($args|index("--model")) != null then error("secondary args must not duplicate the model field")
    else (reduce range(0; ($args|length)) as $i
        ({out:[],skip:false};
         if .skip then .skip=false
         elif $args[$i] == "--dtype" then .skip=true
         else .out += [$args[$i]] end)) as $built
      | {model:$secondary.model_id,dtype:$args[$dtype_indices[0] + 1],additional_args:$built.out}
    end
' "$DESCRIPTOR")" || die 'secondary descriptor must provide exactly one explicit --dtype and startup-compatible arguments'
[[ -e "$(node_joined_marker "$NODE")" && ! -L "$(node_joined_marker "$NODE")" ]] \
  || die "$NODE has no completed JOIN marker"

identity_file="$(node_identity_file "$NODE")"
account_file="$(node_account_file "$NODE")"
[[ -s "$identity_file" && ! -L "$identity_file" && -s "$account_file" && ! -L "$account_file" ]] \
  || die "$NODE has no safe joined identity and participant account state"
participant="$(jq -er '.address | select(test("^gonka1[0-9a-z]{20,90}$"))' "$account_file")"
node_id="$(jq -er '.node_id | select(test("^[a-f0-9]{40}$"))' "$identity_file")"
legacy_runtime_id="qwen3-0.6b:$participant"
replacement_runtime_id="qwen3-4b:$participant"
runtime_identity_dir="$GDC_DATA_ROOT/state/runtime-identities"
[[ -d "$runtime_identity_dir" && ! -L "$runtime_identity_dir" ]] \
  || die "$NODE has no recorded runtime identity lineage directory"
lineage_count=0
lineage_legacy=false
for runtime_identity in "$runtime_identity_dir"/*.env; do
  [[ -e "$runtime_identity" || -L "$runtime_identity" ]] || continue
  [[ -f "$runtime_identity" && ! -L "$runtime_identity" ]] \
    || die 'runtime identity lineage contains a non-regular or symlink entry'
  lineage_record="$(jq -Rn '
    reduce inputs as $line ({};
      if $line == "" then .
      elif ($line | contains("=")) | not then error("malformed runtime identity field")
      else ($line | index("=")) as $separator
        | ($line[0:$separator]) as $key
        | ($line[$separator + 1:]) as $value
        | if ($key | length) == 0 or has($key) then error("duplicate or empty runtime identity key")
          else . + {($key):$value} end
      end)
  ' "$runtime_identity")" || die 'runtime identity lineage file is malformed'
  if jq -e --arg address "$participant" '.participant_address == $address' <<<"$lineage_record" >/dev/null; then
    [[ "$(jq -r .node <<<"$lineage_record")" == "$NODE" ]] \
      || die 'participant runtime identity lineage is recorded for another GDC Host'
    recorded_runtime_id="$(jq -er '.runtime_id | select(type == "string")' <<<"$lineage_record")"
    expected_identity_path="$(runtime_identity_file "$recorded_runtime_id")"
    [[ "$runtime_identity" == "$expected_identity_path" ]] \
      || die 'runtime identity lineage path does not match its recorded runtime ID'
    case "$recorded_runtime_id" in
      "$legacy_runtime_id") lineage_legacy=true ;;
      "$replacement_runtime_id") : ;; # Verified against the transition receipt below.
      *) die 'participant runtime identity lineage contains an unsupported or foreign runtime ID' ;;
    esac
    lineage_count=$((lineage_count + 1))
  fi
done
(( lineage_count > 0 )) || die "$NODE has no recorded runtime identity lineage for its participant"
chain_id="${CHAIN_ID:?CHAIN_ID is required}"
genesis_file="$GENESIS/genesis.json"
[[ -s "$genesis_file" && ! -L "$genesis_file" ]] || die 'current network Genesis is unavailable locally'
[[ "$(jq -er .chain_id "$genesis_file")" == "$chain_id" ]] || die 'local Genesis does not match the configured chain ID'
genesis_sha="$(sha256sum "$genesis_file" | awk '{print $1}')"
descriptor_sha="$(sha256sum "$DESCRIPTOR" | awk '{print $1}')"
worker_id="$(jq -er --arg participant "$participant" '.secondary.model_id + ":" + $participant + "--secondary"' "$DESCRIPTOR")"
network_name="$(jq -er .host_docker_network "$DESCRIPTOR")"
project="gdc-shared-$(printf '%s' "$participant:$worker_id" | sha256sum | cut -c1-12)"
managed_key="$(printf '%s' "$participant:$worker_id" | sha256sum | cut -c1-24)"
remote_root="/srv/dai/deploy/model-workers/$managed_key"
run_id="${GDC_RUN_ID:-manual}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'GDC run ID is unsafe for model-worker evidence paths'
remote_stage="/tmp/gdc-model-worker-$run_id-$managed_key"

RUN="$GDC_HOME/runs/$run_id/model-worker-add-$NODE-$managed_key"
if [[ "$ACTION" == apply ]]; then
  mkdir -p "$RUN"
  chmod 0700 "$RUN"
fi
scratch="$(mktemp -d)"
startup_request_file="$scratch/startup-request.json"
printf '%s\n' "$startup_request_json" >"$startup_request_file"
stage_created=false
reconcile_stage_created=false
cleanup() {
  local rc=$?
  if [[ "$stage_created" == true ]]; then
    ssh -T "$NODE" "rm -rf -- '$remote_stage'" >/dev/null 2>&1 || true
  fi
  if [[ "$reconcile_stage_created" == true ]]; then
    ssh -T "$NODE" "rm -rf -- '/tmp/gdc-model-worker-reconcile-$run_id-$managed_key'" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
  exit "$rc"
}
trap cleanup EXIT

# Capture the canonical deployment, DAPI bind and exact primary runtime
# metadata in one remote read. Any noncanonical Compose or config location
# fails closed, including the retained legacy Host layout.
remote_state="$scratch/remote-state.json"
primary_args_json="$(jq -c .primary.args "$DESCRIPTOR")"
primary_model="$(jq -r .primary.model_id "$DESCRIPTOR")"
gpu_device="$(jq -r .gpu_device "$DESCRIPTOR")"
router_alias="gdc-shared-$participant-router"
model_alias="gdc-shared-$participant-ml"
router_service="gdc-$participant-router"
model_service="gdc-$participant-ml"
ssh -T "$NODE" "sudo bash -s -- '$network_name'" >"$remote_state" <<'REMOTE'
set -Eeuo pipefail
expected_network="$1"
deploy=/srv/dai/deploy
test -d "$deploy" && test ! -L "$deploy"
test -s "$deploy/compose.yaml" && test ! -L "$deploy/compose.yaml"
test -s "$deploy/node-config.json" && test ! -L "$deploy/node-config.json"
cd "$deploy"
mlnode="$(docker compose --env-file .env -f compose.yaml ps -q mlnode)"
api="$(docker compose --env-file .env -f compose.yaml ps -q api)"
test -n "$mlnode" && test -n "$api"
node_image="$(docker inspect --format '{{.Config.Image}}' "$mlnode")"
api_mounts="$(docker inspect --format '{{json .Mounts}}' "$api")"
networks="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$mlnode")"
api_networks="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$api")"
mounts="$(docker inspect --format '{{json .Mounts}}' "$mlnode")"
devices="$(docker inspect --format '{{json .HostConfig.DeviceRequests}}' "$mlnode")"
ml_env="$(docker inspect --format '{{json .Config.Env}}' "$mlnode")"
primary_models="$(docker exec "$mlnode" curl -fsS --connect-timeout 5 --max-time 10 http://127.0.0.1:5000/v1/models)"
gpu_indices="$(nvidia-smi --query-gpu=index --format=csv,noheader | jq -Rsc 'split("\n") | map(select(length>0))')"
network_name="$expected_network"
jq -e --arg network "$expected_network" 'has($network)' <<<"$networks" >/dev/null
network_containers="$(docker network inspect --format '{{json .Containers}}' "$network_name")"
endpoint_ids="$(docker network inspect --format '{{range $id, $c := .Containers}}{{$id}}{{"\n"}}{{end}}' "$network_name")"
endpoints='[]'
while IFS= read -r endpoint_id; do
  [[ -n "$endpoint_id" ]] || continue
  endpoint_info="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$endpoint_id")"
  endpoint_aliases="$(jq -c --arg network "$network_name" '.[$network].Aliases // []' <<<"$endpoint_info")"
  endpoints="$(jq -cn --argjson current "$endpoints" --arg id "$endpoint_id" --argjson aliases "$endpoint_aliases" '$current + [{id:$id,aliases:$aliases}]')"
done <<<"$endpoint_ids"
# Transition receipts are host-local evidence. Inspect a bounded, canonical
# ledger only; reject symlinks, malformed entries, and digest/path mismatch.
# BEGIN receipt scan test boundary
model_transitions='[]'
ledger=/srv/dai/deploy/.gdc-model-updates
if [[ -e "$ledger" || -L "$ledger" ]]; then
  test -d "$ledger" && test ! -L "$ledger"
  entry_count=0
  while IFS= read -r -d '' entry; do
    entry_count=$((entry_count + 1))
    test "$entry_count" -le 256 || { echo 'model-update receipt ledger exceeds bounded history' >&2; exit 1; }
    test -d "$entry" && test ! -L "$entry"
    key="${entry##*/}"
    result_path="$entry/transition-result.json"
    plan_path="$entry/plan.json"
    if [[ ! -e "$result_path" && ! -L "$result_path" ]]; then continue; fi
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo 'transition receipt has a noncanonical ledger directory' >&2; exit 1; }
    test -f "$result_path" && test ! -L "$result_path"
    test -f "$plan_path" && test ! -L "$plan_path"
    test "$(stat -c %s "$result_path")" -le 1048576
    test "$(stat -c %s "$plan_path")" -le 1048576
    jq -e 'type == "object"' "$plan_path" >/dev/null
    jq -e 'type == "object"' "$result_path" >/dev/null
    jq -e '[.. | numbers | tostring | select(test("[eE]"))] | length == 0' "$plan_path" >/dev/null \
      || { echo 'exponent-form transition number is unsupported by the canonical hash reader' >&2; exit 1; }
    compact_plan="$(jq -S -c . "$plan_path")"
    # Python's producer uses json.dumps(sort_keys=True) with its default
    # separators. Recreate only that whitespace over jq's sorted JSON tokens;
    # non-ASCII input is rejected because the producers' escaping differs.
    if printf '%s' "$compact_plan" | LC_ALL=C grep -q '[^ -~]'; then
      echo 'non-ASCII transition plan cannot be canonically hashed by this reader' >&2
      exit 1
    fi
    canonical_plan=''
    in_string=false
    escaped=false
    while IFS= read -r -n1 character; do
      if [[ "$escaped" == true ]]; then
        canonical_plan+="$character"
        escaped=false
      elif [[ "$in_string" == true ]]; then
        canonical_plan+="$character"
        if [[ "$character" == $'\\' ]]; then escaped=true
        elif [[ "$character" == '"' ]]; then in_string=false
        fi
      elif [[ "$character" == '"' ]]; then
        canonical_plan+="$character"
        in_string=true
      elif [[ "$character" == ',' || "$character" == ':' ]]; then
        canonical_plan+="$character "
      else
        canonical_plan+="$character"
      fi
    done < <(printf '%s' "$compact_plan")
    [[ "$in_string" == false && "$escaped" == false ]]
    actual_key="$(printf '%s' "$canonical_plan" | sha256sum | awk '{print $1}')"
    [[ "$actual_key" == "$key" ]] || { echo 'transition plan digest does not match its receipt path' >&2; exit 1; }
    transition="$(jq -cn --slurpfile plan "$plan_path" --slurpfile result "$result_path" \
      --arg receipt_dir "$entry" '{plan:$plan[0],result:$result[0],receipt_dir:$receipt_dir}')"
    model_transitions="$(jq -cn --argjson current "$model_transitions" --argjson next "$transition" '$current + [$next]')"
  done < <(find "$ledger" -mindepth 1 -maxdepth 1 -print0)
fi
# END receipt scan test boundary
jq -n --arg image "$node_image" --argjson api_mounts "$api_mounts" \
  --argjson networks "$networks" --argjson api_networks "$api_networks" \
  --argjson mounts "$mounts" --argjson devices "$devices" --argjson ml_env "$ml_env" \
  --argjson gpu_indices "$gpu_indices" --argjson primary_models "$primary_models" \
  --arg network_name "$network_name" --argjson network_containers "$network_containers" --argjson endpoints "$endpoints" \
  --argjson model_transitions "$model_transitions" \
  --slurpfile config "$deploy/node-config.json" \
  '{mlnode:{Config:{Image:$image,Env:$ml_env}},api:{Mounts:$api_mounts},networks:$networks,api_networks:$api_networks,mounts:$mounts,devices:$devices,gpu_indices:$gpu_indices,primary_models:$primary_models,network:{Name:$network_name,Containers:$network_containers},endpoints:$endpoints,node_config:$config[0],model_transitions:$model_transitions}'
REMOTE

# JOIN records the participant/Host lineage, but a supported --replace-id
# transition can change the runtime-ID prefix without changing that lineage.
# Bind the live primary ID from the unique configured primary model and its
# exact reviewed arguments, then require the same ID in DAPI below.
primary_config_records="$(jq -c --arg model "$primary_model" --argjson args "$primary_args_json" '
  [.node_config[] | select(.host == "inference" and (.models | type == "object")
    and .models[$model].args == $args)]
' "$remote_state")"
[[ "$(jq 'length' <<<"$primary_config_records")" == 1 ]] \
  || die "$NODE primary model/args do not resolve to exactly one configured runtime identity"
runtime_id="$(jq -er '.[0].id | select(type == "string")' <<<"$primary_config_records")"
case "$runtime_id" in
  "$legacy_runtime_id")
    [[ "$lineage_legacy" == true ]] || die 'legacy primary runtime ID has no matching recorded participant lineage' ;;
  "$replacement_runtime_id")
    transition_matches="$(jq -c --arg host "$NODE" --arg legacy "$legacy_runtime_id" \
      --arg replacement "$replacement_runtime_id" --arg chain "$chain_id" \
      --arg model "$primary_model" --argjson args "$primary_args_json" '
      [.model_transitions[]?
       | select(.plan.schema_version == 1 and .plan.kind == "gdc-host-models"
         and .plan.host == $host and .plan.node_id == $legacy
         and .plan.replace_id == $replacement
         and .plan.identity.chain_id == $chain
         and .plan.identity.config_path == "/srv/dai/deploy/node-config.json"
         and .plan.models == {($model):{args:$args}}
         and .plan.before.id == $legacy and .plan.before.host == "inference"
         and .plan.before.models[$model].args == $args
         and .result.status == "transitioned"
         and .result.retired_worker == $legacy and .result.worker == $replacement
         and .result.models == [$model] and .result.serving_verified == false
         and .result.identity == .plan.identity
         and .result.receipt == .receipt_dir)]
    ' "$remote_state")"
    [[ "$(jq 'length' <<<"$transition_matches")" == 1 ]] \
      || die 'replacement primary runtime ID has no unique matching successful replace-id receipt' ;;
  *) die "$NODE configured primary runtime ID is unsupported or belongs to another participant" ;;
esac

receipt="$RUN/receipt.json"
api_worker_matches() {
  local nodes_file="$1" expected_file="$2"
  jq -e --slurpfile expected "$expected_file" '
    def intended_node:
      . as $node
      | if ((($node | has("inference_segment") | not) or $node.inference_segment == "")
          and (($node | has("poc_segment") | not) or $node.poc_segment == "")
          and (($node | has("hardware") | not) or $node.hardware == null or ($node.hardware | type == "array"))
          and (($node | has("node_num") | not) or ($node.node_num | type == "number" and floor == . and . >= 0))
          and (($node | has("registration_seq") | not) or ($node.registration_seq | type == "number" and floor == . and . >= 0)))
        then $node | del(.inference_segment,.poc_segment,.hardware,.node_num,.registration_seq)
        else null end;
    [.[] | select(.node.id == $expected[0].id and .node.host == $expected[0].host)] as $matches
    | ($matches | length) == 1
      and ($matches[0].node | intended_node) == $expected[0]
  ' "$nodes_file" >/dev/null 2>&1
}
existing="$(ssh -T "$NODE" "sudo cat '$remote_root/receipt.json' 2>/dev/null" || true)"
has_existing=false
uncertain=''
if [[ "$ACTION" == reconcile ]]; then
  [[ -z "$existing" ]] || die 'a PASS receipt already exists; use normal apply verification instead of uncertain reconciliation'
  uncertain="$(ssh -T "$NODE" "sudo cat '$remote_root/uncertain.json' 2>/dev/null" || true)"
  jq -e --arg worker "$worker_id" --arg descriptor "$descriptor_sha" \
    '.schema_version == 1 and .kind == "gdc-model-worker" and .outcome == "UNCERTAIN" and
     .phase == "dapi-readback" and .worker_id == $worker and
     (.descriptor_sha256 == null or .descriptor_sha256 == $descriptor)' \
    <<<"$uncertain" >/dev/null || die 'no matching dapi-readback uncertainty is available to reconcile'
  has_existing=true
fi
if [[ -n "$existing" ]]; then
  jq -e --arg hash "$descriptor_sha" --arg participant "$participant" --arg worker "$worker_id" \
    --arg chain "$chain_id" --arg genesis "$genesis_sha" --arg project "$project" --arg endpoint "$router_alias" \
    '.schema_version == 1 and .kind == "gdc-model-worker" and .outcome == "PASS" and
     .descriptor_sha256 == $hash and .participant == $participant and .worker_id == $worker and
     .chain_id == $chain and .genesis_sha256 == $genesis and .compose_project == $project and .endpoint == $endpoint' \
    <<<"$existing" >/dev/null || die 'a different or invalid managed worker receipt already occupies this target'
  has_existing=true
fi

jq -e --arg expected_network "$network_name" --arg image "$(jq -r .primary.image "$DESCRIPTOR")" \
  --arg primary_model "$(jq -r .primary.model_id "$DESCRIPTOR")" \
  --arg runtime_id "$runtime_id" --arg node_id "$node_id" --arg gpu "$gpu_device" \
  --arg router_alias "$router_alias" --arg model_alias "$model_alias" \
  --arg router_service "$router_service" --arg model_service "$model_service" \
  --arg existing "$has_existing" --argjson primary_args "$primary_args_json" '
  (.api.Mounts | map(select(.Destination == "/root/node_config.json" and .Type == "bind")) | length) == 1
  and ([.api.Mounts[] | select(.Destination == "/root/node_config.json" and .Type == "bind") | .Source] == ["/srv/dai/deploy/node-config.json"])
  and (.node_config | type == "array" and length > 0)
  and ([.node_config[] | select(.id == $runtime_id and .host == "inference")] | length) == 1
  and ([.node_config[] | select(.id == $runtime_id and .host == "inference") | .models | keys] == [[$primary_model]])
  and ([.node_config[] | select(.id == $runtime_id and .host == "inference") | .models[$primary_model].args] == [$primary_args])
  and (.mlnode.Config.Image == $image)
  and ((.networks | keys) == [$expected_network])
  and ((.api_networks | keys) == [$expected_network])
  and ((.mounts | map(select(.Destination == "/root/.cache" and .Type == "bind")) | length) == 1)
  and (
    ((.devices | map(.DeviceIDs // []) | add // []) | index($gpu) != null)
    or
    ((.devices | length) == 1 and .devices[0].Count == -1
      and ((.devices[0].DeviceIDs // []) | length) == 0
      and any(.devices[0].Capabilities[]; . == ["gpu"])
      and (.mlnode.Config.Env | index("NVIDIA_VISIBLE_DEVICES=all") != null)
      and .gpu_indices == [$gpu])
  )
  and ($existing == "true" or ([.endpoints[].aliases[]?] | index($router_alias) == null and
    index($model_alias) == null and index($router_service) == null and index($model_service) == null))
' "$remote_state" >/dev/null \
  || die "$NODE is not the expected joined validator/runtime or the descriptor does not match its primary model, image, cache, GPU and Docker network"
jq -e --arg cache "$(jq -r .hf_cache_root "$DESCRIPTOR")" \
  'any(.mounts[]; .Destination == "/root/.cache" and .Type == "bind" and .Source == $cache)' "$remote_state" >/dev/null \
  || die 'descriptor HF cache root does not match the target primary worker'
jq -e --arg network "$network_name" '
  . as $state
  | any(.network.Containers[]?; .Name as $name | .EndpointID != "" and .IPv4Address != "")
  and ($state.network.Name == $network)
' "$remote_state" >/dev/null || die 'target Docker network is missing or malformed'

remote_chain_id="$(ssh -T "$NODE" 'sudo jq -er .chain_id /srv/dai/shared/genesis.json')"
[[ "$remote_chain_id" == "$chain_id" ]] || die "$NODE deployed Genesis has the wrong chain ID"
remote_genesis_sha="$(ssh -T "$NODE" 'sudo sha256sum /srv/dai/shared/genesis.json' | awk '{print $1}')"
[[ "$remote_genesis_sha" == "$genesis_sha" ]] || die "$NODE deployed Genesis lineage differs from the current local network"
node_status="$(ssh -T "$NODE" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status')"
jq -e --arg chain "$chain_id" --arg node_id "$node_id" \
  '.result.node_info.network == $chain and (.result.node_info.id | ascii_downcase) == $node_id' \
  <<<"$node_status" >/dev/null || die "$NODE live Core identity does not match its joined account and chain lineage"

api_nodes="$scratch/dapi-nodes.json"
ssh -T "$NODE" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes' >"$api_nodes"
jq -e --arg runtime "$runtime_id" 'type == "array" and any(.[]; .node.id == $runtime and .node.host == "inference")' "$api_nodes" >/dev/null \
  || die "$NODE DAPI does not have the expected primary validator model registered"
candidate="$scratch/candidate"
mkdir -p "$scratch"
"$ROOT/../devnet/model-layouts/shared-gpu/render.sh" "$participant" "$DESCRIPTOR" "$candidate" >/dev/null
worker_file="$candidate/secondary-worker.json"
next_config="$scratch/node-config.next.json"
before_config="$scratch/node-config.before.json"
after_id_collision=0
api_primary="$(jq -c --arg id "$runtime_id" '[.[] | select(.node.id == $id) | .node]' "$api_nodes")"
[[ "$(jq 'length' <<<"$api_primary")" == 1 ]] || die 'DAPI primary registration is missing or duplicated'
api_primary_entry="$scratch/api-primary-before.json"
jq -ce --arg id "$runtime_id" '[.[] | select(.node.id == $id and .node.host == "inference")] | if length == 1 then .[0] else error("primary DAPI entry is missing/duplicated") end' "$api_nodes" >"$api_primary_entry" \
  || die 'DAPI primary registration is missing or duplicated'
api_primary_args="$(jq -c --arg model "$primary_model" '.[0].models[$model].args' <<<"$api_primary")"
[[ "$api_primary_args" == "$primary_args_json" ]] || die 'DAPI primary model arguments differ from the reviewed descriptor'

# The renderer's router alias is a Docker-network service identity, not a
# host-published endpoint. Keep the complete prior DAPI document intact and
# append one immutable worker registration.
ssh -T "$NODE" 'sudo cat /srv/dai/deploy/node-config.json' >"$before_config"
secondary_id="$(jq -r .id "$worker_file")"
secondary_host="$(jq -r .host "$worker_file")"
jq -e --arg id "$secondary_id" --arg host "$secondary_host" --arg existing "$has_existing" '
  ($existing == "true" and any(.[]; .id == $id and .host == $host)) or
  ($existing != "true" and all(.[]; .id != $id and .host != $host))
' "$before_config" >/dev/null || after_id_collision=1
[[ "$after_id_collision" == 0 ]] || die 'DAPI worker ID or network alias is already occupied'
jq -e --arg id "$secondary_id" --arg host "$secondary_host" \
  --arg existing "$has_existing" \
  '($existing == "true" and any(.[]; .node.id == $id and .node.host == $host)) or
   ($existing != "true" and all(.[]; .node.id != $id and .node.host != $host))' "$api_nodes" >/dev/null \
  || die 'DAPI already has a registration using the secondary worker ID or router alias'
jq --slurpfile worker "$worker_file" '. + [$worker[0]]' "$before_config" >"$next_config"

if [[ "$ACTION" == reconcile ]]; then
  current_sha="$(sha256sum "$before_config" | awk '{print $1}')"
  uncertain_next="$(jq -r .node_config_next_sha256 <<<"$uncertain")"
  expected_inode="$(jq -r .node_config_inode <<<"$uncertain")"
  uncertain_current="$(jq -r .node_config_current_sha256 <<<"$uncertain")"
  ssh -T "$NODE" "sudo cat '$remote_root/node-config.before.json'" >"$scratch/reconcile-node-config.before.json" \
    || die 'preserved before-config is unavailable'
  ssh -T "$NODE" "sudo cat '$remote_root/node-config.next.json'" >"$scratch/reconcile-node-config.next.json" \
    || die 'preserved next-config is unavailable'
  remote_before_sha="$(sha256sum "$scratch/reconcile-node-config.before.json" | awk '{print $1}')"
  remote_next_sha="$(sha256sum "$scratch/reconcile-node-config.next.json" | awk '{print $1}')"
  uncertain_before="$(jq -r .node_config_before_sha256 <<<"$uncertain")"
  [[ "$remote_before_sha" == "$uncertain_before" && "$remote_next_sha" == "$uncertain_next" ]] \
    || die 'preserved before/next DAPI config artifacts do not match the uncertainty receipt'
  [[ "$current_sha" == "$uncertain_next" && "$current_sha" == "$uncertain_current" ]] \
    || die 'current DAPI config does not match the preserved uncertain next-config hash'
  cmp -s "$before_config" "$scratch/reconcile-node-config.next.json" \
    || die 'current DAPI config differs from the preserved next-config bytes'
  remote_inode="$(ssh -T "$NODE" 'sudo stat -c %i /srv/dai/deploy/node-config.json')"
  [[ "$remote_inode" == "$expected_inode" ]] || die 'DAPI config inode differs from the preserved uncertain state'
  jq -e --slurpfile worker "$worker_file" --slurpfile before "$scratch/reconcile-node-config.before.json" \
    '. == ($before[0] + [$worker[0]])' "$scratch/reconcile-node-config.next.json" >/dev/null \
    || die 'preserved next-config is not the exact before-config plus reviewed worker'
  jq -e --slurpfile expected "$worker_file" \
    '([.[] | select(.id == $expected[0].id)] | length) == 1 and
     ([.[] | select(.id == $expected[0].id)][0] == $expected[0])' "$before_config" >/dev/null \
    || die 'current DAPI config does not contain exactly the reviewed secondary worker'
  remote_worker="$(ssh -T "$NODE" "sudo cat '$remote_root/secondary-worker.json'")"
  [[ "$remote_worker" == "$(<"$worker_file")" ]] || die 'retained worker descriptor differs from the reviewed candidate'
  api_worker_matches "$api_nodes" "$worker_file" \
    || die 'current DAPI registration does not exactly match the reviewed worker'
  jq -e --arg model "$primary_model" --arg runtime "$runtime_id" --argjson args "$primary_args_json" '
    [.[] | select(.node.id == $runtime and .node.host == "inference")] as $matches
    | ($matches | length) == 1
      and ($matches[0].node.models | keys) == [$model]
      and $matches[0].node.models[$model].args == $args
      and $matches[0].state.lock_count == 0
      and (($matches[0].state.preserved_models // {}) | length) == 0
      and $matches[0].state.admin_state.enabled == true
      and $matches[0].state.current_status == "INFERENCE"
      and $matches[0].state.intended_status == "INFERENCE"
      and ($matches[0].state.deployment_update_pending // false) == false
      and $matches[0].state.reconcile_info == null
      and $matches[0].state.poc_current_status == "IDLE"
      and ($matches[0].state.epoch_models | type) == "object"
      and ($matches[0].state.epoch_models | has($model))
      and (($matches[0].state.epoch_ml_nodes | type) == "object")
      and (if (($matches[0].state.epoch_ml_nodes | keys) == [$model])
           then $matches[0].state.epoch_ml_nodes[$model].node_id == $runtime
           else $matches[0].state.epoch_ml_nodes == {} end)
  ' "$api_nodes" >/dev/null \
    || die 'current primary DAPI state is neither the exact assignment nor ready-unassigned for the reviewed single model'
  jq -e --arg model "$primary_model" '.primary_models.data | type == "array" and length == 1 and .[0].id == $model' "$remote_state" >/dev/null \
    || die 'primary ML engine is not serving exactly the reviewed model'
  current_primary="$(jq -c --arg runtime "$runtime_id" '[.[] | select(.node.id == $runtime and .node.host == "inference")][0]' "$api_nodes")"
  historical_primary=false
  primary_before_remote="$(ssh -T "$NODE" "sudo cat '$remote_root/primary-before.json' 2>/dev/null || true")"
  if [[ -n "$primary_before_remote" ]]; then
    jq -e --argjson current "$current_primary" \
      '(.state.epoch_ml_nodes == $current.state.epoch_ml_nodes) and
       (.node | del(.node_num,.registration_seq)) == ($current.node | del(.node_num,.registration_seq))' \
      <<<"$primary_before_remote" >/dev/null || die 'primary DAPI registration/assignment differs from the preserved pre-apply snapshot'
    historical_primary=true
  fi
  health="$(ssh -T "$NODE" "sudo bash -s -- '$remote_root' '$project' '$secondary_id' '$secondary_host' '$model_service' '$router_service'" <<'REMOTE'
set -Eeuo pipefail
target="$1"; project="$2"; worker_id="$3"; endpoint="$4"; model_service="$5"; router_service="$6"
compose="$target/secondary-compose.json"
test -s "$compose" && test -s "$target/nginx.conf" && test -s "$target/secondary-worker.json"
mlnode="$(docker compose --project-name "$project" --env-file /srv/dai/deploy/.env -f "$compose" ps -q "$model_service")"
router="$(docker compose --project-name "$project" --env-file /srv/dai/deploy/.env -f "$compose" ps -q "$router_service")"
test -n "$mlnode" && test -n "$router"
router_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$router")"
test -n "$router_ip"
curl -fsS --connect-timeout 5 --max-time 15 "http://$router_ip:8080/health" >/dev/null
models="$(curl -fsS --connect-timeout 5 --max-time 15 "http://$router_ip:5000/v1/models")"
jq -e --arg model "$(jq -r '.models|keys[0]' "$target/secondary-worker.json")" '.data | any(.[]; .id == $model)' <<<"$models" >/dev/null
printf 'HEALTHY\n'
REMOTE
  )" || die 'uncertain worker runtime is not currently healthy; no reconciliation receipt written'
  [[ "$health" == HEALTHY ]] || die 'uncertain worker health check returned an unexpected result'
  [[ "$(sha256sum "$before_config" | awk '{print $1}')" == "$current_sha" \
    && "$(ssh -T "$NODE" 'sudo stat -c %i /srv/dai/deploy/node-config.json')" == "$remote_inode" ]] \
    || die 'DAPI config changed during read-only reconciliation'
  reconciliation_json="$(jq -cn --arg worker "$worker_id" --arg descriptor "$descriptor_sha" \
    --arg config_sha "$current_sha" --argjson historical_primary "$historical_primary" \
    --argjson uncertainty_descriptor_bound "$(jq 'has("descriptor_sha256")' <<<"$uncertain")" \
    '{schema_version:1,kind:"gdc-model-worker-reconciliation",outcome:"PASS",worker_id:$worker,descriptor_sha256:$descriptor,node_config_sha256:$config_sha,source_uncertainty_descriptor_bound:$uncertainty_descriptor_bound,primary_preapply_snapshot_compared:$historical_primary,scope:"current-state-only",verified_at:(now|todateiso8601)}')"
  receipt_json="$(jq -cn --arg participant "$participant" --arg runtime_id "$runtime_id" --arg chain_id "$chain_id" \
    --arg genesis_sha "$genesis_sha" --arg worker "$worker_id" --arg endpoint "$router_alias" \
    --arg descriptor_sha "$descriptor_sha" --arg config_sha "$current_sha" --arg network "$network_name" --arg project "$project" \
    '{schema_version:1,kind:"gdc-model-worker",outcome:"PASS",participant:$participant,runtime_id:$runtime_id,chain_id:$chain_id,genesis_sha256:$genesis_sha,worker_id:$worker,endpoint:$endpoint,descriptor_sha256:$descriptor_sha,node_config_before_sha256:null,node_config_after_sha256:$config_sha,docker_network:$network,compose_project:$project,reconciled_current_state:true,registered_at:(now|todateiso8601)}')"
  reconcile_stage="/tmp/gdc-model-worker-reconcile-$run_id-$managed_key"
  printf '%s\n' "$reconciliation_json" >"$scratch/reconciliation.json"
  printf '%s\n' "$receipt_json" >"$scratch/reconciliation-receipt.json"
  ssh -T "$NODE" "install -d -m 0700 '$reconcile_stage'"
  reconcile_stage_created=true
  scp -q "$scratch/reconciliation.json" "$scratch/reconciliation-receipt.json" "$NODE:$reconcile_stage/"
  ssh -T "$NODE" "sudo bash -s -- '$remote_root' '$reconcile_stage'" <<'REMOTE'
set -Eeuo pipefail
target="$1"; stage="$2"
reconciliation="$stage/reconciliation.json"
receipt="$stage/reconciliation-receipt.json"
test ! -e "$target/receipt.json" && test ! -e "$target/reconciliation.json"
install -m 0600 "$reconciliation" "$target/reconciliation.json.tmp"
mv "$target/reconciliation.json.tmp" "$target/reconciliation.json"
install -m 0600 "$receipt" "$target/receipt.json.tmp"
mv "$target/receipt.json.tmp" "$target/receipt.json"
REMOTE
  ssh -T "$NODE" "rm -rf -- '$reconcile_stage'"
  reconcile_stage_created=false
  ssh -T "$NODE" "sudo cat '$remote_root/reconciliation.json'" >"$RUN/reconciliation.json"
  ssh -T "$NODE" "sudo cat '$remote_root/receipt.json'" >"$receipt"
  printf 'PASS model-worker current-state reconciliation host=%s worker=%s historical_primary_snapshot=%s\\n' "$NODE" "$worker_id" "$historical_primary"
  exit 0
fi

if [[ "$has_existing" == true && "$ACTION" == apply ]]; then
  actual_config_sha="$(sha256sum "$before_config" | awk '{print $1}')"
  jq -e --arg hash "$actual_config_sha" '.node_config_after_sha256 == $hash' <<<"$existing" >/dev/null \
    || die 'managed worker receipt does not bind the current DAPI config'
  jq -e --slurpfile worker "$worker_file" \
    '([.[] | select(.id == $worker[0].id)] | length) == 1 and
     ([.[] | select(.id == $worker[0].id)][0] == $worker[0])' "$before_config" >/dev/null \
    || die 'managed worker DAPI config differs from the reviewed candidate'
  api_worker_matches "$api_nodes" "$worker_file" \
    || die 'managed worker DAPI registration differs from the reviewed candidate'
  health="$(ssh -T "$NODE" "sudo bash -s -- '$remote_root' '$project' '$secondary_id' '$secondary_host' '$model_service' '$router_service'" <<'REMOTE'
set -Eeuo pipefail
target="$1"; project="$2"; worker_id="$3"; endpoint="$4"; model_service="$5"; router_service="$6"
compose="$target/secondary-compose.json"
mlnode="$(docker compose --project-name "$project" --env-file /srv/dai/deploy/.env -f "$compose" ps -q "$model_service")"
router="$(docker compose --project-name "$project" --env-file /srv/dai/deploy/.env -f "$compose" ps -q "$router_service")"
test -n "$mlnode" && test -n "$router"
router_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$router")"
test -n "$router_ip"
curl -fsS --connect-timeout 5 --max-time 15 "http://$router_ip:8080/health" >/dev/null
models="$(curl -fsS --connect-timeout 5 --max-time 15 "http://$router_ip:5000/v1/models")"
jq -e --arg model "$(jq -r '.models|keys[0]' "$target/secondary-worker.json")" '.data | any(.[]; .id == $model)' <<<"$models" >/dev/null
nodes="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes)"
jq -e --arg id "$worker_id" --arg host "$endpoint" 'any(.[]; .node.id == $id and .node.host == $host)' <<<"$nodes" >/dev/null
printf 'HEALTHY\n'
REMOTE
  )" || die 'managed worker receipt exists but service health or DAPI registration is not current'
  [[ "$health" == HEALTHY ]] || die 'managed worker health check returned an unexpected result'
  printf '%s\n' "$existing" >"$receipt"
  chmod 0600 "$receipt"
  printf 'NO_CHANGE model-worker already applied host=%s worker=%s\n' "$NODE" "$worker_id"
  exit 0
fi

if [[ "$ACTION" == plan ]]; then
  printf 'READY model-worker plan host=%s participant=%s primary=%s secondary=%s descriptor_sha256=%s; no remote files changed\n' \
    "$NODE" "$participant" "$(jq -r .primary.model_id "$DESCRIPTOR")" "$(jq -r .secondary.model_id "$DESCRIPTOR")" "$descriptor_sha"
  exit 0
fi

if [[ -n "$existing" ]]; then
  jq -e --arg hash "$descriptor_sha" --arg participant "$participant" --arg worker "$worker_id" \
    '.schema_version == 1 and .kind == "gdc-model-worker" and .descriptor_sha256 == $hash and .participant == $participant and .worker_id == $worker and .outcome == "PASS"' \
    <<<"$existing" >/dev/null || die 'a different or invalid managed worker receipt already occupies this target'
  printf '%s\n' "$existing" >"$receipt"
  printf 'NO_CHANGE model-worker already applied host=%s worker=%s\n' "$NODE" "$worker_id"
  exit 0
fi

expected_config_sha="$(sha256sum "$before_config" | awk '{print $1}')"
mkdir -p "$candidate/transfer"
cp "$candidate/secondary-compose.json" "$candidate/nginx.conf" "$worker_file" "$before_config" "$next_config" \
  "$api_primary_entry" "$startup_request_file" "$ROOT/02-node/sync-node-config.sh" "$candidate/transfer/"
stage_created=true
ssh -T "$NODE" "install -d -m 0700 '$remote_stage'"
scp -q "$candidate/transfer/secondary-compose.json" "$candidate/transfer/nginx.conf" \
  "$candidate/transfer/secondary-worker.json" "$candidate/transfer/node-config.before.json" \
  "$candidate/transfer/node-config.next.json" "$candidate/transfer/api-primary-before.json" \
  "$candidate/transfer/startup-request.json" "$candidate/transfer/sync-node-config.sh" "$NODE:$remote_stage/"

apply_rc=0
ssh -T "$NODE" "sudo bash -s -- '$remote_stage' '$remote_root' '$project' '$network_name' '$expected_config_sha' '$worker_id' '$secondary_host' '$descriptor_sha' '$participant' '$runtime_id' '$chain_id' '$genesis_sha' '$model_service' '$router_service'" <<'REMOTE' || apply_rc=$?
set -Eeuo pipefail
stage="$1"; target="$2"; project="$3"; network="$4"; expected_config_sha="$5"; worker_id="$6"; endpoint="$7"; descriptor_sha="$8"; participant="$9"; runtime_id="${10}"; chain_id="${11}"; genesis_sha="${12}"; model_service="${13}"; router_service="${14}"
deploy=/srv/dai/deploy
compose="$target/secondary-compose.json"
config="$deploy/node-config.json"
installed=false; started=false; config_changed=false; uncertain=false; rollback_safe=false
startup_requested=false
worker_file="$stage/secondary-worker.json"
primary_before_file="$stage/api-primary-before.json"
before_sha="$expected_config_sha"
next_sha="$(sha256sum "$stage/node-config.next.json" | awk '{print $1}')"
config_inode=''
write_uncertain() {
  local phase="$1" reason="$2"
  uncertain=true
  mkdir -p "$target"
  cp -f "$stage/node-config.before.json" "$target/node-config.before.json" 2>/dev/null || true
  cp -f "$stage/node-config.next.json" "$target/node-config.next.json" 2>/dev/null || true
  jq -cn --arg worker "$worker_id" --arg phase "$phase" --arg reason "$reason" \
    --arg before "$before_sha" --arg next "$next_sha" \
    --arg current "$(sha256sum "$config" 2>/dev/null | awk '{print $1}' || true)" \
    --arg inode "$(stat -c %i "$config" 2>/dev/null || true)" \
    --arg descriptor "$descriptor_sha" \
    '{schema_version:1,kind:"gdc-model-worker",outcome:"UNCERTAIN",worker_id:$worker,descriptor_sha256:$descriptor,phase:$phase,reason:$reason,node_config_before_sha256:$before,node_config_next_sha256:$next,node_config_current_sha256:$current,node_config_inode:$inode,recorded_at:(now|todateiso8601)}' \
    >"$target/uncertain.json"
  chmod 0600 "$target/uncertain.json" 2>/dev/null || true
  cp "$stage/api-primary-before.json" "$target/primary-before.json" 2>/dev/null || true
  if [[ "$phase" == dapi-readback ]]; then
    cp "$stage/dapi-readback.last.json" "$target/dapi-readback.last.json" 2>/dev/null || true
    jq --argjson attempts "${dapi_readback_attempts:-0}" '. + {dapi_readback_attempts:$attempts}' \
      "$target/uncertain.json" >"$target/uncertain.json.tmp" && mv "$target/uncertain.json.tmp" "$target/uncertain.json"
  fi
}
rollback() {
  rc=$?
  if (( rc != 0 )) && [[ "$config_changed" == true && "$uncertain" != true ]]; then
    live="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes 2>/dev/null || true)"
    if [[ "$(sha256sum "$config" 2>/dev/null | awk '{print $1}')" == "$next_sha" \
       && "$(stat -c %i "$config" 2>/dev/null || true)" == "$config_inode" ]]; then
      if jq -e --arg id "$worker_id" --arg host "$endpoint" \
        'type == "array" and all(.[]; .node.id != $id and .node.host != $host)' <<<"$live" >/dev/null 2>&1; then
        rollback_safe=true
        if ! cat "$stage/node-config.before.json" >"$config" || ! sync -f "$config" \
          || [[ "$(sha256sum "$config" | awk '{print $1}')" != "$before_sha" || "$(stat -c %i "$config")" != "$config_inode" ]] \
          || ! cp "$stage/node-config.before.json" "$stage/node-config.json" \
          || ! bash "$stage/sync-node-config.sh"; then
          rollback_safe=false
        else
          live="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes 2>/dev/null || true)"
          jq -e --arg id "$worker_id" --arg host "$endpoint" \
            'type == "array" and all(.[]; .node.id != $id and .node.host != $host)' <<<"$live" >/dev/null 2>&1 || rollback_safe=false
        fi
      fi
    fi
    if [[ "$rollback_safe" != true ]]; then
      write_uncertain rollback 'DAPI/config state could not be proven safe to restore; worker retained for reconciliation'
    fi
  fi
  if (( rc != 0 )) && [[ "$uncertain" != true ]]; then
    if [[ "$started" == true ]]; then docker compose --project-name "$project" -f "$compose" down --remove-orphans || { write_uncertain teardown 'worker teardown failed; retained for reconciliation'; }; fi
    if [[ "$installed" == true && "$uncertain" != true ]]; then rm -f "$compose" "$target/nginx.conf" "$target/secondary-worker.json" "$target/receipt.json"; rmdir "$target" 2>/dev/null || true; fi
  fi
  rm -rf -- "$stage"
  exit "$rc"
}
trap rollback EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
test -d "$deploy" && test ! -L "$deploy"
exec 9>"$deploy/.gdc-models.lock"
flock -n 9 || { echo 'another host-model operation holds the deployment lock' >&2; exit 1; }
test "$(sha256sum "$config" | awk '{print $1}')" = "$expected_config_sha" || { echo 'DAPI config changed since plan' >&2; exit 1; }
config_inode="$(stat -c %i "$config")"
test ! -e "$target" && test ! -L "$target" || { echo 'managed worker target path is already occupied' >&2; exit 1; }
install -m 0750 -d "$target"
installed=true
install -m 0640 "$stage/secondary-compose.json" "$compose"
install -m 0640 "$stage/nginx.conf" "$target/nginx.conf"
install -m 0640 "$stage/secondary-worker.json" "$target/secondary-worker.json"
docker compose --project-name "$project" --env-file "$deploy/.env" -f "$compose" config --quiet
started=true
docker compose --project-name "$project" --env-file "$deploy/.env" -f "$compose" up -d
deadline=$((SECONDS + 900))
router=''
healthy=false
while (( SECONDS < deadline )); do
  model_worker="$(docker compose --project-name "$project" --env-file "$deploy/.env" -f "$compose" ps -q "$model_service")"
  router="$(docker compose --project-name "$project" --env-file "$deploy/.env" -f "$compose" ps -q "$router_service")"
  if [[ -n "$model_worker" && -n "$router" ]]; then
    router_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$router")"
    if [[ -n "$router_ip" ]] && curl -fsS --connect-timeout 5 --max-time 15 "http://$router_ip:8080/health" >/dev/null 2>&1; then
      if status="$(curl -fsS --connect-timeout 5 --max-time 15 "http://$router_ip:8080/api/v1/inference/up/status" 2>/dev/null)"; then
        if jq -e '(.error != null and .error != "")' <<<"$status" >/dev/null 2>&1; then
          echo 'secondary ML manager reported an inference startup error' >&2
          exit 1
        fi
        if jq -e '.status == "not_started" and (.is_running != true)' <<<"$status" >/dev/null 2>&1; then
          if [[ "$startup_requested" != true ]]; then
            startup_requested=true
            if ! curl -fsS --connect-timeout 5 --max-time 30 -X POST \
              "http://$router_ip:8080/api/v1/inference/up/async" -H 'Content-Type: application/json' \
              --data-binary @- <"$stage/startup-request.json" >/dev/null; then
              echo 'secondary ML manager rejected the reviewed inference startup request' >&2
              exit 1
            fi
          fi
        elif jq -e '.is_running == true and (.error == null or .error == "")' <<<"$status" >/dev/null 2>&1; then
          models="$(curl -fsS --connect-timeout 5 --max-time 15 "http://$router_ip:5000/v1/models" 2>/dev/null || true)"
          if jq -e --arg model "$(jq -r '.models|keys[0]' "$stage/secondary-worker.json")" \
            '.data | type == "array" and any(.[]; .id == $model)' <<<"$models" >/dev/null 2>&1; then
            healthy=true
            break
          fi
          echo 'secondary ML manager is running a different model than the reviewed candidate' >&2
          exit 1
        elif jq -e '.is_starting == true or .status == "in_progress" or .status == "starting"' \
          <<<"$status" >/dev/null 2>&1; then
          :
        else
          echo 'secondary ML manager returned an unknown inference startup state' >&2
          exit 1
        fi
      fi
    fi
  fi
  sleep 3
done
[[ "$healthy" == true ]] || { echo 'secondary worker did not become healthy' >&2; exit 1; }
prewrite_nodes="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes 2>/dev/null || true)"
if ! jq -e --arg runtime "$runtime_id" --slurpfile primary "$primary_before_file" '
  [.[] | select(.node.id == $runtime and .node.host == "inference")] as $matches
  | ($matches | length) == 1
    and (($matches[0].state.epoch_ml_nodes // {}) == ($primary[0].state.epoch_ml_nodes // {}))
    and (($matches[0].node | del(.node_num,.registration_seq)) == ($primary[0].node | del(.node_num,.registration_seq)))
' <<<"$prewrite_nodes" >/dev/null 2>&1; then
  echo 'primary DAPI registration or assignment changed during worker startup' >&2
  exit 1
fi
if [[ "$(sha256sum "$config" | awk '{print $1}')" != "$expected_config_sha" \
   || "$(stat -c %i "$config")" != "$config_inode" ]]; then
  echo 'DAPI config changed during worker startup; preserving concurrent update' >&2
  exit 1
fi
config_changed=true
if ! cat "$stage/node-config.next.json" >"$config" || ! sync -f "$config" \
  || [[ "$(sha256sum "$config" | awk '{print $1}')" != "$next_sha" || "$(stat -c %i "$config")" != "$config_inode" ]]; then
  write_uncertain config-write 'in-place DAPI config update or inode verification failed'
  exit 4
fi
install -m 0600 "$config" "$stage/node-config.json"
if ! bash "$stage/sync-node-config.sh"; then
  write_uncertain dapi-sync 'DAPI config sync request failed; worker retained for reconciliation'
  exit 4
fi
dapi_readback_attempts=0
dapi_readback_ok=false
dapi_readback_deadline=$((SECONDS + 30))
while (( SECONDS < dapi_readback_deadline )); do
  nodes="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes 2>/dev/null || true)"
  dapi_readback_attempts=$((dapi_readback_attempts + 1))
  if [[ -n "$nodes" ]]; then
    printf '%s\n' "$nodes" >"$stage/dapi-readback.last.json"
  else
    printf '{"error":"DAPI GET returned no response"}\n' >"$stage/dapi-readback.last.json"
  fi
  if jq -e --slurpfile expected "$worker_file" '
  def normalized:
    . as $node
    | if ((($node | has("inference_segment") | not) or $node.inference_segment == "")
        and (($node | has("poc_segment") | not) or $node.poc_segment == "")
        and (($node | has("hardware") | not) or $node.hardware == null or ($node.hardware | type == "array"))
        and (($node | has("node_num") | not) or ($node.node_num | type == "number" and floor == . and . >= 0))
        and (($node | has("registration_seq") | not) or ($node.registration_seq | type == "number" and floor == . and . >= 0)))
      then $node | del(.inference_segment,.poc_segment,.hardware,.node_num,.registration_seq)
      else null end;
  [.[] | select(.node.id == $expected[0].id and .node.host == $expected[0].host)] as $matches
  | ($matches | length) == 1 and ($matches[0].node | normalized) == $expected[0]
' <<<"$nodes" >/dev/null 2>&1 \
    && jq -e --arg runtime "$runtime_id" --slurpfile primary "$primary_before_file" '
  [.[] | select(.node.id == $runtime and .node.host == "inference")] as $matches
  | ($matches | length) == 1
    and (($matches[0].state.epoch_ml_nodes // {}) == ($primary[0].state.epoch_ml_nodes // {}))
    and (($matches[0].node | del(.node_num,.registration_seq)) == ($primary[0].node | del(.node_num,.registration_seq)))
' <<<"$nodes" >/dev/null 2>&1; then
    dapi_readback_ok=true
    break
  fi
  sleep 3
done
if [[ "$dapi_readback_ok" != true ]]; then
  write_uncertain dapi-readback 'DAPI registration did not converge to the intended worker and unchanged primary within the bounded readback window'
  exit 4
fi
[[ "$(sha256sum "$config" | awk '{print $1}')" == "$next_sha" && "$(stat -c %i "$config")" == "$config_inode" ]] || {
  write_uncertain config-drift 'node-config changed after worker registration; worker retained for reconciliation'
  exit 4
}
after_sha="$next_sha"
jq -cn --arg participant "$participant" --arg runtime_id "$runtime_id" --arg chain_id "$chain_id" --arg genesis_sha "$genesis_sha" \
  --arg worker_id "$worker_id" --arg endpoint "$endpoint" --arg descriptor_sha "$descriptor_sha" \
  --arg before_sha "$expected_config_sha" --arg after_sha "$after_sha" --arg network "$network" --arg project "$project" \
  '{schema_version:1,kind:"gdc-model-worker",outcome:"PASS",participant:$participant,runtime_id:$runtime_id,chain_id:$chain_id,genesis_sha256:$genesis_sha,worker_id:$worker_id,endpoint:$endpoint,descriptor_sha256:$descriptor_sha,node_config_before_sha256:$before_sha,node_config_after_sha256:$after_sha,docker_network:$network,compose_project:$project,registered_at:(now|todateiso8601)}' \
  >"$target/receipt.json.tmp"
install -m 0600 "$target/receipt.json.tmp" "$target/receipt.json"
rm -f "$target/receipt.json.tmp"
rm -f "$target/uncertain.json" "$target/node-config.before.json" "$target/node-config.next.json"
printf 'PASS model-worker applied and registered\n'
rm -rf -- "$stage"
trap - EXIT
REMOTE
if (( apply_rc == 4 )); then die "$NODE model-worker apply is UNCERTAIN; worker and recovery evidence retained at $remote_root; reconcile before retry"; fi
if (( apply_rc != 0 )); then die "$NODE model-worker apply failed; safe rollback was attempted only for $remote_root and $project"; fi
stage_created=false

ssh -T "$NODE" "sudo cat '$remote_root/receipt.json'" >"$receipt"
jq -e --arg hash "$descriptor_sha" --arg worker "$worker_id" \
  '.schema_version == 1 and .kind == "gdc-model-worker" and .outcome == "PASS" and .descriptor_sha256 == $hash and .worker_id == $worker' \
  "$receipt" >/dev/null || die 'remote model-worker receipt did not match the reviewed candidate'
chmod 0600 "$receipt"
printf 'PASS model-worker host=%s participant=%s worker=%s receipt=%s\n' "$NODE" "$participant" "$worker_id" "$receipt"
