#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
nginx_image='nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609'
docker info >/dev/null || { echo 'Docker daemon is required for nginx configuration validation' >&2; exit 1; }
docker pull "$nginx_image" >/dev/null
fixture_image='alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40'
docker pull "$fixture_image" >/dev/null
fixture_network="gdc-shared-gpu-dns-$(printf '%s' "$tmp" | sha256sum | cut -c1-10)"
base_project="$fixture_network-base"
base_compose="$tmp/base-compose.yaml"
dns_projects=()
dns_compose_files=()
docker network create "$fixture_network" >/dev/null
cleanup_docker() {
  for index in "${!dns_projects[@]}"; do
    project="${dns_projects[$index]}"
    compose_file="${dns_compose_files[$index]}"
    docker compose --project-name "$project" -f "$compose_file" down --remove-orphans >/dev/null 2>&1 || true
  done
  docker compose --project-name "$base_project" -f "$base_compose" down --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$fixture_network" >/dev/null 2>&1 || true
}
trap 'cleanup_docker; rm -rf -- "$tmp"' EXIT
cat >"$base_compose" <<YAML
services:
  mlnode:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    networks: [fixture]
  router:
    image: $fixture_image
    command: ["sh", "-c", "sleep 3600"]
    networks: [fixture]
networks:
  fixture:
    external: true
    name: $fixture_network
YAML
docker compose --project-name "$base_project" -f "$base_compose" up -d --pull never --wait >/dev/null
primary_mlnode_id="$(docker compose --project-name "$base_project" -f "$base_compose" ps -q mlnode)"
primary_router_id="$(docker compose --project-name "$base_project" -f "$base_compose" ps -q router)"
primary_mlnode_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$primary_mlnode_id")"
primary_router_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$primary_router_id")"
assert_dns_only() {
  local client=$1 hostname=$2 expected=$3 forbidden=$4 result
  result="$(docker exec "$client" nslookup "$hostname." 2>&1)" || {
    printf 'DNS lookup failed for %s: %s\n' "$hostname" "$result" >&2
    return 1
  }
  grep -Fq "$expected" <<<"$result" && ! grep -Fq "$forbidden" <<<"$result" || {
    printf 'DNS name %s did not resolve exclusively to %s (excluded %s):\n%s\n' \
      "$hostname" "$expected" "$forbidden" "$result" >&2
    return 1
  }
}
jq -n '"events {}\nhttp {}\n"' >"$tmp/json-encoded-nginx.conf"
[[ "$(head -c 1 "$tmp/json-encoded-nginx.conf")" == '"' ]]
if docker run --rm --network none --mount "type=bind,src=$tmp/json-encoded-nginx.conf,dst=/etc/nginx/nginx.conf,readonly" \
  "$nginx_image" nginx -t >"$tmp/json-encoded-nginx.out" 2>&1; then
  echo 'JSON-encoded nginx config unexpectedly passed nginx -t' >&2
  exit 1
