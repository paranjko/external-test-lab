#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "$*" >&2; exit 1; }
mkdir -p "$tmp/bin"

# Execute the production run-directory allocator twice under an identical
# timestamp. Attempts must remain isolated so a prior final-success marker can
# never be inherited by a later or concurrent qualification.
allocator="$tmp/allocate-run.sh"
sed -n '/^mkdir -p "\$GDC_HOME\/runs"$/,/^RUN=/p' "$ROOT/scripts/phase-qualify-ml.sh" >"$allocator"
[[ -s "$allocator" ]] || fail 'could not extract qualification run allocator'
date() { printf '20260922T000000Z\n'; }
export GDC_HOME="$tmp/operator-home"
# shellcheck disable=SC1090
source "$allocator"
first_run="$RUN"
printf 'backend=rocm\n' >"$first_run/qualification-success.txt"
# shellcheck disable=SC1090
source "$allocator"
second_run="$RUN"
[[ "$first_run" != "$second_run" ]] || fail 'same-second qualification attempts reused one run directory'
[[ "$first_run" == *-ml-qualification && "$second_run" == *-ml-qualification ]] \
  || fail 'unique qualification run directories lost the discovery suffix'
[[ ! -e "$second_run/qualification-success.txt" ]] \
  || fail 'new qualification attempt inherited a prior final-success marker'

cat >"$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
args="$*"
if [[ "$args" == *'/v1/chat/completions'* ]]; then
  cat >/dev/null
  [[ "${GDC_TEST_ML_MODE:-}" != completion-timeout ]] || exit 7
  printf '%s\n' '{"choices":[{"message":{"content":"GDC_OK"}}]}'
  exit 0
fi
case "$args" in
  *' up -d') [[ "${GDC_TEST_ML_MODE:-}" != up-failure ]] || exit 8 ;;
  *' logs --no-color mlnode')
    if [[ "${GDC_TEST_ML_MODE:-}" == terminal-runtime ]]; then
      printf '%s\n' 'ERROR Failed to load plugin quark_online_quant' 'ERROR EngineCore failed to start.'
    else
      printf '%s\n' 'ERROR Failed to load plugin quark_online_quant' 'INFO startup continues'
    fi ;;
  *' logs --no-color') printf 'retained runtime diagnostics\n' ;;
  *' down') printf 'bounded cleanup\n' ;;
  *'/api/v1/inference/up/status')
    count_file="${GDC_TEST_ML_COUNT:?}"; count=0
    [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
    count=$((count + 1)); printf '%s\n' "$count" >"$count_file"
    if [[ "${GDC_TEST_ML_MODE:-}" == transient-success && "$count" -eq 1 ]]; then exit 7; fi
    if [[ "${GDC_TEST_ML_MODE:-}" == terminal-runtime ]]; then
      printf '%s\n' '{"status":"in_progress","is_starting":true,"is_running":false,"error":null}'
    else
      printf '%s\n' '{"status":"running","is_starting":false,"is_running":true,"error":null}'
    fi ;;
  *'/v1/models') printf '%s\n' '{"data":[{"id":"test/model"}]}' ;;
  *' rocminfo') printf 'gfx-test\n' ;;
  *'python3 -c'*) printf 'hip=6.4 device=gfx-test sum=1024\n' ;;
  *) printf 'unexpected fake docker invocation: %s\n' "$args" >&2; exit 90 ;;
esac
DOCKER
chmod 0755 "$tmp/bin/docker"

run_remote() {
  local mode="$1" work="$tmp/$1"
  mkdir -p "$work/02-node"
  printf '%s\n' AMD_KFD_GROUP_ID=44 AMD_RENDER_GROUP_ID=44 >"$work/.env"
  env PATH="$tmp/bin:$PATH" GDC_TEST_ML_MODE="$mode" GDC_TEST_ML_COUNT="$work/count" \
    ML_QUALIFICATION_TIMEOUT_SECONDS=3 ML_QUALIFICATION_PROBE_TIMEOUT_SECONDS=1 \
    ML_QUALIFICATION_POLL_INTERVAL_SECONDS=1 ML_QUALIFICATION_VLLM_POLL_INTERVAL_SECONDS=1 \
    "$ROOT/scripts/qualify-ml-remote.sh" "$work" "$work/.env" rocm test/model bfloat16 revision 1 1 0.8 2048
}

start=$SECONDS
if output="$(run_remote terminal-runtime 2>&1)"; then fail 'terminal EngineCore failure passed'; fi
(( SECONDS - start < 3 )) || fail 'terminal EngineCore failure did not exit early'
grep -Fq 'terminal EngineCore startup failure' <<<"$output"
grep -Fq 'Failed to load plugin quark_online_quant' "$tmp/terminal-runtime/startup-runtime.log"

run_remote transient-success >/dev/null || fail 'transient endpoint failure did not recover'
jq -e '.is_running == true' "$tmp/transient-success/status.json" >/dev/null
grep -Fq 'hip=6.4 device=gfx-test sum=1024' "$tmp/transient-success/rocm-workload.txt"

if run_remote completion-timeout >/dev/null 2>&1; then fail 'missing completion passed'; fi
[[ ! -e "$tmp/completion-timeout/rocm-info.txt" ]] || fail 'GPU probe ran after completion timeout'
if run_remote up-failure >/dev/null 2>&1; then fail 'Compose up failure passed'; fi
grep -Fq 'retained runtime diagnostics' "$tmp/up-failure/runtime.log"
grep -Fq 'bounded cleanup' "$tmp/up-failure/stop.log"

