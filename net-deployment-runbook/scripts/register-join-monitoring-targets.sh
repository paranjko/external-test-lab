#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --registry-host SSH_ALIAS --node NAME --public-host HOST" >&2; }
registry=''; node=''; public_host=''
while (($#)); do
  case "$1" in
    --registry-host) registry="${2:-}"; shift 2 ;;
    --node) node="${2:-}"; shift 2 ;;
    --public-host) public_host="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$registry" =~ ^[a-z0-9][a-z0-9_-]*$ && "$node" =~ ^[a-z0-9][a-z0-9_-]*$ && "$public_host" =~ ^[A-Za-z0-9.-]+$ ]] || { usage; exit 2; }

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
for spec in host:9101 cadvisor:8088 gonka-node:26660; do
  job="${spec%%:*}"; port="${spec##*:}"
  jq -cn --arg target "$public_host:$port" --arg host "$node" '[{targets:[$target],labels:{host:$host}}]' >"$stage/$job.json"
done

remote="/tmp/gdc-monitoring-targets-${node}-$$"
ssh "$registry" "set -Eeuo pipefail; mkdir -p '$remote'; sudo install -d -m 0755 /srv/dai/ops/prometheus/targets/join/host /srv/dai/ops/prometheus/targets/join/cadvisor /srv/dai/ops/prometheus/targets/join/gonka-node"
scp -q "$stage/host.json" "$stage/cadvisor.json" "$stage/gonka-node.json" "$registry:$remote/"
ssh "$registry" "set -Eeuo pipefail
for job in host cadvisor gonka-node; do
  sudo install -m 0644 '$remote/'\"\$job\".json '/srv/dai/ops/prometheus/targets/join/'\"\$job\"/'$node.json.tmp'
  sudo mv -f '/srv/dai/ops/prometheus/targets/join/'\"\$job\"/'$node.json.tmp' '/srv/dai/ops/prometheus/targets/join/'\"\$job\"/'$node.json'
done
rm -rf '$remote'"
printf 'PASS registered Prometheus discovery targets node=%s registry=%s\n' "$node" "$registry"
