#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "$*" >&2; exit 1; }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib.sh"
# Consumed by the production functions sourced above.
# shellcheck disable=SC2034
GDC_NODES=(node8)
# shellcheck disable=SC2034
MODEL_ID='test/model'
node_data_home() { printf '%s/node8\n' "$tmp"; }
report="$tmp/node8/runs/20260922T000000Z-ml-qualification/node8"
mkdir -p "$report"
printf '%s\n' '{"data":[{"id":"test/model"}]}' >"$report/models.json"
printf '%s\n' '{"choices":[{"message":{"content":"GDC_OK"}}]}' >"$report/completion.json"
printf 'gfx1201\n' >"$report/rocm-info.txt"
printf 'hip=6.4 device=gfx1201 sum=1024\n' >"$report/rocm-workload.txt"
printf 'compose started\n' >"$report/start.log"
printf 'runtime complete\n' >"$report/runtime.log"
printf 'compose stopped\n' >"$report/stop.log"
printf '%s\n' '{"is_running":true,"error":null}' >"$report/status.json"

image='example.invalid/mlnode@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
jq -n --arg image "$image" '{spec:{target:{accelerator:{qualification_backend:"rocm",mlnode_image:$image}}}}' >"$tmp/profile.json"
export GDC_JOIN_PROFILE="$tmp/profile.json"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'marker-absent historical ROCm evidence without image binding was selected'
fi

rm "$report/runtime.log"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'marker-absent ROCm report missing runtime.log was selected'
fi
printf 'runtime complete\n' >"$report/runtime.log"

# New producer-contract reports are unusable until the phase finalizes them,
# and remain unusable if any mandatory runtime diagnostic disappears.
printf 'backend=rocm\nimage=%s\n' "$image" >"$report/evidence-contract.txt"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'all-files-present but unfinalized current ROCm report was selected'
fi
printf 'backend=rocm\nimage=%s\n' "$image" >"$report/qualification-success.txt"
[[ "$(latest_ml_qualification_report node8)" == "$report" ]] \
  || fail 'complete finalized ROCm report was not selected'
rm "$report/runtime.log"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'finalized ROCm report missing runtime.log was selected'
fi
printf 'runtime complete\n' >"$report/runtime.log"

sed 's/aaaaaaaa/bbbbbbbb/' "$tmp/profile.json" >"$tmp/wrong-image.json"
export GDC_JOIN_PROFILE="$tmp/wrong-image.json"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'ROCm evidence from a different MLNode digest was selected'
fi
export GDC_JOIN_PROFILE="$tmp/profile.json"

rm "$report/rocm-workload.txt"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'ROCm evidence missing its workload proof was selected'
fi
printf 'hip=6.4 device=gfx1201 sum=1024\n' >"$report/rocm-workload.txt"
printf 'unexpected CUDA evidence\n' >"$report/vram.csv"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'mixed or wrong-backend evidence was selected for ROCm'
fi

jq -n --arg image "$image" '{spec:{target:{accelerator:{qualification_backend:"cuda"}},deployment:{host_envelope:{mlnode_image:$image}}}}' >"$tmp/profile.json"
rm "$report/rocm-info.txt" "$report/rocm-workload.txt"
printf 'backend=cuda\nimage=%s\n' "$image" >"$report/evidence-contract.txt"
printf 'backend=cuda\nimage=%s\n' "$image" >"$report/qualification-success.txt"
[[ "$(latest_ml_qualification_report node8)" == "$report" ]] \
  || fail 'complete CUDA evidence was not selected'
require_ml_qualification node8

printf 'gfx1201\n' >"$report/rocm-info.txt"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'ROCm evidence was accepted beside CUDA evidence'
fi
rm "$report/rocm-info.txt"

# Validated historical v1 profiles have no accelerator object. Their profile
# loader supplies the CUDA binding; an accelerator object that is present but
# malformed must not use this compatibility path.
rm "$report/evidence-contract.txt" "$report/qualification-success.txt"
jq -n --arg image "$image" '{spec:{target:{},deployment:{host_envelope:{mlnode_image:$image}}}}' >"$tmp/profile.json"
export ACCELERATOR_QUALIFICATION_BACKEND=cuda
[[ "$(latest_ml_qualification_report node8)" == "$report" ]] \
  || fail 'validated legacy CUDA profile did not select complete historical CUDA evidence'
printf 'backend=cuda\nimage=%s\n' "$image" >"$report/evidence-contract.txt"
printf 'backend=cuda\nimage=%s\n' "$image" >"$report/qualification-success.txt"
[[ "$(latest_ml_qualification_report node8)" == "$report" ]] \
  || fail 'new finalized evidence under a legacy CUDA profile was not selected'
printf 'backend=cuda\nimage=example.invalid/wrong@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' \
  >"$report/qualification-success.txt"
if latest_ml_qualification_report node8 >/dev/null; then
  fail 'legacy CUDA profile accepted finalized evidence from the wrong image'
fi
rm "$report/evidence-contract.txt" "$report/qualification-success.txt"
jq -n '{spec:{target:{accelerator:{}}}}' >"$tmp/profile.json"
if (latest_ml_qualification_report node8) >"$tmp/malformed.out" 2>"$tmp/malformed.err"; then
  fail 'malformed fresh accelerator profile used the legacy CUDA fallback'
fi
grep -Fq 'lacks an accelerator qualification backend' "$tmp/malformed.err"
printf 'PASS ML qualification evidence follows the generated accelerator backend\n'
