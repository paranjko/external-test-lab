#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --output FILE --ssh-alias ALIAS [--public-host DNS] [--public-edge-ssh-alias ALIAS] [--public-edge-host DNS]" >&2
}

OUTPUT=''; SSH_ALIAS=''; PUBLIC_HOST=''; PUBLIC_EDGE_SSH_ALIAS=''; PUBLIC_EDGE_HOST=''
while (($#)); do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --ssh-alias) SSH_ALIAS="${2:-}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
    --public-edge-ssh-alias) PUBLIC_EDGE_SSH_ALIAS="${2:-}"; shift 2 ;;
    --public-edge-host) PUBLIC_EDGE_HOST="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$OUTPUT" && -n "$SSH_ALIAS" ]] || { usage; exit 2; }
[[ "$SSH_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid Genesis SSH alias' >&2; exit 2; }
[[ -z "$PUBLIC_EDGE_SSH_ALIAS" || "$PUBLIC_EDGE_SSH_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid public edge SSH alias' >&2; exit 2; }
[[ -n "$PUBLIC_EDGE_SSH_ALIAS" ]] || PUBLIC_EDGE_SSH_ALIAS="$SSH_ALIAS"
[[ -z "$PUBLIC_EDGE_HOST" || "$PUBLIC_EDGE_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'invalid public edge host' >&2; exit 2; }
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$("$(dirname "$0")/detect-public-host.sh" "$SSH_ALIAS")"
fi
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'invalid Genesis public host' >&2; exit 2; }
if [[ -z "$PUBLIC_EDGE_HOST" ]]; then
  PUBLIC_EDGE_HOST="$("$(dirname "$0")/detect-public-host.sh" "$PUBLIC_EDGE_SSH_ALIAS")"
fi
[[ "$PUBLIC_EDGE_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'invalid public edge host' >&2; exit 2; }

node_aliases="$SSH_ALIAS"
node_hosts="$SSH_ALIAS=$PUBLIC_HOST"
node_gpu_profiles="$SSH_ALIAS=auto"
node_p2p_ports="$SSH_ALIAS=5000"
if [[ "$PUBLIC_EDGE_SSH_ALIAS" != "$SSH_ALIAS" ]]; then
  node_aliases+=" $PUBLIC_EDGE_SSH_ALIAS"
  node_hosts+=" $PUBLIC_EDGE_SSH_ALIAS=$PUBLIC_EDGE_HOST"
  node_gpu_profiles+=" $PUBLIC_EDGE_SSH_ALIAS=auto"
  node_p2p_ports+=" $PUBLIC_EDGE_SSH_ALIAS=5000"
fi

install -d -m 0700 "$(dirname "$OUTPUT")"
umask 077
{
  printf 'GDC_NODE_ALIASES=%q\n' "$node_aliases"
  printf 'GDC_NODE_PUBLIC_HOSTS=%q\n' "$node_hosts"
  printf 'GDC_NODE_GPU_PROFILES=%q\n' "$node_gpu_profiles"
  printf 'GDC_NODE_P2P_PORTS=%q\n' "$node_p2p_ports"
  printf 'GDC_GENESIS_NODE=%q\n' "$SSH_ALIAS"
  printf 'GDC_PUBLIC_EDGE_NODE=%q\n' "$PUBLIC_EDGE_SSH_ALIAS"
  printf 'GDC_GATEWAY_NODE=%q\n' "$SSH_ALIAS"
  printf 'GDC_DEPLOYMENT_PROFILE=%q\n' community-lab
  printf 'GDC_OPERATOR_SERVICES_PROFILE=%q\n' gdc-lab
  printf 'GDC_GENESIS_ROLE_INPUT=true\n'
} >"$OUTPUT"
