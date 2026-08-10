#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --output FILE --ssh-alias ALIAS [--gpu-ssh-alias ALIAS] [--bootstrap-url URL]" >&2
}

OUTPUT=''
SSH_ALIAS=''
GPU_SSH_ALIAS=''
BOOTSTRAP_URL="${GDC_JOIN_BOOTSTRAP_URL:-https://node0.gonka-dev.net/join-bootstrap}"
while (($#)); do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --ssh-alias) SSH_ALIAS="${2:-}"; shift 2 ;;
    --gpu-ssh-alias) GPU_SSH_ALIAS="${2:-}"; shift 2 ;;
    --bootstrap-url) BOOTSTRAP_URL="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$OUTPUT" && -n "$SSH_ALIAS" ]] || { usage; exit 2; }
[[ "$SSH_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid JOIN SSH alias' >&2; exit 2; }
if [[ -n "$GPU_SSH_ALIAS" ]]; then
  [[ "$GPU_SSH_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid JOIN GPU SSH alias' >&2; exit 2; }
  [[ "$GPU_SSH_ALIAS" != "$SSH_ALIAS" ]] || { echo 'JOIN Host and GPU SSH aliases must be different' >&2; exit 2; }
fi
[[ "$BOOTSTRAP_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$ ]] \
  || { echo 'JOIN bootstrap URL must use HTTPS' >&2; exit 2; }
BOOTSTRAP_URL="${BOOTSTRAP_URL%/}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/profile"
for path in manifest.sha256 topology.env profile/genesis.env; do
  curl -fsS --connect-timeout 10 --max-time 60 "$BOOTSTRAP_URL/$path" -o "$tmp/$path"
done

grep -E '  \./(topology\.env|profile/genesis\.env)$' "$tmp/manifest.sha256" >"$tmp/required.sha256"
[[ "$(wc -l <"$tmp/required.sha256")" -eq 2 ]] || { echo 'public bootstrap manifest is incomplete' >&2; exit 1; }
(cd "$tmp" && sha256sum -c required.sha256)

allowed='GDC_NODE_ALIASES|GDC_NODE_PUBLIC_HOSTS|GDC_NODE_GPU_PROFILES|GDC_NODE_P2P_PORTS|GDC_NODE_ML_HOSTS|GDC_GENESIS_NODE|GDC_PUBLIC_EDGE_NODE|GDC_GATEWAY_NODE'
if grep -Ev "^($allowed)=([A-Za-z0-9._=\\\\ -]*|'')$" "$tmp/topology.env" | grep -q .; then
  echo 'public topology contains an unsupported assignment' >&2
  exit 1
fi
for name in GDC_NODE_ALIASES GDC_NODE_PUBLIC_HOSTS GDC_NODE_GPU_PROFILES GDC_NODE_P2P_PORTS GDC_GENESIS_NODE; do
  [[ "$(grep -c "^$name=" "$tmp/topology.env")" -eq 1 ]] || { echo "public topology is missing $name" >&2; exit 1; }
done

# The file is generated with printf %q and was restricted above to inert
# assignment characters before it is sourced.
# shellcheck disable=SC1090
source "$tmp/topology.env"
if [[ " $GDC_NODE_ALIASES " != *" $SSH_ALIAS "* ]]; then
  public_host="$("$(dirname "$0")/detect-public-host.sh" "$SSH_ALIAS")"
  GDC_NODE_ALIASES+=" $SSH_ALIAS"
  GDC_NODE_PUBLIC_HOSTS+=" $SSH_ALIAS=$public_host"
  GDC_NODE_GPU_PROFILES+=" $SSH_ALIAS=auto"
  GDC_NODE_P2P_PORTS+=" $SSH_ALIAS=5000"
fi
if [[ -n "$GPU_SSH_ALIAS" ]]; then
  updated_ml_hosts=''
  for mapping in ${GDC_NODE_ML_HOSTS:-}; do
    [[ "${mapping%%=*}" == "$SSH_ALIAS" ]] && continue
    updated_ml_hosts+="${updated_ml_hosts:+ }$mapping"
  done
  GDC_NODE_ML_HOSTS="${updated_ml_hosts}${updated_ml_hosts:+ }$SSH_ALIAS=$GPU_SSH_ALIAS"
fi

install -d -m 0700 "$(dirname "$OUTPUT")"
umask 077
{
  printf 'GDC_NODE_ALIASES=%q\n' "$GDC_NODE_ALIASES"
  printf 'GDC_NODE_PUBLIC_HOSTS=%q\n' "$GDC_NODE_PUBLIC_HOSTS"
  printf 'GDC_NODE_GPU_PROFILES=%q\n' "$GDC_NODE_GPU_PROFILES"
  printf 'GDC_NODE_P2P_PORTS=%q\n' "$GDC_NODE_P2P_PORTS"
  printf 'GDC_NODE_ML_HOSTS=%q\n' "${GDC_NODE_ML_HOSTS:-}"
  printf 'GDC_GENESIS_NODE=%q\n' "$GDC_GENESIS_NODE"
  printf 'GDC_PUBLIC_EDGE_NODE=%q\n' "${GDC_PUBLIC_EDGE_NODE:-$GDC_GENESIS_NODE}"
  printf 'GDC_GATEWAY_NODE=%q\n' "${GDC_GATEWAY_NODE:-$GDC_GENESIS_NODE}"
  printf 'GDC_JOIN_BOOTSTRAP_URL=%q\n' "$BOOTSTRAP_URL"
  printf 'GDC_DEPLOYMENT_PROFILE=community-lab\n'
  printf 'GDC_OPERATOR_SERVICES_PROFILE=gdc-lab\n'
  printf 'GDC_JOIN_ROLE_INPUT=true\n'
} >"$OUTPUT"
