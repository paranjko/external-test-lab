#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

state() {
  local file="$1" height="$2" round="$3" step="$4" hash="${5:-}"
  if [[ -n "$hash" ]]; then
    jq -cn --arg height "$height" --arg round "$round" --argjson step "$step" --arg hash "$hash" \
      '{height:$height,round:$round,step:$step,block_id:{hash:$hash,parts:{total:1,hash:("a" * 64)}}}' >"$file"
  else
    jq -cn --arg height "$height" --arg round "$round" --argjson step "$step" \
      '{height:$height,round:$round,step:$step,block_id:null}' >"$file"
  fi
}

state "$tmp/minimum.json" 00042 000 0
state "$tmp/advanced.json" 43 0 -1
"$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$tmp/minimum.json" --observed "$tmp/advanced.json" --fence-height 42 >"$tmp/advanced.out"
jq -e '.state == "non_regressing"' "$tmp/advanced.out" >/dev/null
if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$tmp/minimum.json" --observed "$tmp/minimum.json" --require-advance >"$tmp/no-advance.out" 2>"$tmp/no-advance.err"; then
  echo 'unchanged TMKMS state unexpectedly verified as post-enable advancement' >&2; exit 1
fi
grep -Fq 'did not advance' "$tmp/no-advance.err"
state "$tmp/regressed.json" 41 0 0
if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$tmp/minimum.json" --observed "$tmp/regressed.json" >"$tmp/regressed.out" 2>"$tmp/regressed.err"; then
  echo 'regressing TMKMS state unexpectedly verified' >&2; exit 1
fi
grep -Fq 'TMKMS signing state regressed in height' "$tmp/regressed.err"
state "$tmp/same-tuple-a.json" 42 0 0 "$(printf 'a%.0s' {1..64})"
state "$tmp/same-tuple-b.json" 42 0 0 "$(printf 'b%.0s' {1..64})"
if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$tmp/same-tuple-a.json" --observed "$tmp/same-tuple-b.json" >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
  echo 'conflicting same-tuple TMKMS state unexpectedly verified' >&2; exit 1
fi
grep -Fq 'TMKMS signing state has a conflicting block identity' "$tmp/conflict.err"
if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$tmp/minimum.json" --observed "$tmp/regressed.json" --fence-height 42 >"$tmp/fence.out" 2>"$tmp/fence.err"; then
  echo 'TMKMS state behind signer fence unexpectedly verified' >&2; exit 1
fi
grep -Fq 'TMKMS signing state regressed in height' "$tmp/fence.err"
printf 'PASS TMKMS signing state is exact, monotonic, and fence-bound\n'
