#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo $0 HF_CACHE_ROOT MLNODE_IMAGE MODEL_SOURCE_ID MODEL_SOURCE_REVISION [HF_API_KEY]" >&2
}

[[ $# -ge 4 && $# -le 5 ]] || { usage; exit 2; }
cache_root="$1"
image="$2"
model="$3"
revision="$4"
api_key="${5:-}"

[[ "$cache_root" == /* && "$cache_root" != / ]] || { usage; exit 2; }
[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { usage; exit 2; }
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { usage; exit 2; }

# Reuse the deployed MLNode cache on either supported storage layout.
# Multiple different mounts are ambiguous: do not choose an arbitrary one.
ml_ids=$(docker ps -q --filter label=com.docker.compose.service=mlnode)
if [[ -n "$ml_ids" ]]; then
  mapfile -t ml_containers <<<"$ml_ids"
  mounts=$(docker inspect "${ml_containers[@]}")
  cache_root=$(jq -er '[.[].Mounts[] | select(.Destination == "/root/.cache" and .Type == "bind") | .Source] | unique | if length == 1 then .[0] else error("ambiguous or missing deployed MLNode cache") end' <<<"$mounts")
  [[ "$cache_root" == /* && "$cache_root" != / && -d "$cache_root" ]] || exit 2
fi

install -d -m 0755 "$cache_root"
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >&2

# This is intentionally a one-shot CPU-only container. The cache bind is the
# same location that the MLNode Compose service mounts at /root/.cache.
token_args=()
[[ -z "$api_key" ]] || token_args=(--env "HF_TOKEN=$api_key")
docker run --rm -i --pull never --network host \
  --env HF_HOME=/root/.cache \
  "${token_args[@]}" \
  --volume "$cache_root:/root/.cache" \
  --entrypoint python3 "$image" - "$model" "$revision" <<'PY'
import json
import sys
from huggingface_hub import snapshot_download

model, revision = sys.argv[1:]
snapshot = snapshot_download(repo_id=model, revision=revision)
print(json.dumps({"model": model, "revision": revision, "snapshot": snapshot}, sort_keys=True))
PY
