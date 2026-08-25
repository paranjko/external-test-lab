#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

address_a=gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
address_b=gonka1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
runtime_a="$(runtime_id_for_participant "$address_a")"
runtime_b="$(runtime_id_for_participant "$address_b")"

[[ "$runtime_a" == qwen3-0.6b:"$address_a" ]]
[[ "$runtime_b" == qwen3-0.6b:"$address_b" ]]
[[ "$runtime_a" != "$runtime_b" ]]

GDC_HOME="$(mktemp -d)"
init_gdc_paths
init_gdc_data_root
trap 'rm -rf "$GDC_HOME"' EXIT
record_runtime_identity validator-a "$address_a" "$runtime_a"
record_runtime_identity validator-a "$address_a" "$runtime_a"
if GDC_HOME="$GDC_HOME" ROOT="$ROOT" bash -c '
  set -Eeuo pipefail
  source "$ROOT/scripts/lib.sh"
  init_gdc_data_root
  record_runtime_identity validator-b "gonka1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "qwen3-0.6b:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
' >/dev/null 2>&1; then
  echo 'runtime identity collision was accepted' >&2
  exit 1
fi

echo 'PASS runtime identity is stable across independent local inventories'
