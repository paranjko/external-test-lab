#!/usr/bin/env bash
# Exercise the real ownership discriminator before either ML lifecycle path
# can mutate a Host. An installed validator must lend; a clean partial ML-only
# deployment must reach its preparation path without needing a not-yet-copied
# staging installer.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  if [[ "${GDC_TEST_KEEP_TMP:-false}" == true ]]; then
    printf 'KEEP_TEST_TMP=%s\n' "$tmp" >&2
  else
    rm -rf -- "$tmp"
  fi
}
trap cleanup EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$tmp/bin" "$tmp/operator"
cp "$ROOT/scripts/phase-ml-add.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${GDC_TEST_KIT:?}"
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  GDC_DATA_ROOT="${GDC_TEST_OPERATOR:?}"
  GDC_HOME="$GDC_DATA_ROOT"
  STATE="$GDC_DATA_ROOT/state"
  HF_CACHE_ROOT=/srv/hf-cache
}
topology_contains_node() { [[ "$1" == parent ]]; }
ssh_ready() {
  echo "unexpected duplicate SSH readiness probe: $1" >&2
  exit 93
}
die() { printf '%s\n' "$*" >&2; exit 1; }
step() { printf 'step:%s\n' "$*" >>"$GDC_TEST_EVENTS"; }
network_bootstrap_url() { printf 'https://bootstrap.example.test/bootstrap.json\n'; }
node_public_host() { [[ "$1" == parent ]]; printf 'parent.example.test\n'; }
write_env() { :; }
SH

