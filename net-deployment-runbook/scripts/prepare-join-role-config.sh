#!/bin/sh
# Compile validated Bootstrap data into a local JOIN role input. This remains
# local operator code and must not depend on Bash/GNU realpath/sha256sum.
set -eu

usage() {
  printf 'Usage: %s --output FILE --ssh-alias ALIAS --bootstrap-file FILE [--public-host HOST] [--p2p-port PORT] [--gpu-ssh-alias ALIAS]\n' "$0" >&2
}

shell_quote() {
  # The generated role input is later sourced by POSIX sh and Bash. Quote
  # paths, including spaces and Unicode, without relying on Bash printf %q.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

OUTPUT=''
SSH_ALIAS=''
BOOTSTRAP_FILE=''
PUBLIC_HOST=''
P2P_PORT=5000
GPU_SSH_ALIAS=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|--ssh-alias|--bootstrap-file|--public-host|--p2p-port|--gpu-ssh-alias)
      gdc_option=$1
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      case "$gdc_option" in
        --output) OUTPUT=$1 ;;
        --ssh-alias) SSH_ALIAS=$1 ;;
        --bootstrap-file) BOOTSTRAP_FILE=$1 ;;
        --public-host) PUBLIC_HOST=$1 ;;
        --p2p-port) P2P_PORT=$1 ;;
        --gpu-ssh-alias) GPU_SSH_ALIAS=$1 ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done
[ -n "$OUTPUT" ] && [ -n "$SSH_ALIAS" ] && [ -r "$BOOTSTRAP_FILE" ] || { usage; exit 2; }
printf '%s\n' "$SSH_ALIAS" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' \
  || { printf 'invalid JOIN SSH alias (use lowercase letters, digits, _ or -)\n' >&2; exit 2; }
printf '%s\n' "$P2P_PORT" | grep -Eq '^[1-9][0-9]{0,4}$' && [ "$P2P_PORT" -le 65535 ] \
  || { printf 'invalid JOIN P2P port\n' >&2; exit 2; }
if [ -n "$GPU_SSH_ALIAS" ]; then
  printf '%s\n' "$GPU_SSH_ALIAS" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' && [ "$GPU_SSH_ALIAS" != "$SSH_ALIAS" ] \
    || { printf 'invalid JOIN GPU SSH alias\n' >&2; exit 2; }
fi

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"
gdc_require_jq || exit $?
BOOTSTRAP_FILE=$(gdc_realpath_existing "$BOOTSTRAP_FILE") \
  || { printf 'JOIN Bootstrap path is not readable\n' >&2; exit 2; }
"$ROOT/scripts/network-bootstrap.sh" verify "$BOOTSTRAP_FILE" >/dev/null
if [ -z "$PUBLIC_HOST" ]; then
  PUBLIC_HOST=$("$ROOT/scripts/detect-public-host.sh" "$SSH_ALIAS")
fi
printf '%s\n' "$PUBLIC_HOST" | grep -Eq '^[A-Za-z0-9.-]+$' \
  || { printf 'invalid JOIN public host\n' >&2; exit 2; }

stage=$(gdc_mktemp_dir)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
"$ROOT/scripts/network-bootstrap.sh" stage "$BOOTSTRAP_FILE" "$stage" >/dev/null
bootstrap_sha256=$(gdc_sha256 "$BOOTSTRAP_FILE")
bootstrap_schema='https://gonka-dev.net/v1.bootstrap.schema.json'
# This file is generated locally from validated JSON, never downloaded or
# evaluated from a remote source. Values are schema-restricted URLs.
. "$stage/bootstrap.env"
[ -n "${SEED_NODE_RPC_URL:-}" ] \
  || { printf 'validated bootstrap did not yield a usable seed RPC\n' >&2; exit 1; }
network_host=${SEED_NODE_RPC_URL#*://}
network_host=${network_host%%[:/]*}
[ -n "$network_host" ] \
  || { printf 'validated bootstrap did not yield a usable seed RPC host\n' >&2; exit 1; }

gdc_private_dir "$(dirname "$OUTPUT")"
umask 077
{
  printf 'GDC_NODE_ALIASES='; shell_quote "$SSH_ALIAS"; printf '\n'
  printf 'GDC_NODE_PUBLIC_HOSTS='; shell_quote "$SSH_ALIAS=$PUBLIC_HOST"; printf '\n'
  printf 'GDC_NODE_P2P_PORTS='; shell_quote "$SSH_ALIAS=$P2P_PORT"; printf '\n'
  printf 'GDC_NODE_ML_HOSTS='; shell_quote "${GPU_SSH_ALIAS:+$SSH_ALIAS=$GPU_SSH_ALIAS}"; printf '\n'
  printf 'GDC_JOIN_BOOTSTRAP_FILE='; shell_quote "$BOOTSTRAP_FILE"; printf '\n'
  printf 'GDC_JOIN_BOOTSTRAP_SHA256='; shell_quote "$bootstrap_sha256"; printf '\n'
  printf 'GDC_JOIN_BOOTSTRAP_SCHEMA='; shell_quote "$bootstrap_schema"; printf '\n'
  printf 'GDC_JOIN_NETWORK_HOST='; shell_quote "$network_host"; printf '\n'
  printf 'GDC_CHAIN_RPC_URL='; shell_quote "$SEED_NODE_RPC_URL/"; printf '\n'
  printf 'SEED_API_URL='; shell_quote "$SEED_API_URL"; printf '\n'
  printf 'SEED_NODE_RPC_URL='; shell_quote "$SEED_NODE_RPC_URL"; printf '\n'
  printf 'SEED_NODE_P2P_URL='; shell_quote "$SEED_NODE_P2P_URL"; printf '\n'
  printf 'GDC_JOIN_ROLE_INPUT=true\n'
} >"$OUTPUT"
chmod 0600 "$OUTPUT"
