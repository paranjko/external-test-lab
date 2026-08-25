#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
join_role_stage='load release profile'
on_join_role_error() {
  local rc="$?" line="$1"
  trap - ERR
  printf 'ERROR JOIN role configuration failed exit=%s line=%s stage=%s bootstrap_url=%s\n' \
    "$rc" "$line" "$join_role_stage" "${BOOTSTRAP_URL:-unavailable}" >&2
  exit "$rc"
}
trap 'on_join_role_error "$LINENO"' ERR

# This helper runs before the JOIN phase loads the selected release profile.
# Load it here so public bootstrap compatibility is checked against the
# operator's chosen release rather than an inherited shell variable.
# shellcheck disable=SC1091
source "$ROOT/scripts/profile.sh"
load_profiles

usage() {
  echo "Usage: $0 --output FILE --ssh-alias ALIAS [--public-host DNS] [--gpu-ssh-alias ALIAS] [--bootstrap-url URL]" >&2
}

OUTPUT=''
SSH_ALIAS=''
GPU_SSH_ALIAS=''
PUBLIC_HOST=''
BOOTSTRAP_URL="${GDC_JOIN_BOOTSTRAP_URL:-https://api.gonka-dev.net/join-bootstrap}"
while (($#)); do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --ssh-alias) SSH_ALIAS="${2:-}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
    --gpu-ssh-alias) GPU_SSH_ALIAS="${2:-}"; shift 2 ;;
    --bootstrap-url) BOOTSTRAP_URL="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$OUTPUT" && -n "$SSH_ALIAS" ]] || { usage; exit 2; }
[[ "$SSH_ALIAS" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'invalid JOIN SSH alias (use lowercase letters, digits, _ or -)' >&2; exit 2; }
[[ -z "$PUBLIC_HOST" || "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'invalid JOIN public host' >&2; exit 2; }
if [[ -n "$GPU_SSH_ALIAS" ]]; then
  [[ "$GPU_SSH_ALIAS" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'invalid JOIN GPU SSH alias (use lowercase letters, digits, _ or -)' >&2; exit 2; }
  [[ "$GPU_SSH_ALIAS" != "$SSH_ALIAS" ]] || { echo 'JOIN Host and GPU SSH aliases must be different' >&2; exit 2; }
fi
[[ "$BOOTSTRAP_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$ ]] \
  || { echo 'JOIN bootstrap URL must use HTTPS' >&2; exit 2; }
BOOTSTRAP_URL="${BOOTSTRAP_URL%/}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
verify_public_checksum() {
  local manifest="$1" required="$2" expected path actual checked=0
  while read -r expected path; do
    [[ "$expected" =~ ^[0-9a-f]{64}$ && "$path" == ./* ]] || {
      echo "public JOIN bootstrap manifest has an invalid checksum entry: $expected $path" >&2
      return 1
    }
    actual="$(sha256sum "$tmp/${path#./}" | awk '{print $1}')" || {
      echo "public JOIN bootstrap checksum could not read file=$path bootstrap_url=$BOOTSTRAP_URL" >&2
      return 1
    }
    if [[ "$actual" != "$expected" ]]; then
      printf 'public JOIN bootstrap checksum mismatch bootstrap_url=%s file=%s expected_sha256=%s actual_sha256=%s\n' \
        "$BOOTSTRAP_URL" "$path" "$expected" "$actual" >&2
      return 1
    fi
    checked=$((checked + 1))
  done <"$manifest"
  [[ "$checked" -eq "$required" ]] || {
    echo "public JOIN bootstrap manifest is incomplete: expected_files=$required checked_files=$checked bootstrap_url=$BOOTSTRAP_URL" >&2
    return 1
  }
}
mkdir -p "$tmp/profile"
join_role_stage='download public bootstrap metadata'
for path in manifest.sha256 topology.env profile/genesis.env; do
  curl -fsS --connect-timeout 10 --max-time 60 "$BOOTSTRAP_URL/$path" -o "$tmp/$path"
done

join_role_stage='verify public bootstrap metadata'
if ! grep -E '  \./(topology\.env|profile/genesis\.env)$' "$tmp/manifest.sha256" >"$tmp/required.sha256"; then
  echo 'public JOIN bootstrap manifest lacks topology/profile checksum entries; the endpoint may be serving an error document' >&2
  exit 1
fi
if ! verify_public_checksum "$tmp/required.sha256" 2; then
  echo 'public JOIN bootstrap checksum verification failed; retry only after the Genesis operator republishes one consistent bootstrap' >&2
  exit 1
fi
grep -qx "join_bootstrap_format=$JOIN_BOOTSTRAP_FORMAT" "$tmp/profile/genesis.env" \
  || { echo 'public join bootstrap format is incompatible with this release profile' >&2; exit 1; }
BOOTSTRAP_MANIFEST_SHA256="$(sha256sum "$tmp/manifest.sha256" | awk '{print $1}')"
[[ "$BOOTSTRAP_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'public JOIN bootstrap manifest digest is unavailable' >&2
  exit 1
}

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
join_role_stage='validate public topology'
source "$tmp/topology.env"
if [[ -n "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$("$(dirname "$0")/detect-public-host.sh" "$SSH_ALIAS" "$PUBLIC_HOST")"
fi
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$(topology_value "$GDC_NODE_PUBLIC_HOSTS" "$SSH_ALIAS" || true)"
fi
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$("$(dirname "$0")/detect-public-host.sh" "$SSH_ALIAS")"
fi
if [[ " $GDC_NODE_ALIASES " != *" $SSH_ALIAS "* ]]; then
  GDC_NODE_ALIASES+=" $SSH_ALIAS"
  GDC_NODE_GPU_PROFILES+=" $SSH_ALIAS=auto"
  GDC_NODE_P2P_PORTS+=" $SSH_ALIAS=5000"
fi
updated_public_hosts=''
for mapping in $GDC_NODE_PUBLIC_HOSTS; do
  [[ "${mapping%%=*}" == "$SSH_ALIAS" ]] && continue
  updated_public_hosts+="${updated_public_hosts:+ }$mapping"
done
GDC_NODE_PUBLIC_HOSTS="${updated_public_hosts}${updated_public_hosts:+ }$SSH_ALIAS=$PUBLIC_HOST"
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
join_role_stage='write independent Host role input'
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
  printf 'GDC_JOIN_BOOTSTRAP_MANIFEST_SHA256=%q\n' "$BOOTSTRAP_MANIFEST_SHA256"
  printf 'GDC_DEPLOYMENT_PROFILE=community-lab\n'
  printf 'GDC_OPERATOR_SERVICES_PROFILE=gdc-lab\n'
  printf 'GDC_JOIN_ROLE_INPUT=true\n'
} >"$OUTPUT"