fi
make_descriptor() {
  local primary=$1 secondary=$2 output=$3
  jq -n --arg p "$primary" --arg s "$secondary" --arg nginx_image "$nginx_image" --arg network "$fixture_network" '
    def w($id;$rev;$port): {model_id:$id,revision:$rev,
      image:"ghcr.io/gonka-ai/mlnode:3.0.16@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      args:["--revision",$rev,"--gpu-memory-utilization","0.4"],
      management_port:8080,inference_port:5000};
    {gpu_device:"0",host_docker_network:$network,hf_cache_root:"/fixture/cache",
     nginx_image:$nginx_image,
     primary:w($p;"1111111111111111111111111111111111111111";8080),
     secondary:w($s;"2222222222222222222222222222222222222222";8080)}' >"$output"
}
participant=gonka1hw92ev7r3u3uw6s0kx5ed9t9faptjwmfwzw774
variant=0
for pair in 'Qwen/Qwen2.5-7B-Instruct|Qwen/Qwen3-4B-Instruct-2507' 'Qwen/Qwen3-4B-Instruct-2507|Qwen/Qwen3-0.6B'; do
  variant=$((variant + 1))
  IFS='|' read -r primary secondary <<<"$pair"
  descriptor="$tmp/descriptor.json" output="$tmp/out-$(basename "$primary")"
  make_descriptor "$primary" "$secondary" "$descriptor"
  bash "$here/render.sh" "$participant" "$descriptor" "$output"
  jq -e --arg p "$primary" '.model_id==$p and .management_port==8080 and .inference_port==5000' "$output/primary-expected.json" >/dev/null
  jq -e --arg s "$secondary" --arg host "gdc-shared-${participant}-router" '.host==$host and .inference_port==5000 and .poc_port==8080 and (.models|keys==[$s])' "$output/secondary-worker.json" >/dev/null
  model_service="gdc-${participant}-ml"
  router_service="gdc-${participant}-router"
  jq -e --arg model "$model_service" --arg router "$router_service" '
    (.services|keys|sort)==([$model,$router]|sort) and
    (.services[$model].image|test("@sha256:[a-f0-9]{64}$")) and
    .services[$model].deploy.resources.reservations.devices[0].device_ids==["0"] and
    .services[$model].volumes[0].source=="/fixture/cache/hub" and
    (.services[$router].image|test("@sha256:[a-f0-9]{64}$"))' "$output/secondary-compose.json" >/dev/null
  grep -Fq "server gdc-shared-${participant}-ml:8080 resolve" "$output/nginx.conf"
  grep -Fq "server gdc-shared-${participant}-ml:5000 resolve" "$output/nginx.conf"
  [[ "$(head -c 1 "$output/nginx.conf")" != '"' ]]
  docker run --rm --network none --mount "type=bind,src=$output/nginx.conf,dst=/etc/nginx/nginx.conf,readonly" \
    "$nginx_image" nginx -t >/dev/null
  docker compose -f "$output/secondary-compose.json" config --quiet
  dns_compose="$output/dns-compose.yaml"
  jq --arg model "$model_service" --arg router "$router_service" --arg image "$fixture_image" '
    .services[$model].image=$image |
    .services[$model].command=["sh","-c","sleep 3600"] |
    # This fixture tests DNS with sleeping containers, not ML resource capacity.
    del(.services[$model].volumes,.services[$model].deploy,.services[$model].cpus,.services[$model].mem_limit) |
    .services[$router].image=$image |
    .services[$router].command=["sh","-c","sleep 3600"] |
    del(.services[$router].volumes)
  ' "$output/secondary-compose.json" >"$dns_compose"
  dns_project="${fixture_network}-worker-${variant}"
  dns_projects+=("$dns_project")
  dns_compose_files+=("$dns_compose")
  docker compose --project-name "$dns_project" -f "$dns_compose" up -d --pull never --wait >/dev/null
  secondary_mlnode_id="$(docker compose --project-name "$dns_project" -f "$dns_compose" ps -q "$model_service")"
  secondary_router_id="$(docker compose --project-name "$dns_project" -f "$dns_compose" ps -q "$router_service")"
  secondary_mlnode_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$secondary_mlnode_id")"
  secondary_router_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$secondary_router_id")"
  assert_dns_only "$secondary_router_id" mlnode "$primary_mlnode_ip" "$secondary_mlnode_ip"
  assert_dns_only "$secondary_router_id" router "$primary_router_ip" "$secondary_router_ip"
  assert_dns_only "$secondary_router_id" "$model_service" "$secondary_mlnode_ip" "$primary_mlnode_ip"
  assert_dns_only "$secondary_router_id" "gdc-shared-${participant}-ml" "$secondary_mlnode_ip" "$primary_mlnode_ip"
  assert_dns_only "$secondary_router_id" "$router_service" "$secondary_router_ip" "$primary_router_ip"
  assert_dns_only "$secondary_router_id" "gdc-shared-${participant}-router" "$secondary_router_ip" "$primary_router_ip"
  docker compose --project-name "$dns_project" -f "$dns_compose" down --remove-orphans >/dev/null
  if bash "$here/render.sh" "$participant" "$descriptor" "$output" >/dev/null 2>&1; then exit 1; fi
done
refusal() {
  local descriptor=$1
  if bash "$here/validate.sh" "$descriptor" >/dev/null 2>&1; then
    echo "Unexpected descriptor acceptance: $descriptor" >&2
    exit 1
  fi
}
make_descriptor model/a model/b "$tmp/base.json"
jq '.secondary.image="ghcr.io/gonka-ai/mlnode:latest"' "$tmp/base.json" >"$tmp/unpinned.json"
refusal "$tmp/unpinned.json"
jq '.secondary.args[3]="1.1"' "$tmp/base.json" >"$tmp/fraction.json"
refusal "$tmp/fraction.json"
jq '.secondary.inference_port=5001' "$tmp/base.json" >"$tmp/collision.json"
refusal "$tmp/collision.json"
jq 'del(.primary.args)' "$tmp/base.json" >"$tmp/malformed.json"
refusal "$tmp/malformed.json"
if bash "$here/render.sh" invalid "$tmp/base.json" "$tmp/no-output" >/dev/null 2>&1; then exit 1; fi
[[ ! -e $tmp/no-output ]]
printf 'PASS shared-GPU renderer variants and fail-closed validation\n'
