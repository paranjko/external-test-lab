#!/usr/bin/env bash
# Offline lower bounds for the observed 32 x 256 PoC workload, not GPU qualification.
set -Eeuo pipefail
[[ $# == 1 ]] || exit 2
jq -e '
  def capacity($flag):
    . as $args | [range(length) | select($args[.] == $flag)] as $positions |
    if ($positions|length) != 1 then error("missing or repeated capacity flag")
    else ($args[$positions[0]+1] | tonumber) end;
  (.primary|keys)==["Qwen/Qwen2.5-7B-Instruct"] and
  (.secondary|keys)==["Qwen/Qwen3-4B-Instruct-2507"] and
  all(.[][]; .args |
    capacity("--max-num-seqs") >= 32 and
    capacity("--max-num-batched-tokens") >= (32*256))
' "$1" >/dev/null || {
  echo 'Profile cannot hold the 32-sequence, 8192-token PoC batch' >&2
  exit 1
}