phase="$ROOT/scripts/phase-qualify-ml.sh"
collection_fragment="$tmp/phase-qualification-collection.fragment"
awk '
  !seen && /^  set \+e$/ { seen=1; in_block=1 }
  in_block && /^done$/ { exit }
  in_block { print }
' "$phase" >"$collection_fragment"
[[ -s "$collection_fragment" ]] || fail 'could not extract phase qualification collection block'

# Execute the production collection/finalization block with transport mocks.
# The mocks populate only files requested by the real rsync allowlist, so a
# removed startup.json include or broadened .env selection fails this test.
collection_harness="$tmp/phase-qualification-collection.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
    'mode="$1"' 'report="$2"' 'SSH_LOG="$3"' 'RSYNC_LOG="$4"' \
    'host=fixture-host' 'remote=/tmp/fixture-qualification' 'qualification_backend=rocm' \
    'MLNODE_GENERIC_IMAGE=example.invalid/mlnode@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'MODEL_ID=test/model' 'MLNODE_DTYPE=bfloat16' 'MODEL_REVISION=revision' \
    'MLNODE_TENSOR_PARALLEL_SIZE=1' 'MLNODE_MAX_NUM_SEQS=1' \
    'MLNODE_GPU_MEMORY_UTILIZATION=0.8' 'MLNODE_CONTEXT_LENGTH=2048' \
    'mkdir -p "$report"' \
    'ssh() {' \
    '  printf "%s\n" "$*" >>"$SSH_LOG"' \
    '  if [[ "$*" == *qualify-ml-remote.sh* && "$mode" == qualification-and-rsync-fail ]]; then return 23; fi' \
    '  return 0' \
    '}' \
    'rsync() {' \
    '  printf "%s\n" "$@" >"$RSYNC_LOG"' \
    '  [[ "$mode" != qualification-and-rsync-fail && "$mode" != rsync-fail ]] || return 71' \
    '  local artifact' \
    '  for artifact in start.log runtime.log stop.log status.json models.json completion.json rocm-info.txt rocm-workload.txt; do' \
    '    [[ "$mode" != missing-artifact || "$artifact" != completion.json ]] || continue' \
    '    printf "fixture\n" >"$report/$artifact"' \
    '  done' \
    '  if printf "%s\n" "$@" | grep -Fxq -- "--include=/startup.json"; then printf "{}\n" >"$report/startup.json"; fi' \
    '  if printf "%s\n" "$@" | grep -Fxq -- "--include=/.env"; then printf "secret\n" >"$report/.env"; fi' \
    '}'
  sed -n '1,$p' "$collection_fragment"
  printf '%s\n' ': >"$report/continued-after-collection"'
} >"$collection_harness"
chmod 0755 "$collection_harness"

run_collection() {
  local mode="$1"
  local report="$tmp/collection-$mode" ssh_log="$tmp/ssh-$mode.log" rsync_log="$tmp/rsync-$mode.log"
  if "$collection_harness" "$mode" "$report" "$ssh_log" "$rsync_log" >"$tmp/$mode.out" 2>"$tmp/$mode.err"; then
    COLLECTION_RC=0
  else
    COLLECTION_RC=$?
  fi
  COLLECTION_REPORT="$report" COLLECTION_SSH_LOG="$ssh_log" COLLECTION_RSYNC_LOG="$rsync_log"
}

run_collection qualification-and-rsync-fail
[[ "$COLLECTION_RC" == 23 ]] || fail "collection failure replaced qualification rc 23 with $COLLECTION_RC"
grep -Fq 'remote diagnostics retained after collection failure' "$tmp/qualification-and-rsync-fail.err"
! grep -Fq "rm -rf '/tmp/fixture-qualification'" "$COLLECTION_SSH_LOG" \
  || fail 'remote diagnostics were removed after collection failure'

run_collection rsync-fail
[[ "$COLLECTION_RC" == 71 ]] || fail "successful qualification ignored rsync rc 71: $COLLECTION_RC"
! grep -Fq "rm -rf '/tmp/fixture-qualification'" "$COLLECTION_SSH_LOG" \
  || fail 'remote diagnostics were removed after rsync failure'

run_collection missing-artifact
[[ "$COLLECTION_RC" == 66 ]] || fail "missing mandatory artifact did not fail with rc 66: $COLLECTION_RC"
grep -Fq 'lacks mandatory artifact completion.json' "$tmp/missing-artifact.err"
! grep -Fq "rm -rf '/tmp/fixture-qualification'" "$COLLECTION_SSH_LOG" \
  || fail 'remote diagnostics were removed after mandatory-artifact failure'

run_collection success
[[ "$COLLECTION_RC" == 0 ]] || fail "complete diagnostic collection failed: $COLLECTION_RC"
[[ -s "$COLLECTION_REPORT/startup.json" ]] || fail 'startup.json was not collected by the production allowlist'
[[ ! -e "$COLLECTION_REPORT/.env" ]] || fail 'Compose .env leaked into qualification evidence'
grep -Fxq -- '--include=/startup.json' "$COLLECTION_RSYNC_LOG"
grep -Fxq -- '--exclude=*' "$COLLECTION_RSYNC_LOG"
grep -Fq "rm -rf '/tmp/fixture-qualification'" "$COLLECTION_SSH_LOG" \
  || fail 'complete diagnostic collection did not clean the remote directory'
[[ -e "$COLLECTION_REPORT/continued-after-collection" ]] \
  || fail 'complete diagnostic collection did not reach the success continuation'
printf 'PASS bounded ML qualification failures and diagnostic retention\n'
