#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
bash "$here/render.sh" gonka1hw92ev7r3u3uw6s0kx5ed9t9faptjwmfwzw774 "$fixture/output"
jq -e 'keys==["Qwen/Qwen2.5-7B-Instruct"]' "$fixture/output/primary-models.json" >/dev/null
jq -e '.id=="qwen3-4b:gonka1hw92ev7r3u3uw6s0kx5ed9t9faptjwmfwzw774--local-second" and
 .host=="gdc-dual-4b-router" and .max_concurrent==1 and
 (.models|keys)==["Qwen/Qwen3-4B-Instruct-2507"]' "$fixture/output/secondary-worker.json" >/dev/null
jq -e 'all(.[][];.args as $a|
 ($a|index("--kv-cache-memory-bytes")) as $i|
 $i!=null and $a[$i+1]=="2147483648" and
 ($a|index("--enforce-eager"))!=null)' "$here/profiles.json" >/dev/null
before=$(sha256sum "$fixture/output/primary-models.json")
jq -e '.[][] | .args as $a |
 ($a|index("--max-num-batched-tokens")) as $i |
 $i!=null and $a[$i+1]=="512"' "$here/profiles.json" >/dev/null
jq -e '.secondary|to_entries[]|. as $m|.value.args as $a|
 ($a|index("--served-model-name")) as $i|
 $i!=null and $a[$i+1]==$m.key' "$here/profiles.json" >/dev/null
if bash "$here/render.sh" gonka1hw92ev7r3u3uw6s0kx5ed9t9faptjwmfwzw774 "$fixture/output"; then exit 1; fi
[[ $(sha256sum "$fixture/output/primary-models.json") == "$before" ]]
if bash "$here/render.sh" invalid "$fixture/invalid"; then exit 1; fi
[[ ! -e $fixture/invalid ]]
HF_CACHE_ROOT=/fixture/cache HOST_DOCKER_NETWORK=fixture_default \
 docker compose -f "$here/compose.yaml" config --quiet
HF_CACHE_ROOT=/fixture/cache HOST_DOCKER_NETWORK=fixture_default \
 docker compose -f "$here/compose.yaml" config --format json |
 jq -e '.services.mlnode4b.volumes | length==1 and
 .[0].source=="/fixture/cache/hub" and .[0].target=="/root/.cache/hub" and
 .[0].read_only==true' >/dev/null
printf 'PASS offline renderer, retained models, explicit budgets, input and overwrite refusals, Compose validation\n'
