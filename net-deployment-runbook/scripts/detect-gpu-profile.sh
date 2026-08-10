#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 [--gpu-name NAME] SSH_ALIAS" >&2; }

gpu_name=''
if [[ "${1:-}" == --gpu-name ]]; then
  gpu_name="${2:-}"
  shift 2
fi
[[ $# -eq 1 ]] || { usage; exit 2; }
host="$1"
[[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid SSH alias' >&2; exit 2; }
if [[ -z "$gpu_name" ]]; then
  gpu_name="$(ssh "$host" 'nvidia-smi --query-gpu=name --format=csv,noheader' | head -n 1)"
fi

case "$gpu_name" in
  *A5000*) printf 'a5000-24g\n' ;;
  *"RTX 4090"*) printf '4090-24g\n' ;;
  *"RTX 3090"*) printf '3090-24g\n' ;;
  *"Tesla T4"*|*"NVIDIA T4"*) printf 't4-16g\n' ;;
  *"RTX PRO 2000 Blackwell"*|*"RTX PRO 6000 Blackwell"*|*"RTX 5090"*) printf 'blackwell-16g\n' ;;
  *)
    printf 'unsupported GPU for the pinned Community DevNet profile: %s\n' "$gpu_name" >&2
    exit 1
    ;;
esac
