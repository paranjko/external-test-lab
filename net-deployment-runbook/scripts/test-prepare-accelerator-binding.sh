#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$ROOT"
PHASE="$ROOT/scripts/phase-prepare.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "$*" >&2; exit 1; }

mkdir -p "$tmp/root/00-host-prep" "$tmp/root/scripts" "$tmp/run"
sed -n '/^append_accelerator_remote_env()/,/^}/p; /^revalidate_join_accelerator()/,/^}/p' "$PHASE" >"$tmp/helper.sh"
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
RUN="$tmp/run"
ROOT="$tmp/root"
source "$tmp/helper.sh"

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

grep -Fq 'MLNode qualification is still required' "$PROJECT_ROOT/00-host-prep/verify-host.sh"
binding_line="$(grep -n 'revalidate_join_accelerator "\$host" "\$role"' "$PHASE" | cut -d: -f1)"
transfer_line="$(grep -n 'tar -C "\$ROOT/00-host-prep"' "$PHASE" | cut -d: -f1)"
ready_line="$(grep -n 'sudo test -s /etc/gonka/host.env' "$PHASE" | cut -d: -f1)"
(( binding_line < transfer_line && binding_line < ready_line )) \
  || fail 'accelerator binding does not precede transfer and READY shortcut'
printf 'PASS generated AMD accelerator receipt is rebound before Host mutation\n'
