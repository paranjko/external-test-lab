#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

[[ -n "${GDC_PREFETCH_HOST:-}" ]] || die 'prefetch-ml requires one inventory node'
record_phase_profile ml-prefetch

host="$GDC_PREFETCH_HOST"
if ! ssh_ready "$host"; then
  die "ML prefetch host is unreachable: $host"
fi

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-ml-prefetch"
mkdir -p "$RUN"
remote="/tmp/gdc-ml-prefetch-$$-$host"
trap 'ssh "$host" "rm -rf '\''$remote'\''" >/dev/null 2>&1 || true' EXIT

step "Prefetch $MODEL_SOURCE_ID@$MODEL_SOURCE_REVISION on $host"
ssh "$host" "rm -rf '$remote' && mkdir -p '$remote'"
scp -q "$ROOT/scripts/prefetch-ml-remote.sh" "$host:$remote/prefetch-ml-remote.sh"
ssh -T "$host" "sudo bash '$remote/prefetch-ml-remote.sh' '$HF_CACHE_ROOT' '$MLNODE_GENERIC_IMAGE' '$MODEL_SOURCE_ID' '$MODEL_SOURCE_REVISION' '${HF_API_KEY:-}'" \
  | tee "$RUN/$host.json"
jq -e --arg model "$MODEL_SOURCE_ID" --arg revision "$MODEL_SOURCE_REVISION" \
  '.model == $model and .revision == $revision and (.snapshot | type == "string" and length > 0)' \
  "$RUN/$host.json" >/dev/null || die 'ML prefetch did not return a matching immutable snapshot receipt'
printf 'PASS ML weights prefetched without starting inference: %s\n' "$RUN/$host.json"
