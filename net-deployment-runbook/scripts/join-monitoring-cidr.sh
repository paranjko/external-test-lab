#!/usr/bin/env bash
set -Eeuo pipefail

fail() { echo "$*" >&2; exit 2; }
cidr="${GDC_MONITORING_DOCKER_CIDR:-}"
registry="${1:-}"
if [[ -z "$cidr" && -n "$registry" ]]; then
  [[ "$registry" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail 'JOIN monitoring collector SSH alias is invalid'
  containers="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$registry" \
    "sudo -n docker ps --filter label=com.docker.compose.service=prometheus --format '{{.ID}}'")" \
    || fail 'JOIN cannot inspect Prometheus on the configured monitoring collector'
  [[ "$containers" =~ ^[0-9a-f]{12,64}$ ]] || fail 'JOIN requires exactly one running Prometheus service on the configured collector'
  networks="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$registry" \
    "sudo -n docker inspect '$containers' --format '{{json .NetworkSettings.Networks}}'")" \
    || fail 'JOIN cannot inspect Prometheus on the configured monitoring collector'
  network="$(jq -er 'keys | if length == 1 then .[0] else error("ambiguous networks") end' <<<"$networks" 2>/dev/null)" \
    || fail 'JOIN requires one Prometheus Docker network or an explicit GDC_MONITORING_DOCKER_CIDR'
  [[ "$network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail 'JOIN found an invalid Prometheus Docker network name'
  subnets="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$registry" \
    "sudo -n docker network inspect '$network' --format '{{json .IPAM.Config}}'")" \
    || fail 'JOIN cannot inspect the Prometheus Docker subnet'
  cidr="$(jq -er '[.[].Subnet | select(type == "string") | select(contains(":") | not)] | unique | if length == 1 then .[0] else error("ambiguous subnets") end' <<<"$subnets" 2>/dev/null)" \
    || fail 'JOIN requires one Prometheus IPv4 subnet or an explicit GDC_MONITORING_DOCKER_CIDR'
fi
# A participant without a configured collector grants no additional Docker network access
cidr="${cidr:-127.0.0.1/32}"
[[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] \
  || fail 'JOIN requires GDC_MONITORING_DOCKER_CIDR set to the verified Prometheus Docker IPv4 subnet'
IFS='./' read -r a b c d _ <<<"$cidr"
for octet in "$a" "$b" "$c" "$d"; do
  (( 10#$octet <= 255 )) || fail 'JOIN monitoring Docker CIDR contains an invalid IPv4 address'
done
printf '%s\n' "$cidr"
