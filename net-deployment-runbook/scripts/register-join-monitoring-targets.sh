#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --registry-host SSH_ALIAS [--check | --node NAME --public-host HOST]" >&2; }
registry=''; node=''; public_host=''; check=false
while (($#)); do
  case "$1" in
    --registry-host) registry="${2:-}"; shift 2 ;;
    --node) node="${2:-}"; shift 2 ;;
    --public-host) public_host="${2:-}"; shift 2 ;;
    --check) check=true; shift ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$registry" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { usage; exit 2; }
transport=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
if [[ "$check" == true ]]; then
  ssh "${transport[@]}" "$registry" 'test -d /srv/dai/ops/prometheus/targets && sudo -n test -w /srv/dai/ops/prometheus/targets && curl -fsS --max-time 10 http://127.0.0.1:9099/-/ready >/dev/null' || {
    echo 'JOIN monitoring collector must provide writable discovery targets and a ready Prometheus on port 9099' >&2
    exit 1
  }
  exit 0
fi
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]*$ && "$public_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { usage; exit 2; }

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
for spec in host:9101 cadvisor:8088 gonka-node:26660; do
  job="${spec%%:*}"; port="${spec##*:}"
  jq -cn --arg target "$public_host:$port" --arg host "$node" '[{targets:[$target],labels:{host:$host}}]' >"$stage/$job.json"
done

remote="/tmp/gdc-monitoring-targets-${node}-$$"
ssh "${transport[@]}" "$registry" "set -Eeuo pipefail; mkdir -p '$remote'; sudo -n install -d -m 0755 /srv/dai/ops/prometheus/targets/join/host /srv/dai/ops/prometheus/targets/join/cadvisor /srv/dai/ops/prometheus/targets/join/gonka-node"
scp "${transport[@]}" -q "$stage/host.json" "$stage/cadvisor.json" "$stage/gonka-node.json" "$registry:$remote/"
ssh "${transport[@]}" "$registry" "set -Eeuo pipefail
for job in host cadvisor gonka-node; do
  sudo -n install -m 0644 '$remote/'\"\$job\".json '/srv/dai/ops/prometheus/targets/join/'\"\$job\"/'$node.json.tmp'
  sudo -n mv -f '/srv/dai/ops/prometheus/targets/join/'\"\$job\"/'$node.json.tmp' '/srv/dai/ops/prometheus/targets/join/'\"\$job\"/'$node.json'
done
rm -rf '$remote'"
printf 'PASS registered Prometheus discovery targets node=%s registry=%s\n' "$node" "$registry"

# Require fresh scrapes of every endpoint while tolerating duplicate static discovery labels
query=''
for spec in host:9101 cadvisor:8088 gonka-node:26660; do
  selector="up{host=\"$node\",job=\"${spec%%:*}\",instance=\"$public_host:${spec##*:}\"}"
  query+="${query:+ + }(count(($selector == 1) and (time() - timestamp($selector) < 60)) > bool 0)"
done
for attempt in {1..12}; do
  if response="$(ssh "${transport[@]}" "$registry" "curl -fsS --max-time 10 --get --data-urlencode 'query=$query' http://127.0.0.1:9099/api/v1/query")" \
    && jq -e '.status == "success" and (.data.result | length == 1) and .data.result[0].value[1] == "3"' <<<"$response" >/dev/null; then
    printf 'PASS Prometheus scrapes JOIN endpoints node=%s registry=%s\n' "$node" "$registry"
    exit 0
  fi
  (( attempt == 12 )) || sleep 10
done
echo "Monitoring targets for $node are registered but Prometheus has not confirmed all three endpoints, retry this command without resetting the Host" >&2
exit 1
