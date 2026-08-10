#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --output FILE --ssh-alias ALIAS [--public-host DNS]" >&2
}

OUTPUT=''; SSH_ALIAS=''; PUBLIC_HOST=''
while (($#)); do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --ssh-alias) SSH_ALIAS="${2:-}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$OUTPUT" && -n "$SSH_ALIAS" ]] || { usage; exit 2; }
[[ "$SSH_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid Genesis SSH alias' >&2; exit 2; }
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$("$(dirname "$0")/detect-public-host.sh" "$SSH_ALIAS")"
fi
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'invalid Genesis public host' >&2; exit 2; }

install -d -m 0700 "$(dirname "$OUTPUT")"
umask 077
{
  printf 'GDC_NODE_ALIASES=%q\n' "$SSH_ALIAS"
  printf 'GDC_NODE_PUBLIC_HOSTS=%q\n' "$SSH_ALIAS=$PUBLIC_HOST"
  printf 'GDC_NODE_GPU_PROFILES=%q\n' "$SSH_ALIAS=auto"
  printf 'GDC_NODE_P2P_PORTS=%q\n' "$SSH_ALIAS=5000"
  printf 'GDC_GENESIS_NODE=%q\n' "$SSH_ALIAS"
  printf 'GDC_PUBLIC_EDGE_NODE=%q\n' "$SSH_ALIAS"
  printf 'GDC_GATEWAY_NODE=%q\n' "$SSH_ALIAS"
  printf 'GDC_DEPLOYMENT_PROFILE=%q\n' community-lab
  printf 'GDC_OPERATOR_SERVICES_PROFILE=%q\n' gdc-lab
  printf 'GDC_GENESIS_ROLE_INPUT=true\n'
} >"$OUTPUT"
