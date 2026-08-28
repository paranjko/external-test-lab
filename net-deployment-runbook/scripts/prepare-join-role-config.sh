#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --output FILE --ssh-alias ALIAS --bootstrap-file FILE [--public-host HOST] [--p2p-port PORT] [--gpu-ssh-alias ALIAS]" >&2
}

OUTPUT=''
SSH_ALIAS=''
BOOTSTRAP_FILE=''
PUBLIC_HOST=''
P2P_PORT=5000
GPU_SSH_ALIAS=''
while (($#)); do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --ssh-alias) SSH_ALIAS="${2:-}"; shift 2 ;;
    --bootstrap-file) BOOTSTRAP_FILE="${2:-}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
    --p2p-port) P2P_PORT="${2:-}"; shift 2 ;;
    --gpu-ssh-alias) GPU_SSH_ALIAS="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$OUTPUT" && -n "$SSH_ALIAS" && -r "$BOOTSTRAP_FILE" ]] || { usage; exit 2; }
[[ "$SSH_ALIAS" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'invalid JOIN SSH alias (use lowercase letters, digits, _ or -)' >&2; exit 2; }
[[ "$P2P_PORT" =~ ^[1-9][0-9]{0,4}$ && "$P2P_PORT" -le 65535 ]] || { echo 'invalid JOIN P2P port' >&2; exit 2; }
if [[ -n "$GPU_SSH_ALIAS" ]]; then
  [[ "$GPU_SSH_ALIAS" =~ ^[a-z0-9][a-z0-9_-]*$ && "$GPU_SSH_ALIAS" != "$SSH_ALIAS" ]] || { echo 'invalid JOIN GPU SSH alias' >&2; exit 2; }
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/network-bootstrap.sh" verify "$BOOTSTRAP_FILE" >/dev/null
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$("$ROOT/scripts/detect-public-host.sh" "$SSH_ALIAS")"
fi
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'invalid JOIN public host' >&2; exit 2; }

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
"$ROOT/scripts/network-bootstrap.sh" stage "$BOOTSTRAP_FILE" "$stage" >/dev/null
bootstrap_sha256="$(sha256sum "$BOOTSTRAP_FILE" | awk '{print $1}')"
bootstrap_schema='https://gonka-dev.net/v1.bootstrap.schema.json'
# This file is generated locally from validated JSON, never downloaded or
# evaluated from a remote source.
source "$stage/bootstrap.env"
[[ -n "${SEED_NODE_RPC_URL:-}" ]] || { echo 'validated bootstrap did not yield a usable seed RPC' >&2; exit 1; }
network_host="${SEED_NODE_RPC_URL#*://}"
network_host="${network_host%%[:/]*}"
[[ -n "$network_host" ]] || { echo 'validated bootstrap did not yield a usable seed RPC host' >&2; exit 1; }

install -d -m 0700 "$(dirname "$OUTPUT")"
umask 077
{
  printf 'GDC_NODE_ALIASES=%q\n' "$SSH_ALIAS"
  printf 'GDC_NODE_PUBLIC_HOSTS=%q\n' "$SSH_ALIAS=$PUBLIC_HOST"
  printf 'GDC_NODE_P2P_PORTS=%q\n' "$SSH_ALIAS=$P2P_PORT"
  printf 'GDC_NODE_ML_HOSTS=%q\n' "${GPU_SSH_ALIAS:+$SSH_ALIAS=$GPU_SSH_ALIAS}"
  printf 'GDC_JOIN_BOOTSTRAP_FILE=%q\n' "$(realpath -e -- "$BOOTSTRAP_FILE")"
  printf 'GDC_JOIN_BOOTSTRAP_SHA256=%q\n' "$bootstrap_sha256"
  printf 'GDC_JOIN_BOOTSTRAP_SCHEMA=%q\n' "$bootstrap_schema"
  printf 'GDC_JOIN_NETWORK_HOST=%q\n' "$network_host"
  printf 'GDC_CHAIN_RPC_URL=%q\n' "$SEED_NODE_RPC_URL/"
  printf 'SEED_API_URL=%q\n' "$SEED_API_URL"
  printf 'SEED_NODE_RPC_URL=%q\n' "$SEED_NODE_RPC_URL"
  printf 'SEED_NODE_P2P_URL=%q\n' "$SEED_NODE_P2P_URL"
  printf 'GDC_JOIN_ROLE_INPUT=true\n'
} >"$OUTPUT"
