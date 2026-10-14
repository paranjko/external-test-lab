#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$ROOT"
PHASE="$ROOT/scripts/phase-prepare.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "$*" >&2; exit 1; }

mkdir -p "$tmp/root/00-host-prep" "$tmp/root/scripts" "$tmp/run"
sed -n '/^RUN=/,/^ready_hosts=/p; /^append_accelerator_remote_env()/,/^}/p; /^revalidate_join_accelerator()/,/^}/p' "$PHASE" >"$tmp/helper.sh"
printf '# inspector is supplied over stdin\n' >"$tmp/root/00-host-prep/inspect-accelerator.sh"
cat >"$tmp/root/scripts/select-accelerator-profile.sh" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  case "$1" in --inspection) inspection="$2"; shift 2;; --output) output="$2"; shift 2;; esac
done
cp "${GDC_TEST_RECEIPT:?}" "$output"
printf 'selected %s\n' "$inspection" >>"${GDC_TEST_CALLS:?}"
EOF
chmod +x "$tmp/root/scripts/select-accelerator-profile.sh"

cat >"$tmp/receipt.json" <<'EOF'
{"schema_version":1,"vendor":"amd","architecture":"gfx1201","pci_device_id":"0x7550","readiness":"ready","compose_variant":"amd","qualification_backend":"rocm"}
EOF
jq -n --slurpfile accelerator "$tmp/receipt.json" '{spec:{target:{accelerator:$accelerator[0]}}}' >"$tmp/profile.json"

ssh() {
  printf 'ssh %s\n' "$*" >>"$GDC_TEST_CALLS"
  printf 'vendor=amd\npci_device_id=0x7550\nreadiness=ready\narchitecture=gfx1201\n'
}
export GDC_TEST_CALLS="$tmp/calls.log" GDC_TEST_RECEIPT="$tmp/receipt.json"
export GDC_JOIN_PROFILE="$tmp/profile.json"
export GDC_HOME="$tmp/home" GDC_RUN_ID=fixture-run
mkdir -p "$GDC_HOME/runs"
ROOT="$tmp/root"
source "$tmp/helper.sh"
[[ "$RUN" == "$GDC_HOME/runs/$GDC_RUN_ID/prepare" ]] || fail "phase preparation chose a non-canonical evidence directory: $RUN"

export ACCELERATOR_VENDOR=amd ACCELERATOR_ARCHITECTURE=gfx1201
for expected_readiness in ready provisioning; do
  export ACCELERATOR_READINESS="$expected_readiness"
  remote_env=()
  append_accelerator_remote_env ml-only
  [[ "${remote_env[*]}" == "GDC_ACCELERATOR_VENDOR='amd' GDC_ACCELERATOR_ARCHITECTURE='gfx1201' GDC_ACCELERATOR_READINESS='$expected_readiness'" ]] \
    || fail "split AMD remote command lost $expected_readiness accelerator fields"
done
unset ACCELERATOR_ARCHITECTURE ACCELERATOR_READINESS

jq 'del(.spec.target.accelerator)' "$tmp/profile.json" >"$tmp/historical.json"
export GDC_JOIN_PROFILE="$tmp/historical.json" ACCELERATOR_VENDOR=nvidia
: >"$GDC_TEST_CALLS"
revalidate_join_accelerator node8 network-gpu || fail 'validated historical NVIDIA profile was rejected'
[[ ! -s "$GDC_TEST_CALLS" ]] || fail 'historical NVIDIA profile triggered accelerator inspection'
unset ACCELERATOR_VENDOR
export GDC_JOIN_PROFILE="$tmp/profile.json"

revalidate_join_accelerator node8 network-gpu || fail 'matching accelerator receipt was rejected'
grep -Fq 'selected ' "$GDC_TEST_CALLS"
[[ -s "$RUN/accelerator-revalidation/node8/inspection.env" ]]
[[ -s "$RUN/accelerator-revalidation/node8/receipt.json" ]]

: >"$GDC_TEST_CALLS"
revalidate_join_accelerator gpu8 ml-only || fail 'matching split ML Host receipt was rejected'
grep -Fq 'ssh -T gpu8 bash -s' "$GDC_TEST_CALLS"
[[ -s "$RUN/accelerator-revalidation/gpu8/receipt.json" ]]

