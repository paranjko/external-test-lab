#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
# A joining Host qualifies under the release profile it resolved from the
# network bootstrap. The baseline gate belongs to network-owner role inputs.
[[ "${GDC_JOIN_ROLE_INPUT:-false}" == true ]] || assert_baseline_release
record_phase_profile ml-qualification

mkdir -p "$GDC_HOME/runs"
RUN="$(mktemp -d --suffix=-ml-qualification "$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
hosts=("$GENESIS_NODE")
if [[ -n "${GDC_QUALIFY_HOSTS:-}" ]]; then
  read -r -a hosts <<<"$GDC_QUALIFY_HOSTS"
  for host in "${hosts[@]}"; do
    if topology_contains_node "$host"; then
      continue
    fi
    ml_known=false
    for node in "${GDC_NODES[@]}"; do
      [[ "$(node_ml_host "$node" || true)" == "$host" ]] && ml_known=true
    done
    [[ "$ml_known" == true ]] || die "unknown ML qualification host: $host"
  done
fi
for host in "${hosts[@]}"; do
  report="$RUN/$host"
  mkdir -p "$report"
  if ! ssh_ready "$host"; then
    printf 'SKIP  %s unreachable; no ML qualification claim\n' "$host" | tee "$report/verdict.txt"
    continue
  fi
  qualification_backend="${ACCELERATOR_QUALIFICATION_BACKEND:-cuda}"
  printf 'backend=%s\nimage=%s\n' "$qualification_backend" "$MLNODE_GENERIC_IMAGE" >"$report/evidence-contract.txt"
  step "Qualify $host with $MODEL_ID"
  remote="/tmp/gdc-ml-qualification-$$-$host"
  ssh "$host" "rm -rf '$remote' && mkdir -p '$remote'"
  rsync -a "$ROOT/02-node/" "$host:$remote/02-node/"
  scp -q "$ROOT/scripts/qualify-ml-remote.sh" "$host:$remote/qualify-ml-remote.sh"
  env_file="$RUN/$host.env"
  write_env "$env_file" "COMPOSE_PROJECT_NAME=gdc-qualify-${host#gdc-}" "HF_HOME=$HF_CACHE_ROOT" \
    "MLNODE_IMAGE=$MLNODE_GENERIC_IMAGE" "MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE" \
    "AMD_KFD_DEVICE=${AMD_KFD_DEVICE:-}" "AMD_RENDER_DEVICE=${AMD_RENDER_DEVICE:-}" \
    "AMD_KFD_GROUP_ID=${AMD_KFD_GROUP_ID:-}" "AMD_RENDER_GROUP_ID=${AMD_RENDER_GROUP_ID:-}" \
    "POC_BATCH_SIZE_DEFAULT=32"
  scp -q "$env_file" "$host:$remote/.env"
  set +e
  ssh -T "$host" "bash '$remote/qualify-ml-remote.sh' '$remote' '$remote/.env' '$qualification_backend' '$MODEL_ID' '$MLNODE_DTYPE' '$MODEL_REVISION' '$MLNODE_TENSOR_PARALLEL_SIZE' '$MLNODE_MAX_NUM_SEQS' '$MLNODE_GPU_MEMORY_UTILIZATION' '$MLNODE_CONTEXT_LENGTH'"
  qualification_status=$?
  set -e

  # Collection is part of both outcomes. Keep the set filtered so the remote
  # Compose environment (which can contain credentials) is never copied into
  # the evidence directory.
  set +e
  rsync -a --prune-empty-dirs \
    --include='/start.log' --include='/startup.log' --include='/startup-runtime.log' \
    --include='/control.log' --include='/vllm.log' --include='/runtime.log' --include='/stop.log' \
    --include='/status.json' --include='/startup.json' --include='/models.json' --include='/completion.json' \
    --include='/vram.csv' --include='/rocm-info.txt' --include='/rocm-workload.txt' --exclude='*' \
    "$host:$remote/" "$report/"
  collection_status=$?
  cleanup_status=0
  set -e

  if (( qualification_status == 0 && collection_status == 0 )); then
    required_artifacts=(start.log runtime.log stop.log status.json models.json completion.json)
    if [[ "$qualification_backend" == cuda ]]; then
      required_artifacts+=(vram.csv)
    else
      required_artifacts+=(rocm-info.txt rocm-workload.txt)
    fi
    for artifact in "${required_artifacts[@]}"; do
      if [[ ! -s "$report/$artifact" ]]; then
        printf 'FAIL  %s successful qualification lacks mandatory artifact %s\n' "$host" "$artifact" >&2
        collection_status=66
      fi
    done
  fi

  if (( collection_status == 0 )); then
    set +e
    ssh "$host" "rm -rf '$remote'"
    cleanup_status=$?
    set -e
  else
    printf 'WARN  remote diagnostics retained after collection failure: %s:%s\n' "$host" "$remote" >&2
  fi

  if (( qualification_status != 0 )); then
    printf 'FAIL  %s ML qualification exited %d; diagnostics: %s\n' \
      "$host" "$qualification_status" "$report" >&2
    (( collection_status == 0 )) || printf 'WARN  diagnostic collection also exited %d; remote retained at %s:%s\n' "$collection_status" "$host" "$remote" >&2
    (( cleanup_status == 0 )) || printf 'WARN  remote diagnostic cleanup also exited %d\n' "$cleanup_status" >&2
    exit "$qualification_status"
  fi
  if (( collection_status != 0 )); then
    printf 'FAIL  %s ML qualification passed but diagnostic collection exited %d; remote retained at %s:%s\n' \
      "$host" "$collection_status" "$host" "$remote" >&2
    exit "$collection_status"
  fi
  (( cleanup_status == 0 )) || printf 'WARN  remote diagnostic cleanup exited %d\n' "$cleanup_status" >&2
  printf 'backend=%s\nimage=%s\n' "$qualification_backend" "$MLNODE_GENERIC_IMAGE" >"$report/qualification-success.txt"
  printf 'PASS  %s model-load, /v1/models, completion, and %s accelerator evidence: %s\n' "$host" "$qualification_backend" "$report"
done
printf 'PASS ML qualification evidence: %s (unreachable hosts are explicitly recorded without a qualification claim)\n' "$RUN"
