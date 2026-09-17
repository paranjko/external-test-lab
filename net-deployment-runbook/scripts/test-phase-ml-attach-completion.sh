#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
phase="$ROOT/scripts/phase-ml-attach.sh"

bash -n "$phase"
grep -Fq 'wait-hardware-node.sh' "$phase"
grep -Fq 'capture-deployed-ml-evidence.sh' "$phase"
hardware_line="$(grep -n 'wait-hardware-node.sh' "$phase" | cut -d: -f1)"
completion_line="$(grep -n 'capture-deployed-ml-evidence.sh' "$phase" | cut -d: -f1)"
link_line="$(grep -n 'Record the explicit Network Node' "$phase" | cut -d: -f1)"
(( hardware_line < completion_line && completion_line < link_line )) || {
  echo 'ML completion must follow hardware registration and precede association recording' >&2
  exit 1
}
printf 'PASS ML attach requires a bounded deployed completion before signer activation can continue\n'
