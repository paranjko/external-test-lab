#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s SSH_ALIAS CHAIN_API_URL\n' "$0" >&2
}

[[ $# == 2 ]] || { usage; exit 2; }
NODE="$1"
CHAIN_API="${2%/}"
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { usage; exit 2; }
[[ "$CHAIN_API" =~ ^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$ ]] || { usage; exit 2; }

ssh -T "$NODE" "bash -s -- $(printf '%q' "$CHAIN_API")" <<'REMOTE'
set -Eeuo pipefail

chain_api="${1%/}"
gateway_env=/srv/dai/ops/gateway.env
[[ -r "$gateway_env" ]] || { printf 'READY gateway state is not installed\n'; exit 0; }

set -a
. "$gateway_env"
set +a
if [[ -z "${DEVSHARD_GATEWAY_DATA_VOLUME:-}" ]]; then
  printf 'READY gateway state has no configured managed volume\n'
  exit 0
fi
[[ "${DEVSHARD_GATEWAY_DATA_VOLUME:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
  printf 'ERROR gateway state reset refused: invalid managed volume name\n' >&2
  exit 1
}
if [[ -n "${DEVSHARD_GATEWAY_DATA_VOLUME_NAME:-}" ]]; then
  [[ "$DEVSHARD_GATEWAY_DATA_VOLUME_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    printf 'ERROR gateway state reset refused: invalid exact managed volume name\n' >&2
    exit 1
  }
fi

admin_state="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:18080/v1/admin/devshards \
  -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY")" || {
  printf 'WAIT gateway state reset deferred: admin state unavailable\n' >&2
  exit 0
}
mapfile -t ids < <(jq -r '[.devshards[]?.id | tostring | select(test("^[1-9][0-9]*$"))] | unique[]' <<<"$admin_state")
(( ${#ids[@]} > 0 )) || { printf 'READY gateway state has no runtime to reset\n'; exit 0; }

for id in "${ids[@]}"; do
  escrow="$(curl -fsS --connect-timeout 5 --max-time 15 \
    "$chain_api/productscience/inference/inference/devshard_escrow/$id")" || {
    printf 'WAIT gateway state reset deferred: chain escrow query unavailable id=%s\n' "$id" >&2
    exit 0
  }
  jq -e 'type == "object" and (.found | type == "boolean")' <<<"$escrow" >/dev/null || {
    printf 'WAIT gateway state reset deferred: chain escrow response is invalid id=%s\n' "$id" >&2
    exit 0
  }
  if jq -e '.found == true' <<<"$escrow" >/dev/null; then
    printf 'READY preserve gateway state: chain escrow remains id=%s\n' "$id"
    exit 0
  fi
done

# All persisted runtime IDs are explicitly absent from committed chain state.
# They cannot be resumed: retaining their sessions makes the gateway route
# requests to a historical group.  Delete only the compose-labelled gateway
# volume, never the OPS monitoring, public site, Host, cache, or bot state.
mapfile -t gateway_containers < <(docker ps -aq \
  --filter label=com.docker.compose.project=gdc-ops \
  --filter label=com.docker.compose.service=devshard-gateway)
(( ${#gateway_containers[@]} == 0 )) || docker rm -f "${gateway_containers[@]}" >/dev/null
if [[ -n "${DEVSHARD_GATEWAY_DATA_VOLUME_NAME:-}" ]]; then
  volumes=()
  if docker volume inspect "$DEVSHARD_GATEWAY_DATA_VOLUME_NAME" >/dev/null 2>&1; then
    volume_project="$(docker volume inspect --format '{{index .Labels "com.docker.compose.project"}}' "$DEVSHARD_GATEWAY_DATA_VOLUME_NAME")"
    volume_logical="$(docker volume inspect --format '{{index .Labels "com.docker.compose.volume"}}' "$DEVSHARD_GATEWAY_DATA_VOLUME_NAME")"
    [[ "$volume_project" == gdc-ops && "$volume_logical" == "$DEVSHARD_GATEWAY_DATA_VOLUME" ]] || {
      printf 'ERROR gateway state reset refused: exact volume ownership differs\n' >&2
      exit 1
    }
    volumes+=("$DEVSHARD_GATEWAY_DATA_VOLUME_NAME")
  fi
else
  mapfile -t volumes < <(docker volume ls -q \
    --filter label=com.docker.compose.project=gdc-ops \
    --filter "label=com.docker.compose.volume=$DEVSHARD_GATEWAY_DATA_VOLUME")
fi
if (( ${#volumes[@]} == 0 )); then
  printf 'READY stale gateway containers removed; managed state volume is already absent\n'
  exit 0
fi
(( ${#volumes[@]} == 1 )) || {
  printf 'ERROR gateway state reset refused: ambiguous managed volumes count=%s\n' "${#volumes[@]}" >&2
  exit 1
}
docker volume rm "${volumes[0]}" >/dev/null
printf 'READY reset stale gateway state: every persisted escrow is absent from chain\n'
REMOTE
