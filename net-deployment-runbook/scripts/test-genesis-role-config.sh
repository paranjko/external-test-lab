#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$ROOT/scripts/write-genesis-role-config.sh" \
  --output "$tmp/genesis-input" \
  --ssh-alias gdc-node0 \
  --public-host node0.example.net

source "$tmp/genesis-input"
[[ "$GDC_NODE_ALIASES" == gdc-node0 ]]
[[ "$GDC_NODE_PUBLIC_HOSTS" == gdc-node0=node0.example.net ]]
[[ "$GDC_NODE_GPU_PROFILES" == gdc-node0=auto ]]
[[ "$GDC_NODE_P2P_PORTS" == gdc-node0=5000 ]]
[[ "$GDC_GENESIS_NODE" == gdc-node0 && "$GDC_PUBLIC_EDGE_NODE" == gdc-node0 && "$GDC_GATEWAY_NODE" == gdc-node0 ]]
grep -Fq 'write-genesis-role-config.sh' "$ROOT/gdc.sh"
grep -Fq 'detect-public-host.sh' "$ROOT/scripts/write-genesis-role-config.sh"
grep -Fq 'active-role-config' "$ROOT/gdc.sh"
grep -Fq 'active-role-config' "$ROOT/scripts/lib.sh"
grep -Fq 'detect-gpu-profile.sh' "$ROOT/scripts/phase-genesis.sh"
[[ "$("$ROOT/scripts/detect-gpu-profile.sh" --gpu-name 'NVIDIA RTX A5000' unused)" == a5000-24g ]]
[[ "$("$ROOT/scripts/detect-gpu-profile.sh" --gpu-name 'Tesla T4' unused)" == t4-16g ]]
[[ "$("$ROOT/scripts/detect-gpu-profile.sh" --gpu-name 'NVIDIA RTX PRO 2000 Blackwell' unused)" == blackwell-16g ]]
if "$ROOT/scripts/write-genesis-role-config.sh" --output "$tmp/invalid" --ssh-alias bad --public-host 'not a host'; then
  echo 'Genesis role config accepted an invalid public host' >&2
  exit 1
fi
printf 'PASS explicit Genesis role input contract\n'