cat >"$kit/scripts/check-running-network-node.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == parent ]]
printf 'parent-ready\n' >>"$GDC_TEST_EVENTS"
SH
cat >"$kit/scripts/phase-ml-lend.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == parent && "$2" == "" && "$3" == donor ]]
printf 'lend-dispatched\n' >>"$GDC_TEST_EVENTS"
SH
cat >"$kit/scripts/resolve-bootstrap-mlnode.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]]
printf '%s\n' '{"mlnode":{"image":"registry.example/ml@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proxy_image":"registry.example/proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","model_id":"fixture-model","model_revision":"fixture-revision","context_length":1,"max_num_seqs":1,"gpu_memory_utilization":"0.1","dtype":"auto","tensor_parallel_size":1}}' >"$output"
printf 'bootstrap-resolved\n' >>"$GDC_TEST_EVENTS"
SH
cat >"$kit/scripts/verify-bootstrap-mlnode-parent.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'parent-image-verified\n' >>"$GDC_TEST_EVENTS"
SH
cat >"$kit/scripts/add-network-ml-endpoint.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
input=''; output=''; id=''
while (($#)); do
  case "$1" in
    --input) input="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --id-output) id="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$input" "$output"
printf 'fixture:parent--donor\n' >"$id"
SH
cat >"$kit/scripts/phase-prepare.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ml-only-prepare-reached\n' >>"$GDC_TEST_EVENTS"
exit 42
SH
chmod 0755 "$kit/scripts"/*.sh
# phase-ml-add dispatches this phase through Bash. The installed runbook must
# not depend on an executable bit being retained for the lending script.
chmod 0644 "$kit/scripts/phase-ml-lend.sh"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
printf '%s\n' "$args" >>"$GDC_TEST_SSH_LOG"
if [[ "$args" == *'identity_root=/srv/dai/identity'* ]]; then
  case "${GDC_TEST_DONOR_KIND:?}" in
    installed) exit 0 ;;
    clean) exit 10 ;;
    unsafe) exit 11 ;;
    *) exit 99 ;;
  esac
fi
if [[ "$args" == *'test ! -e /srv/dai/identity/p2p/node_key.json'* ]]; then
  # The partial ML-only check must not need a staging installer before the
  # phase creates and populates that directory.
  [[ "$args" != *'/02-node/ml-only/install-ml.sh'* ]] || exit 91
  exit 0
fi
if [[ "$args" == *'test -s /srv/dai/deploy/compose.yaml'* || "$args" == *'test -d /srv/dai/signer/tmkms'* ]]; then
  echo "ownership dispatch repeated the lending safety gate: $args" >&2
  exit 93
fi
if [[ "$args" == *"docker inspect"* ]]; then
  printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  exit 0
fi
if [[ "$args" == *'cat /srv/dai/deploy/node-config.json'* ]]; then
  printf '%s\n' '[{"id":"fixture:parent","host":"inference","inference_port":5000,"poc_port":5000}]'
  exit 0
fi
printf 'unexpected ssh command: %s\n' "$args" >&2
exit 92
SH
chmod 0755 "$tmp/bin/ssh"

run_phase() {
  local donor_kind="$1" endpoint="$2" output="$3"
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" \
    GDC_TEST_EVENTS="$tmp/events" GDC_TEST_SSH_LOG="$tmp/ssh.log" \
    GDC_TEST_DONOR_KIND="$donor_kind" GDC_RUN_ID=fixture-run \
    bash "$kit/scripts/phase-ml-add.sh" parent "$endpoint" donor >"$output" 2>&1
}

has_line() {
  local file="$1" expected="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$expected" ]] && return 0
  done <"$file"
  return 1
}

has_text() {
  local file="$1" expected="$2"
  [[ "$(<"$file")" == *"$expected"* ]]
}

: >"$tmp/events"; : >"$tmp/ssh.log"
run_phase installed '' "$tmp/installed.out"
has_line "$tmp/events" 'lend-dispatched'
! has_line "$tmp/events" 'parent-ready'
! has_text "$tmp/ssh.log" 'parent'
! has_text "$tmp/events" 'bootstrap-resolved'

: >"$tmp/events"; : >"$tmp/ssh.log"
if run_phase clean '' "$tmp/clean-without-endpoint.out"; then
  echo 'a clean ML-only Host unexpectedly bypassed the explicit endpoint requirement' >&2
  exit 1
fi
has_text "$tmp/clean-without-endpoint.out" 'ml add requires --mlnode-peer for a new ML-only Host'
has_line "$tmp/events" 'parent-ready'
! has_text "$tmp/events" 'lend-dispatched'
! has_text "$tmp/events" 'bootstrap-resolved'

: >"$tmp/events"; : >"$tmp/ssh.log"
rc=0
run_phase clean ml.example.test "$tmp/partial-clean.out" || rc=$?
[[ "$rc" == 42 ]]
has_line "$tmp/events" 'bootstrap-resolved'
has_line "$tmp/events" 'parent-image-verified'
has_line "$tmp/events" 'ml-only-prepare-reached'
! has_text "$tmp/events" 'lend-dispatched'
! has_text "$tmp/ssh.log" '/02-node/ml-only/install-ml.sh'

# An unsafe residual identity must not be treated as a new ML-only Host or
# delegated into lending. The phase exposes a bounded operator action instead.
: >"$tmp/events"; : >"$tmp/ssh.log"
rc=0
run_phase unsafe ml.example.test "$tmp/unsafe.out" || rc=$?
[[ "$rc" == 195 ]]
has_text "$tmp/unsafe.out" 'cannot safely classify donor as a validator or ML-only Host'
[[ ! -s "$tmp/events" ]]

# A retained ML-only attachment is operator state, not permission to attach
# the Host again. A symlinked record must stop before bootstrap resolution,
# preparation or any remote deployment action.
mkdir -p "$tmp/operator/donor/state"
ln -s missing "$tmp/operator/donor/state/ml-parent.json"
: >"$tmp/events"; : >"$tmp/ssh.log"
rc=0
run_phase clean ml.example.test "$tmp/unsafe-attachment.out" || rc=$?
[[ "$rc" == 195 ]]
has_text "$tmp/unsafe-attachment.out" 'cannot safely read the ML attachment record for donor'
has_line "$tmp/events" 'parent-ready'
! has_text "$tmp/events" 'bootstrap-resolved'
! has_text "$tmp/events" 'ml-only-prepare-reached'
rm -f "$tmp/operator/donor/state/ml-parent.json"

printf 'PASS ML add keeps installed validator lending separate from clean partial ML-only provisioning\n'