jq '.readiness="provisioning"' "$tmp/receipt.json" >"$tmp/drift.json"
export GDC_TEST_RECEIPT="$tmp/drift.json"
: >"$GDC_TEST_CALLS"
mutation="$tmp/remote-mutation"
ready_shortcut="$tmp/ready-shortcut"
if revalidate_join_accelerator node8 network-gpu; then
  : >"$mutation"
  : >"$ready_shortcut"
fi
[[ ! -e "$mutation" && ! -e "$ready_shortcut" ]] \
  || fail 'receipt drift reached remote preparation or READY shortcut'

# NVIDIA retains its existing behavior for either accelerator-host role.
jq '.spec.target.accelerator.vendor="nvidia"' "$tmp/profile.json" >"$tmp/nvidia.json"
export GDC_JOIN_PROFILE="$tmp/nvidia.json"
: >"$GDC_TEST_CALLS"
revalidate_join_accelerator node8 network-gpu
[[ ! -s "$GDC_TEST_CALLS" ]] || fail 'NVIDIA path was unexpectedly reselected'

grep -Fq 'join_accelerator_alias="${join_gpu_alias:-$join_alias}"' "$PROJECT_ROOT/gdc.sh"
grep -Fq 'ssh -T "$join_accelerator_alias"' "$PROJECT_ROOT/gdc.sh"
grep -Fq 'append_accelerator_remote_env "$role"' "$PHASE"
grep -Fq 'sudo ${remote_env[*]} /tmp/gdc-host-prep/prepare-host.sh' "$PHASE"

# Run the complete production phase in a fresh process with its real lib.sh
# and load_project path. Only SSH and accelerator selection are replaced.
runtime_root="$tmp/runtime-runbook"
phase_source="${GDC_TEST_PHASE_PREPARE_ROOT:-$PROJECT_ROOT}"
mkdir -p "$runtime_root"
cp -a "$phase_source/scripts" "$phase_source/profiles" \
  "$phase_source/00-host-prep" "$phase_source/gdc.sh" "$runtime_root/"
cp -a "$phase_source/../model" "$runtime_root/../model"
exporter="$tmp/export-amd-profile.sh"
awk -v root="$PROJECT_ROOT" -v output="$tmp/runtime-profile.json" '
  /^ROOT=/ { print "ROOT=\"" root "\""; next }
  { print }
  /join-profile.sh.*validate.*amd.json/ {
    print "install -m 0600 \"$tmp/amd.json\" \"" output "\""
    print "exit 0"; exit
  }
' "$PROJECT_ROOT/scripts/test-resolve-join-profile.sh" >"$exporter"
chmod +x "$exporter"
"$exporter" >/dev/null
jq -Sc '.spec.target.accelerator' "$tmp/runtime-profile.json" >"$tmp/runtime-receipt.json"
cat >"$runtime_root/scripts/select-accelerator-profile.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while (($#)); do case "$1" in --inspection) shift 2;; --output) cp "${GDC_TEST_RECEIPT:?}" "$2"; shift 2;; *) exit 2;; esac; done
EOF
chmod +x "$runtime_root/scripts/select-accelerator-profile.sh"
mkdir -p "$tmp/runtime-bin"
cat >"$tmp/runtime-bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GDC_TEST_SSH_LOG:?}"
if [[ " $* " == *' -G '* ]]; then printf 'hostname 192.0.2.8\nport 22\n';
elif [[ " $* " == *' -T '* && "$*" == *'bash -s'* ]]; then printf 'fixture inspection\n'; fi
if [[ "$*" =~ (^|[[:space:]])true$ ]]; then
  echo 'unexpected standalone SSH readiness probe' >&2
  exit 93
fi
if [[ "$*" == *'rm -rf /tmp/gdc-host-prep'* && -n "${GDC_TEST_TRANSFER_SSH_EXIT:-}" ]]; then
  exit "$GDC_TEST_TRANSFER_SSH_EXIT"
fi
if [[ "${GDC_TEST_RETAINED_HOST_PREPARATION:-false}" == true ]]; then
  case "$*" in
    *'sudo test -s /etc/gonka/host.env'*|*'sudo test -L /etc/gonka/host.env'*) exit 1 ;;
  esac
fi
exit 0
EOF
cat >"$tmp/runtime-bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.8 STREAM fixture\n'
EOF
chmod +x "$tmp/runtime-bin/ssh" "$tmp/runtime-bin/getent"

