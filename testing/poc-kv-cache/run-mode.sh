#!/usr/bin/env bash
# One mode of the PoC v2 KV cache check on one ML node: record how the node runs, generate PoC vectors for fixed
# inputs, then validate every artifact the run directory holds (this mode and the earlier ones) on this node.
# The ML API is reached through an ssh tunnel; nothing is written on the host and nothing is sent to the chain.
# Usage: run-mode.sh <ssh host> <mode> <run directory>
# Env: GONKA_DIR (gonka-ai/gonka checkout with mlnode/packages/benchmarks), MODEL, SEQ_LEN, K_DIM, NONCES, BATCH, SAMPLE,
# DIST_THRESHOLD, P_MISMATCH, FRAUD_THRESHOLD, BLOCK_HASH, BLOCK_HEIGHT, PUBLIC_KEY, ML_PORT (8080), LOCAL_PORT (18080), FORCE.
set -euo pipefail

host=${1:?ssh host of the ML node}
mode=${2:?mode label, e.g. 1-fp8}
run=${3:?run directory}
here=$(cd "$(dirname "$0")" && pwd)
gonka=${GONKA_DIR:?gonka-ai/gonka checkout}
scripts=$gonka/mlnode/packages/benchmarks/scripts/poc_validation
model=${MODEL:-Qwen/Qwen2.5-7B-Instruct}
seq_len=${SEQ_LEN:-256} k_dim=${K_DIM:-12} nonces=${NONCES:-32} batch=${BATCH:-32} sample=${SAMPLE:-20}
# Chain stat_test of the model; FRAUD_THRESHOLD is the ML node default, the report keeps p_value for any other cutoff.
dist=${DIST_THRESHOLD:-0.4} p_mismatch=${P_MISMATCH:-0.1} fraud=${FRAUD_THRESHOLD:-0.01}
block_hash=${BLOCK_HASH:-poc-kv-cache-check} block_height=${BLOCK_HEIGHT:-1000} public_key=${PUBLIC_KEY:-poc-kv-cache-key}
ml_port=${ML_PORT:-8080} local_port=${LOCAL_PORT:-18080}
url=http://127.0.0.1:$local_port

[[ $mode =~ ^[A-Za-z0-9._-]+$ ]] || { echo "mode must be a plain label" >&2; exit 1; }
[ -f "$scripts/validate.py" ] && [ -f "$scripts/make_artifact.py" ] || { echo "no poc_validation scripts in $gonka" >&2; exit 1; }
dir=$run/$mode
[ ! -e "$dir" ] || { echo "$dir already exists" >&2; exit 1; }
mkdir -p "$dir"
exec > >(tee -a "$dir/run.log") 2>&1
echo "$(date -u +%FT%TZ) mode $mode on $host, gonka $(git -C "$gonka" rev-parse HEAD)"

ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -N -L "$local_port:127.0.0.1:$ml_port" "$host" &
tunnel=$!
trap 'kill $tunnel 2>/dev/null' EXIT
for _ in $(seq 30); do curl -fsS -m 3 "$url/api/v1/state" >/dev/null 2>&1 && break; sleep 1; done

curl -fsS -m 10 "$url/api/v1/state" | tee "$dir/state.json"; echo
curl -fsS -m 10 "$url/api/v1/inference/up/status" > "$dir/up-status.json"
state=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("state"), d.get("poc_status"), d.get("loaded_model"))' "$dir/state.json")
echo "state: $state"
if [ "$state" != "INFERENCE IDLE $model" ] && [ -z "${FORCE:-}" ]; then
  echo "the node is not idle in inference with $model; set FORCE=1 to go on" >&2
  exit 1
fi

# How vLLM runs now: launch arguments, attention backend and KV cache dtype of the latest start, image and GPU.
ssh -o BatchMode=yes "$host" 'c=$(docker ps --format "{{.Names}}" | grep -m1 mlnode)
  echo "container: $c"; docker inspect --format "image: {{.Config.Image}} {{.Image}}" "$c"
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
  docker logs --since 72h "$c" 2>&1 | grep -E "non-default args|attention backend|kv_cache_dtype|Initializing a V1 LLM engine" | tail -n 8' \
  > "$dir/node.txt"
cat "$dir/node.txt"

python3 "$scripts/make_artifact.py" --mlnode-url "$url" --model "$model" --seq-len "$seq_len" --k-dim "$k_dim" \
  --block-hash "$block_hash" --block-height "$block_height" --public-key "$public_key" \
  --num-nonces "$nonces" --batch-size "$batch" --dist-threshold "$dist" --source "mode $mode on $host" \
  --out "$dir/artifact.json"
python3 "$here/compare-vectors.py" --subset "$sample" "$dir/artifact.json" --out "$dir/artifact-sample.json"

# All nonces in one batch repeat the generation; the evenly spread sample is validated in its own batch, as the chain does.
for ref in "$run"/*/artifact.json; do
  from=$(basename "$(dirname "$ref")")
  for variant in all sample; do
    file=$ref
    [ "$variant" = sample ] && file=$(dirname "$ref")/artifact-sample.json
    extra=()
    [ "$variant" = all ] && extra=(--validation-batch-size "$batch")
    echo "== validate $from ($variant) on $mode"
    python3 "$scripts/validate.py" --mlnode-url "$url" --model "$model" --reference "$file" \
      --skip-download --skip-deploy --skip-throughput \
      --threshold "$dist" --p-mismatch "$p_mismatch" --fraud-threshold "$fraud" "${extra[@]}" \
      --exp-dir "$dir/validate-$from-$variant" || echo "validate.py exited $?"
  done
  [ "$from" = "$mode" ] || python3 "$here/compare-vectors.py" --threshold "$dist" "$ref" "$dir/artifact.json" > "$dir/compare-$from.txt"
done

(cd "$run" && find "$mode" -type f ! -name SHA256SUMS ! -name run.log -print0 | sort -z | xargs -0 sha256sum > "$mode/SHA256SUMS")
echo "$(date -u +%FT%TZ) done: $dir"
