#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
record_phase_profile ml-qualification

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-ml-qualification"
mkdir -p "$RUN"
hosts=(gdc-node0 gdc-node1 gdc-node2 gdc-node3 gdc-node4-ml)
if [[ -n "${GDC_QUALIFY_HOSTS:-}" ]]; then
  read -r -a hosts <<<"$GDC_QUALIFY_HOSTS"
  for host in "${hosts[@]}"; do
    case "$host" in gdc-node0|gdc-node1|gdc-node2|gdc-node3|gdc-node4-ml) ;; *) die "unknown ML qualification host: $host" ;; esac
  done
fi
for host in "${hosts[@]}"; do
  report="$RUN/$host"
  mkdir -p "$report"
  if host_is_skipped "$host"; then
    printf 'SKIP  %s excluded by GDC_SKIP_HOSTS; no ML qualification claim\n' "$host" | tee "$report/verdict.txt"
    continue
  fi
  if ! ssh_ready "$host"; then
    printf 'SKIP  %s unreachable; no ML qualification claim\n' "$host" | tee "$report/verdict.txt"
    continue
  fi
  case "$host" in
    gdc-node0) profile="$NODE0_GPU_PROFILE"; image="$MLNODE_GENERIC_IMAGE" ;;
    gdc-node1) profile="$NODE1_GPU_PROFILE"; image="$MLNODE_GENERIC_IMAGE" ;;
    gdc-node2) profile="$NODE2_GPU_PROFILE"; image="$MLNODE_GENERIC_IMAGE" ;;
    gdc-node3) profile="$NODE3_GPU_PROFILE"; image="$MLNODE_GENERIC_IMAGE" ;;
    gdc-node4-ml) profile="$NODE4_GPU_PROFILE"; image="$MLNODE_BLACKWELL_IMAGE" ;;
  esac
  attention_backend="$(attention_backend_for_profile "$profile")"
  step "Qualify $host ($profile) with $MODEL_ID"
  remote="/tmp/gdc-ml-qualification-$$-$host"
  ssh "$host" "rm -rf '$remote' && mkdir -p '$remote'"
  rsync -a "$ROOT/02-node/" "$host:$remote/02-node/"
  scp -q "$ROOT/scripts/qualify-ml-remote.sh" "$host:$remote/qualify-ml-remote.sh"
  env_file="$RUN/$host.env"
  write_env "$env_file" "COMPOSE_PROJECT_NAME=gdc-qualify-${host#gdc-}" "HF_HOME=$HF_CACHE_ROOT" \
    "MLNODE_IMAGE=$image" "MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE" \
    "VLLM_ATTENTION_BACKEND=$attention_backend" "POC_BATCH_SIZE_DEFAULT=32"
  scp -q "$env_file" "$host:$remote/.env"
  ssh -T "$host" "bash '$remote/qualify-ml-remote.sh' '$remote' '$remote/.env' '$MODEL_ID' '$MLNODE_DTYPE' '$MODEL_REVISION' '$MLNODE_TENSOR_PARALLEL_SIZE' '$MLNODE_MAX_NUM_SEQS' '$MLNODE_GPU_MEMORY_UTILIZATION' '$MLNODE_CONTEXT_LENGTH'"
  scp -q "$host:$remote/status.json" "$report/status.json"
  scp -q "$host:$remote/models.json" "$report/models.json"
  scp -q "$host:$remote/completion.json" "$report/completion.json"
  scp -q "$host:$remote/vram.csv" "$report/vram.csv"
  ssh "$host" "rm -rf '$remote'"
  printf 'PASS  %s model-load, /v1/models, completion, and VRAM evidence: %s\n' "$host" "$report"
done
printf 'PASS ML qualification evidence: %s (SKIP hosts are explicitly recorded)\n' "$RUN"