run_phase_process() {
  local name="$1" run_id="$2" ml_hosts="$3" home expected_run receipt_path
  local -a manual_receipts=()
  home="$tmp/$name"
  mkdir -p "$home"
  cat >"$home/role.env" <<EOF
GDC_NODE_ALIASES=node8
GDC_NODE_PUBLIC_HOSTS=node8=192.0.2.8
GDC_NODE_P2P_PORTS=node8=5000
GDC_NODE_ML_HOSTS=$ml_hosts
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_JOIN_ROLE_INPUT=true
GDC_JOIN_NETWORK_HOST=node8
EOF
  phase_env=(env -u RUN -u GDC_RUN_ID PATH="$tmp/runtime-bin:$PATH" GDC_HOME="$home" GDC_DATA_ROOT="$home" GDC_ENV="$home/role.env" GDC_JOIN_PROFILE="$tmp/runtime-profile.json" GDC_PREPARE_HOSTS=node8 GDC_TEST_RECEIPT="$tmp/runtime-receipt.json" GDC_TEST_SSH_LOG="$home/ssh.log")
  [[ "${GDC_TEST_RETAINED_HOST_PREPARATION:-false}" != true ]] \
    || phase_env+=(GDC_TEST_RETAINED_HOST_PREPARATION=true)
  [[ -z "$run_id" ]] || phase_env+=(GDC_RUN_ID="$run_id")
  if ! "${phase_env[@]}" "$runtime_root/scripts/phase-prepare.sh" >"$home/out" 2>"$home/err"; then
    sed -n '1,20p' "$home/err" >&2
    fail "production phase subprocess failed for $name"
  fi
  expected_run="$run_id"
  if [[ -z "$expected_run" ]]; then
    mapfile -t manual_receipts < <(find "$home/runs" -path '*/prepare/accelerator-revalidation/node8/receipt.json' -print)
    ((${#manual_receipts[@]} == 1)) || fail "standalone phase produced an ambiguous receipt set"
    receipt_path="${manual_receipts[0]}"
    [[ "$receipt_path" == "$home"/runs/*-manual/prepare/accelerator-revalidation/node8/receipt.json ]] \
      || fail "standalone phase used a non-canonical manual run path: $receipt_path"
    return 0
  fi
  if [[ -n "$ml_hosts" ]]; then
    [[ -s "$home/runs/$expected_run/prepare/accelerator-revalidation/gpu8/receipt.json" ]] \
      || fail "missing split-process receipt under run $expected_run"
  else
    [[ -s "$home/runs/$expected_run/prepare/accelerator-revalidation/node8/receipt.json" ]] \
      || fail "missing same-host process receipt under run $expected_run"
  fi
  return 0
}
run_phase_process managed-run fixture-run ''
run_phase_process split-run fixture-split 'node8=gpu8'
run_phase_process manual-run '' ''

# Reset removes /srv/dai but retains the host firewall configuration. A JOIN
# must re-run idempotent host preparation in that state instead of requiring
# manual removal of /etc/gonka/host.env.
GDC_TEST_RETAINED_HOST_PREPARATION=true run_phase_process retained-host-preparation fixture-retained ''
case "$(<"$tmp/retained-host-preparation/ssh.log")" in
  *prepare-host.sh*) ;;
  *) fail 'retained Host preparation did not reach the idempotent preparer' ;;
esac
case "$(<"$tmp/retained-host-preparation/out")" in
  *'READY  node8'*) ;;
  *) fail 'retained Host preparation did not complete normally' ;;
esac

# The actual transfer is the only connection used to establish preparation
# availability.  A transport refusal is classified for the requested Host;
# no standalone readiness command may run first or a remote preparer execute.
home="$tmp/transfer-unreachable"; mkdir -p "$home"
cp "$tmp/managed-run/role.env" "$home/role.env"
if env -u RUN PATH="$tmp/runtime-bin:$PATH" GDC_HOME="$home" GDC_DATA_ROOT="$home" \
  GDC_ENV="$home/role.env" GDC_JOIN_PROFILE="$tmp/runtime-profile.json" \
  GDC_PREPARE_HOSTS=node8 GDC_RUN_ID=fixture-transfer-unreachable \
  GDC_TEST_RECEIPT="$tmp/runtime-receipt.json" GDC_TEST_SSH_LOG="$home/ssh.log" \
  GDC_TEST_TRANSFER_SSH_EXIT=255 "$runtime_root/scripts/phase-prepare.sh" \
  >"$home/out" 2>"$home/err"; then
  fail 'production phase accepted an unreachable requested Host'
fi
grep -Fq 'FAILED  node8: SSH is unavailable; cannot prepare the requested Host' "$home/out" \
  || fail 'transport refusal was not classified as requested-Host unavailability'
! grep -Fq ' true' "$home/ssh.log" \
  || fail 'phase preparation opened a standalone readiness connection'
! grep -Fq 'prepare-host.sh' "$home/ssh.log" \
  || fail 'unreachable transfer reached remote Host preparation'
printf 'PASS preparation uses transfer as its SSH availability boundary\n'

# Non-explicit preparation still permits a genuinely unreachable optional
# Host, but a failed transfer must not be disguised as that skip condition.
home="$tmp/optional-unreachable"; mkdir -p "$home"
cp "$tmp/managed-run/role.env" "$home/role.env"
if ! env -u RUN PATH="$tmp/runtime-bin:$PATH" GDC_HOME="$home" GDC_DATA_ROOT="$home" \
  GDC_ENV="$home/role.env" GDC_JOIN_PROFILE="$tmp/runtime-profile.json" \
  GDC_RUN_ID=fixture-optional-unreachable GDC_TEST_RECEIPT="$tmp/runtime-receipt.json" \
  GDC_TEST_SSH_LOG="$home/ssh.log" GDC_TEST_TRANSFER_SSH_EXIT=255 \
  "$runtime_root/scripts/phase-prepare.sh" >"$home/out" 2>"$home/err"; then
  fail 'non-explicit preparation rejected an unreachable optional Host'
fi
grep -Fq 'SKIP  node8 is unreachable' "$home/out" \
  || fail 'optional transport refusal was not recorded as a skip'

home="$tmp/optional-transfer-failure"; mkdir -p "$home"
cp "$tmp/managed-run/role.env" "$home/role.env"
if env -u RUN PATH="$tmp/runtime-bin:$PATH" GDC_HOME="$home" GDC_DATA_ROOT="$home" \
  GDC_ENV="$home/role.env" GDC_JOIN_PROFILE="$tmp/runtime-profile.json" \
  GDC_RUN_ID=fixture-optional-transfer-failure GDC_TEST_RECEIPT="$tmp/runtime-receipt.json" \
  GDC_TEST_SSH_LOG="$home/ssh.log" GDC_TEST_TRANSFER_SSH_EXIT=23 \
  "$runtime_root/scripts/phase-prepare.sh" >"$home/out" 2>"$home/err"; then
  fail 'non-explicit preparation accepted a failed Host-prep transfer'
fi
grep -Fq 'FAILED  node8: cannot transfer host-prep files' "$home/out" \
  || fail 'non-transport transfer failure was not retained as preparation failure'
! grep -Fq 'SKIP  node8 is unreachable' "$home/out" \
  || fail 'non-transport transfer failure was incorrectly classified as unreachable'
printf 'PASS optional Host skip is limited to SSH transport refusal\n'

home="$tmp/drift-home"; mkdir -p "$home"
cp "$tmp/managed-run/role.env" "$home/role.env"
jq '.readiness="provisioning"' "$tmp/runtime-receipt.json" >"$tmp/runtime-drift.json"
if env -u RUN PATH="$tmp/runtime-bin:$PATH" GDC_HOME="$home" GDC_DATA_ROOT="$home" GDC_ENV="$home/role.env" GDC_JOIN_PROFILE="$tmp/runtime-profile.json" GDC_PREPARE_HOSTS=node8 GDC_RUN_ID=fixture-drift GDC_TEST_RECEIPT="$tmp/runtime-drift.json" GDC_TEST_SSH_LOG="$home/ssh.log" "$runtime_root/scripts/phase-prepare.sh" >"$home/out" 2>"$home/err"; then
  fail 'separate phase process accepted a changed accelerator receipt'
fi
! grep -Fq '/tmp/gdc-host-prep' "$home/ssh.log" \
  || fail 'changed receipt reached remote Host preparation or transfer'

grep -Fq 'MLNode qualification is still required' "$PROJECT_ROOT/00-host-prep/verify-host.sh"
binding_line="$(grep -n 'revalidate_join_accelerator "\$host" "\$role"' "$PHASE" | cut -d: -f1)"
transfer_line="$(grep -n 'tar -C "\$ROOT/00-host-prep"' "$PHASE" | cut -d: -f1)"
ready_line="$(grep -n 'sudo test -s /etc/gonka/host.env' "$PHASE" | cut -d: -f1)"
(( binding_line < transfer_line && binding_line < ready_line )) \
  || fail 'accelerator binding does not precede transfer and READY shortcut'
printf 'PASS generated AMD accelerator receipt is rebound before Host mutation\n'
