#!/usr/bin/env bash
# Offline rendering only. No transport, service changes or DAPI registration.
set -Eeuo pipefail
[[ $# == 3 && $1 =~ ^gonka1[023456789acdefghjklmnpqrstuvwxyz]{38}$ ]] || {
  echo 'Usage: render.sh PARTICIPANT DESCRIPTOR.json NEW_OUTPUT_DIRECTORY' >&2
  exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
participant=$1 descriptor=$2 output=$3
bash "$here/validate.sh" "$descriptor"
[[ ! -e $output && ! -L $output ]] || { echo 'Output path already exists' >&2; exit 1; }
router_alias="gdc-shared-${participant}-router"
model_alias="gdc-shared-${participant}-ml"
router_service="gdc-${participant}-router"
model_service="gdc-${participant}-ml"
umask 077
parent=$(dirname "$output")
[[ -d $parent ]] || { echo 'Output parent directory must already exist' >&2; exit 1; }
cleanup() { [[ -z ${tmpdir:-} ]] || rm -rf -- "$tmpdir"; }
trap cleanup EXIT
tmpdir=$(mktemp -d "$parent/.shared-gpu-render.XXXXXX")
jq --arg participant "$participant" --arg host "$router_alias" '
  {id:(.secondary.model_id+":"+$participant+"--secondary"),
   host:$host,inference_port:5000,poc_port:8080,max_concurrent:1,
   models:{(.secondary.model_id):{args:.secondary.args}}}
' "$descriptor" >"$tmpdir/secondary-worker.json"
jq '{model_id:.primary.model_id,revision:.primary.revision,image:.primary.image,args:.primary.args,
     management_port:.primary.management_port,inference_port:.primary.inference_port,
     gpu_device:.gpu_device}' "$descriptor" >"$tmpdir/primary-expected.json"
jq -n --slurpfile d "$descriptor" --arg router "$router_alias" --arg modelhost "$model_alias" \
  --arg router_service "$router_service" --arg model_service "$model_service" '
  $d[0] as $d | {
    services:{($model_service):{image:$d.secondary.image,restart:"unless-stopped",mem_limit:"24g",cpus:8,shm_size:"1g",
      environment:{HF_HOME:"/root/.cache",HF_HUB_OFFLINE:"1",HF_HUB_DISABLE_TELEMETRY:"1",
        MLNODE_VLLM_MODULE:"gonka_poc.entrypoint.api_router",PYTHONPATH:"/app:/app/packages/api/src"},
      volumes:[{type:"bind",source:($d.hf_cache_root+"/hub"),target:"/root/.cache/hub",read_only:true}],
      command:["uvicorn","api.app:app","--host=0.0.0.0","--port=8080"],
      deploy:{resources:{reservations:{devices:[{driver:"nvidia",device_ids:[$d.gpu_device],capabilities:["gpu"]}]}}},
      networks:{host:{aliases:[$modelhost]}}},
      ($router_service):{image:$d.nginx_image,restart:"unless-stopped",volumes:["./nginx.conf:/etc/nginx/nginx.conf:ro"],networks:{host:{aliases:[$router]}}}},
    networks:{host:{external:true,name:$d.host_docker_network}}
  }
' >"$tmpdir/secondary-compose.json"
jq -nr --arg model "$model_alias" '
  "events {}\nhttp {\n  resolver 127.0.0.11 valid=10s;\n  resolver_timeout 5s;\n  upstream ml_api { zone ml_api 64k; server \($model):8080 resolve; }\n  upstream ml_inference { zone ml_inference 64k; server \($model):5000 resolve; }\n  server { listen 8080; client_max_body_size 0; proxy_connect_timeout 24h; proxy_send_timeout 24h; proxy_read_timeout 24h; location /v3.0.8/ { proxy_pass http://ml_api/; } location / { proxy_pass http://ml_api; } }\n  server { listen 5000; client_max_body_size 0; proxy_connect_timeout 24h; proxy_send_timeout 24h; proxy_read_timeout 24h; location /v3.0.8/api/ { proxy_pass http://ml_api/api/; } location /v3.0.8/ { proxy_pass http://ml_inference/; } location / { proxy_pass http://ml_inference; } }\n}\n"
' >"$tmpdir/nginx.conf"
mv -- "$tmpdir" "$output"
tmpdir=''
printf 'Rendered offline shared-GPU candidate; no deployment or registration performed.\n'
