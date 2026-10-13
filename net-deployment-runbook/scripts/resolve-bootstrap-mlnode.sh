#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --url HTTPS_URL --run-id RUN_ID --output FILE" >&2
}

url=''
run_id=''
output=''
while (($#)); do
  case "$1" in
    --url) url="${2:-}"; shift 2 ;;
    --run-id) run_id="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]]+$ && -n "$run_id" && -n "$output" ]] || {
  usage
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$(dirname "$output")"
scratch="$(mktemp -d "$(dirname "$output")/.bootstrap-mlnode.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

bootstrap="$scratch/bootstrap.json"
observation="$scratch/observation.json"
components="$scratch/components.json"
"$ROOT/scripts/fetch-network-bootstrap.sh" --url "$url" --output "$bootstrap"
bash "$ROOT/scripts/resolve-bootstrap-software.sh" observation "$bootstrap" "$observation" "$url" "$run_id" ''
bash "$ROOT/scripts/resolve-bootstrap-software.sh" components "$observation" "$components"

temporary="$(mktemp "$(dirname "$output")/.${output##*/}.XXXXXX")"
trap 'rm -rf -- "$scratch"; rm -f -- "$temporary"' EXIT
jq -ceS --arg url "$url" --arg sha "$(sha256sum "$bootstrap" | awk '{print $1}')" '
  .host_envelope as $host |
  {
    schema_version: 1,
    bootstrap: {url: $url, document_sha256: $sha},
    mlnode: {
      image: $host.mlnode_image,
      proxy_image: $host.mlnode_proxy_image,
      model_id: $host.model_id,
      model_revision: $host.model_revision,
      context_length: $host.mlnode_context_length,
      max_num_seqs: $host.mlnode_max_num_seqs,
      gpu_memory_utilization: $host.mlnode_gpu_memory_utilization,
      dtype: $host.mlnode_dtype,
      tensor_parallel_size: $host.mlnode_tensor_parallel_size
    }
  }
  | select(
      (.mlnode.image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$")) and
      (.mlnode.proxy_image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$")) and
      (.mlnode.model_id | type == "string" and length > 0) and
      (.mlnode.model_revision | test("^[a-f0-9]{40}$")) and
      (.mlnode.context_length | type == "number" and . > 0) and
      (.mlnode.max_num_seqs | type == "number" and . > 0) and
      (.mlnode.gpu_memory_utilization | type == "string" and length > 0) and
      (.mlnode.dtype | type == "string" and length > 0) and
      (.mlnode.tensor_parallel_size | type == "number" and . > 0)
    )
' "$components" >"$temporary"
chmod 0600 "$temporary"
mv "$temporary" "$output"
printf 'PASS selected MLNode runtime from Bootstrap declaration receipt=%s\n' "$output"
