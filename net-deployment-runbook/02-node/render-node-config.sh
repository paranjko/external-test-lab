#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --node-name SSH_ALIAS --runtime-id ID [--ml-host HOST] [--ml-poc-port PORT] --output FILE" >&2; }
NODE=''; RUNTIME_ID=''; ML_HOST='inference'; ML_POC_PORT=8080; OUTPUT=''
while (($#)); do case "$1" in
  --node-name) NODE="$2"; shift 2 ;;
  --runtime-id) RUNTIME_ID="$2"; shift 2 ;;
  --ml-host) ML_HOST="$2"; shift 2 ;;
  --ml-poc-port) ML_POC_PORT="$2"; shift 2 ;;
  --output) OUTPUT="$2"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ "$NODE" =~ ^[A-Za-z0-9._-]+$ && "$RUNTIME_ID" =~ ^qwen3-0\.6b:gonka1[0-9a-z]{20,90}$ && -n "$OUTPUT" && "$ML_POC_PORT" =~ ^[1-9][0-9]{0,4}$ && "$ML_POC_PORT" -le 65535 ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
load_profiles
SOURCE="$ROOT/02-node/node-config-qwen3-0.6B.source.json"
mkdir -p "$(dirname "$OUTPUT")"
jq --arg id "$RUNTIME_ID" --arg host "$ML_HOST" --argjson poc_port "$ML_POC_PORT" --arg model "$MODEL_ID" \
  --arg revision "$MODEL_REVISION" --argjson max "$MLNODE_MAX_NUM_SEQS" \
  --arg util "$MLNODE_GPU_MEMORY_UTILIZATION" --argjson context "$MLNODE_CONTEXT_LENGTH" '
  .[0].id = $id
  | .[0].host = $host
  | .[0].poc_port = $poc_port
  | .[0].max_concurrent = $max
  | .[0].models as $models | .[0].models = {($model): $models["Qwen/Qwen3-0.6B"]}
  | (.[0].models[$model].args | index("--revision")) as $revision_index
  | (.[0].models[$model].args | index("--max-num-seqs")) as $seq
  | (.[0].models[$model].args | index("--gpu-memory-utilization")) as $util_index
  | (.[0].models[$model].args | index("--max-model-len")) as $context_index
  | .[0].models[$model].args[$revision_index + 1] = $revision
  | .[0].models[$model].args[$seq + 1] = ($max | tostring)
  | .[0].models[$model].args[$util_index + 1] = ($util | tostring)
  | .[0].models[$model].args[$context_index + 1] = ($context | tostring)
' "$SOURCE" >"$OUTPUT"
echo "$OUTPUT"
