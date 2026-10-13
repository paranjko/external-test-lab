#!/usr/bin/env bash
# Behavioral fixture for a validator lending its installed ML runtime. Every
# SSH/SCP call is allowlisted; this test has no Host, Docker or GDC state.
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
mkdir -p "$kit/scripts" "$kit/03-join" "$tmp/bin" "$tmp/operator/state/ml-attached" "$tmp/operator/donor/state"
cp "$ROOT/scripts/phase-ml-lend.sh" "$kit/scripts/"
cp "$ROOT/scripts/phase-node-lent-start.sh" "$kit/scripts/"
cp "$ROOT/scripts/read-lent-ml-record.sh" "$kit/scripts/"
cp "$ROOT/scripts/add-network-ml-endpoint.sh" "$kit/scripts/"
cp "$ROOT/scripts/remove-network-ml-endpoint.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${GDC_TEST_KIT:?}"
GDC_DATA_ROOT="${GDC_TEST_OPERATOR:?}"
GDC_HOME="$GDC_DATA_ROOT/donor"
init_gdc_paths() { :; }
load_project() { ROOT="${GDC_TEST_KIT:?}"; GDC_DATA_ROOT="${GDC_TEST_OPERATOR:?}"; STATE="$GDC_DATA_ROOT/parent/state"; GDC_HOME="$GDC_DATA_ROOT/parent"; }
topology_contains_node() { [[ "$1" == parent ]]; }
ssh_ready() {
  echo "unexpected duplicate SSH readiness probe: $1" >&2
  exit 93
}
die() { printf '%s\n' "$*" >&2; exit 1; }
step() { printf 'STEP %s\n' "$*" >>"$GDC_TEST_EVENTS"; }
EOF
cat >"$kit/scripts/check-running-network-node.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${GDC_TEST_PARENT_READY:-true}" == true ]] || exit 1
[[ "$1" == parent ]]
printf 'network-ready:%s\n' "$1" >>"$GDC_TEST_EVENTS"
EOF
cat >"$kit/scripts/node-container-control.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_EVENTS"
case "$1" in
  stop) [[ "$#" == 2 && "$2" == donor ]] ;;
  lend) [[ "$#" == 5 && "$2" == donor && "$3" == parent && "$4" == gpu.example.test && "$5" == qwen:parent--donor ]] ;;
  reclaim) [[ "$#" == 2 && "$2" == donor ]] ;;
  start) [[ "$#" == 2 && "$2" == donor ]] ;;
  *) exit 97 ;;
esac
EOF
cat >"$kit/scripts/detach-network-ml-host.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == --network && "$2" == parent && "$3" == --ml-host && "$4" == donor && "$5" == --data-root && "$6" == "$GDC_TEST_OPERATOR" && "$7" == --run-dir && "$8" == /* ]]
[[ "$9" == --expected-endpoint && "${10}" == gpu.example.test && "${11}" == --expected-node-id && "${12}" == qwen:parent--donor ]]
printf 'detach:parent:donor\n' >>"$GDC_TEST_EVENTS"
EOF
cat >"$kit/03-join/start-local-ml.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 8 && "$1" == donor && "$2" == Qwen/Qwen3-0.6B && "$3" == c1899de289a04d12100db370d81485cdf75e47ca ]]
printf 'start-local-ml:%s\n' "$*" >>"$GDC_TEST_EVENTS"
[[ "${GDC_TEST_ML_START_FAIL:-false}" != true ]]
EOF
chmod 0755 "$kit/scripts"/*.sh
chmod 0755 "$kit/03-join/start-local-ml.sh"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
host=''
for arg in "$@"; do
  [[ "$arg" == parent || "$arg" == donor ]] && { host="$arg"; break; }
done
[[ -n "$host" ]] || exit 91
if [[ "$host" == donor && "${GDC_TEST_DONOR_UNREACHABLE:-false}" == true ]]; then
  exit 255
fi
if [[ "$1" == -G ]]; then
  [[ "$2" == donor ]]
  printf 'hostname gpu.example.test\n'
  exit 0
fi
printf '%s|%s\n' "$host" "$args" >>"$GDC_TEST_SSH_LOG"
case "$host:$args" in
  donor:*gdc-lent-ml-record*)
    [[ "${GDC_TEST_RECORD_READ_FAIL:-false}" != true ]] || exit 77
    cat "$GDC_TEST_DONOR_RECORD_FILE"
    ;;
  donor:*'test -s /srv/dai/identity/p2p/node_key.json'*)
    [[ "$args" != *'/srv/dai/deploy/compose.yaml'* ]] || exit 92
    [[ "${GDC_TEST_VALIDATOR_COMPLETE:-true}" == true ]] && exit 0
    exit 1
    ;;
  donor:*'lent-ml.json'*)
    [[ "${GDC_TEST_LEND_RECORD_READ_FAIL:-false}" != true ]] || exit 77
    if [[ "${GDC_TEST_MODE:-lend}" == start || "${GDC_TEST_DONOR_RECORD:-none}" == exact ]]; then cat "$GDC_TEST_DONOR_RECORD_FILE"; else exit 10; fi
    ;;
  donor:*'cat /srv/dai/deploy/node-config.json'*) cat "$GDC_TEST_DONOR_CONFIG" ;;
  parent:*'cat /srv/dai/deploy/node-config.json'*) cat "$GDC_TEST_CONFIG" ;;
  parent:*'getent ahostsv4'*)
    [[ "${GDC_TEST_PARENT_RESOLVES:-true}" == true ]] || exit 7
    printf 'parent-resolved:%s\n' gpu.example.test >>"$GDC_TEST_EVENTS"
    printf '198.51.100.37\n'
    ;;
  parent:*'curl -fsS'*'/v1/models'*)
    [[ "${GDC_TEST_PARENT_REACHABLE:-true}" == true ]] || exit 7
    printf '{"data":[]}'
    ;;
  parent:*'sync-node-config.sh'*)
    [[ "${GDC_TEST_PARENT_SYNC_FAIL:-false}" != true ]] || exit 1
    exit 0
    ;;
  parent:*'rm -rf'*'gdc-ml-lend-'*) exit 0 ;;
  parent:*'admin/v1/nodes'*) printf '[{"node":{"id":"qwen:parent--donor","host":"gpu.example.test","inference_port":5000,"poc_port":5000}}]' ;;
  parent:*'install_path=/srv/dai/deploy/gdc-ml-link.json'*) cat >"$GDC_TEST_WRITTEN_LINK" ;;
  parent:*'gdc-ml-link.json'*) cat "$GDC_TEST_LINK" ;;
  donor:*'lent-ml.json'*) exit 1 ;;
  donor:*'cat /srv/dai/deploy/.node-control/lent-ml.json'*)
    cat "$GDC_TEST_DONOR_RECORD_FILE"
    ;;
  *) echo "unexpected ssh: $host $args" >&2; exit 92 ;;
esac
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SCP_LOG"
[[ "$1" == -q && "$#" == 3 && "$3" == parent:/tmp/gdc-ml-lend-* ]]
EOF
chmod 0755 "$tmp/bin/"*

config="$tmp/node-config.json"
donor_config="$tmp/donor-node-config.json"
link="$tmp/gdc-ml-link.json"
record="$tmp/lent-ml.json"
written_link="$tmp/written-link.json"
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000},{"id":"qwen:parent--other","host":"other.example.test","inference_port":5000,"poc_port":5000}]' >"$config"
printf '%s\n' '{"id":"qwen:donor","host":"inference","models":{"Qwen/Qwen3-0.6B":{"args":["--revision","c1899de289a04d12100db370d81485cdf75e47ca","--dtype","auto","--tensor-parallel-size","1","--max-num-seqs","64","--gpu-memory-utilization","0.85","--max-model-len","2048"]}}}' | jq -s . >"$donor_config"
printf '%s\n' '{"schema_version":2,"validator_alias":"parent","ml_hosts":[{"ssh_alias":"other","endpoint":"other.example.test","node_id":"qwen:parent--other"}]}' >"$link"
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"gpu.example.test","node_id":"qwen:parent--donor","deployment":"/srv/dai/deploy"}' >"$record"

run_lend() {
  local endpoint="${1:-}" reachable="${2:-true}" sync_fail="${3:-false}"
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" \
    GDC_TEST_CONFIG="$config" GDC_TEST_DONOR_CONFIG="$donor_config" GDC_TEST_LINK="$link" GDC_TEST_DONOR_RECORD_FILE="$record" \
    GDC_TEST_WRITTEN_LINK="$written_link" GDC_TEST_EVENTS="$tmp/events" GDC_TEST_SSH_LOG="$tmp/ssh.log" \
    GDC_TEST_SCP_LOG="$tmp/scp.log" GDC_TEST_DONOR_RECORD="${GDC_TEST_DONOR_RECORD:-none}" \
    GDC_TEST_VALIDATOR_COMPLETE="${GDC_TEST_VALIDATOR_COMPLETE:-true}" \
    GDC_TEST_PARENT_READY="${GDC_TEST_PARENT_READY:-true}" \
    GDC_TEST_PARENT_REACHABLE="$reachable" GDC_TEST_PARENT_RESOLVES="${GDC_TEST_PARENT_RESOLVES:-true}" \
    GDC_TEST_LEND_RECORD_READ_FAIL="${GDC_TEST_LEND_RECORD_READ_FAIL:-false}" \
    GDC_TEST_ML_START_FAIL="${GDC_TEST_ML_START_FAIL:-false}" \
    GDC_TEST_PARENT_SYNC_FAIL="$sync_fail" GDC_RUN_ID=fixture-run \
    bash "$kit/scripts/phase-ml-lend.sh" parent "$endpoint" donor
}

has_text() {
  local file="$1" expected="$2"
  [[ "$(<"$file")" == *"$expected"* ]]
}

first_text_line() {
  local file="$1" expected="$2" line number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    [[ "$line" == *"$expected"* ]] && { printf '%s\n' "$number"; return 0; }
  done <"$file"
  return 1
}

# `phase-ml-add` uses an identity marker only to choose the lending path. The
# lending phase must remain the sole full ownership gate: an incomplete
# validator stops before it can control donor containers or touch parent config.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
partial_validator_rc=0
GDC_TEST_VALIDATOR_COMPLETE=false run_lend gpu.example.test >"$tmp/partial-validator.out" 2>&1 || partial_validator_rc=$?
if [[ "$partial_validator_rc" == 0 ]]; then
  echo 'partial validator unexpectedly entered the lending lifecycle' >&2
  exit 1
fi
[[ "$partial_validator_rc" == 195 ]]
has_text "$tmp/partial-validator.out" 'OPERATOR ACTION REQUIRED donor is not an installed validator with a local ML runtime; join or restore it before lending its GPU'
[[ "$(<"$tmp/events")" == $'network-ready:parent\nparent-resolved:gpu.example.test' ]]
[[ ! -s "$tmp/scp.log" ]]

# The one pre-stop donor validation SSH call distinguishes an unreachable Host
# from an incomplete validator.  It must not retry a standalone readiness
# probe or reach the lender/SCP paths.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
donor_unreachable_rc=0
GDC_TEST_DONOR_UNREACHABLE=true run_lend gpu.example.test >"$tmp/donor-unreachable.out" 2>&1 || donor_unreachable_rc=$?
[[ "$donor_unreachable_rc" -eq 195 ]]
has_text "$tmp/donor-unreachable.out" 'OPERATOR ACTION REQUIRED donor is unreachable; restore SSH access and retry'
[[ "$(<"$tmp/events")" == $'network-ready:parent\nparent-resolved:gpu.example.test' ]]
[[ ! -s "$tmp/scp.log" ]]

# An unreadable donor ownership record is not proof that the donor is free.
# Refuse before the controlled stop rather than exposing a runtime that might
# already be lent to a parent whose record could not be read.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
lend_record_rc=0
GDC_TEST_LEND_RECORD_READ_FAIL=true run_lend gpu.example.test >"$tmp/lend-record-read-failure.out" 2>&1 || lend_record_rc=$?
if [[ "$lend_record_rc" -eq 0 ]]; then
  echo 'unreadable donor lending record unexpectedly entered the lending lifecycle' >&2
  exit 1
fi
[[ "$lend_record_rc" -eq 195 ]]
has_text "$tmp/lend-record-read-failure.out" 'OPERATOR ACTION REQUIRED cannot determine whether donor is already lent; leave it unchanged and restore SSH access before retrying'
[[ "$(<"$tmp/events")" == $'network-ready:parent\nparent-resolved:gpu.example.test' ]]
[[ ! -s "$tmp/scp.log" ]]

# A readable record is not enough: malformed ownership must remain an
# actionable refusal before the donor is stopped or parent state changes.
printf '%s\n' '{}' >"$record"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
malformed_record_rc=0
GDC_TEST_DONOR_RECORD=exact run_lend gpu.example.test >"$tmp/lend-record-malformed.out" 2>&1 || malformed_record_rc=$?
[[ "$malformed_record_rc" -eq 195 ]]
has_text "$tmp/lend-record-malformed.out" 'OPERATOR ACTION REQUIRED cannot determine whether donor is already lent; leave it unchanged and repair its retained lending record before retrying'
[[ "$(<"$tmp/events")" == $'network-ready:parent\nparent-resolved:gpu.example.test' ]]
[[ ! -s "$tmp/scp.log" ]]
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"gpu.example.test","node_id":"qwen:parent--donor","deployment":"/srv/dai/deploy"}' >"$record"

# A valid record for another parent or endpoint is a durable ownership
# conflict. It must not stop, reclaim or reconfigure the donor merely because
# the operator selected a new parent/endpoint in this invocation.
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"other-parent","endpoint":"gpu.example.test","node_id":"qwen:other-parent--donor","deployment":"/srv/dai/deploy"}' >"$record"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
other_parent_rc=0
GDC_TEST_DONOR_RECORD=exact run_lend gpu.example.test >"$tmp/lend-other-parent.out" 2>&1 || other_parent_rc=$?
[[ "$other_parent_rc" -eq 195 ]]
has_text "$tmp/lend-other-parent.out" 'OPERATOR ACTION REQUIRED donor is already lent to other-parent; run gdc host start donor before lending it elsewhere'
[[ "$(<"$tmp/events")" == $'network-ready:parent\nparent-resolved:gpu.example.test' ]]
[[ ! -s "$tmp/scp.log" ]]
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"other.example.test","node_id":"qwen:parent--donor","deployment":"/srv/dai/deploy"}' >"$record"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
other_endpoint_rc=0
GDC_TEST_DONOR_RECORD=exact run_lend gpu.example.test >"$tmp/lend-other-endpoint.out" 2>&1 || other_endpoint_rc=$?
[[ "$other_endpoint_rc" -eq 195 ]]
has_text "$tmp/lend-other-endpoint.out" 'OPERATOR ACTION REQUIRED donor is already lent to parent with a different ML endpoint; run gdc host start donor before changing the endpoint'
[[ "$(<"$tmp/events")" == $'network-ready:parent\nparent-resolved:gpu.example.test' ]]
[[ ! -s "$tmp/scp.log" ]]
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"gpu.example.test","node_id":"qwen:parent--donor","deployment":"/srv/dai/deploy"}' >"$record"

: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
run_lend >"$tmp/lend.out"
[[ "$(<"$tmp/events")" == *$'lend donor parent gpu.example.test qwen:parent--donor'* ]]
resolve_line="$(first_text_line "$tmp/events" 'parent-resolved:gpu.example.test')"
lend_line="$(first_text_line "$tmp/events" 'lend donor parent gpu.example.test qwen:parent--donor')"
[[ "$resolve_line" =~ ^[1-9][0-9]*$ && "$lend_line" =~ ^[1-9][0-9]*$ && "$resolve_line" -lt "$lend_line" ]]
backend_line="$(first_text_line "$tmp/events" 'start-local-ml:donor Qwen/Qwen3-0.6B')"
[[ "$backend_line" =~ ^[1-9][0-9]*$ && "$lend_line" -lt "$backend_line" ]]
jq -e '
  .schema_version == 2 and .validator_alias == "parent" and
  ([.ml_hosts[].ssh_alias] | sort) == ["donor", "other"] and
  ([.ml_hosts[] | select(.ssh_alias == "donor")][0].ownership == "lent_validator")
' "$written_link" >/dev/null
jq -e '
  .schema_version == 1 and .kind == "gdc-ml-parent" and
  .network_alias == "parent" and .ml_alias == "donor" and
  .endpoint == "gpu.example.test" and .node_id == "qwen:parent--donor"
' "$tmp/operator/donor/state/ml-parent.json" >/dev/null
jq '. + [{id:"qwen:parent--donor",host:"gpu.example.test",inference_port:5000,poc_port:5000}]' "$config" >"$tmp/config.next"
mv "$tmp/config.next" "$config"

# An exact retained donor record makes repetition a no-op. No new controlled
# stop, lender invocation or parent configuration mutation is allowed.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
GDC_TEST_DONOR_RECORD=exact run_lend gpu.example.test >"$tmp/repeat.out"
has_text "$tmp/repeat.out" 'PASS parent already uses the retained ML runtime of donor'
[[ "$(<"$tmp/events")" == *$'start-local-ml:donor Qwen/Qwen3-0.6B'* && ! -s "$tmp/scp.log" ]]

# A backend startup failure leaves the parent untouched even though the donor
# was deliberately stopped. The caller can inspect or reclaim it; DAPI never
# receives an endpoint that has no inference process behind it.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000},{"id":"qwen:parent--other","host":"other.example.test","inference_port":5000,"poc_port":5000}]' >"$config"
if GDC_TEST_ML_START_FAIL=true run_lend gpu.example.test >"$tmp/backend-failure.out" 2>&1; then
  echo 'backend startup failure unexpectedly changed the parent' >&2
  exit 1
fi
[[ "$(<"$tmp/events")" == *$'lend donor parent gpu.example.test qwen:parent--donor'* ]]
[[ "$(<"$tmp/events")" == *$'start-local-ml:donor Qwen/Qwen3-0.6B'* ]]
[[ ! -s "$tmp/scp.log" ]]

# A route failure occurs after the donor is controlled-stopped but before the
# parent is modified. It is safe to inspect or reclaim; it cannot create a
# second ML controller.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000},{"id":"qwen:parent--other","host":"other.example.test","inference_port":5000,"poc_port":5000}]' >"$config"
if run_lend gpu.example.test false >"$tmp/unreachable.out" 2>&1; then
  echo 'unreachable parent route unexpectedly lent a validator' >&2
  exit 1
fi
has_text "$tmp/unreachable.out" 'no parent endpoint was added'
[[ "$(<"$tmp/events")" == *$'lend donor parent gpu.example.test qwen:parent--donor'* ]]
[[ ! -s "$tmp/scp.log" ]]

# Failure to resolve the selected endpoint on the parent is an early refusal:
# the donor must not be stopped or lent merely because the operator can reach
# its SSH alias.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
unresolved_rc=0
GDC_TEST_PARENT_RESOLVES=false run_lend gpu.example.test >"$tmp/unresolved.out" 2>&1 || unresolved_rc=$?
if [[ "$unresolved_rc" == 0 ]]; then
  echo 'unresolvable parent endpoint unexpectedly lent a validator' >&2
  exit 1
fi
[[ "$unresolved_rc" == 195 ]]
has_text "$tmp/unresolved.out" 'OPERATOR ACTION REQUIRED parent cannot resolve ML endpoint gpu.example.test; provide a parent-reachable --mlnode-peer before lending the donor GPU'
[[ "$(<"$tmp/events")" == 'network-ready:parent' ]]
[[ ! -s "$tmp/scp.log" ]]

# A stopped or unjoined parent is an operator prerequisite. It is refused
# before donor discovery, resolution, records or lifecycle actions.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
parent_not_ready_rc=0
GDC_TEST_PARENT_READY=false run_lend gpu.example.test >"$tmp/parent-not-ready.out" 2>&1 || parent_not_ready_rc=$?
[[ "$parent_not_ready_rc" == 195 ]]
has_text "$tmp/parent-not-ready.out" 'OPERATOR ACTION REQUIRED parent is not a running Network Node with a deployed DAPI endpoint; start or join it before lending a GPU'
[[ ! -s "$tmp/events" && ! -s "$tmp/ssh.log" && ! -s "$tmp/scp.log" ]]

# A parent-side synchronization failure happens after the controlled stop, but
# before DAPI readback or link persistence. The donor remains stopped/lent and
# the parent receives no ownership record that could make two controllers.
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"; : >"$written_link"
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000},{"id":"qwen:parent--other","host":"other.example.test","inference_port":5000,"poc_port":5000}]' >"$config"
if run_lend gpu.example.test true true >"$tmp/sync-failure.out" 2>&1; then
  echo 'parent configuration failure unexpectedly completed a lending transfer' >&2
  exit 1
fi
has_text "$tmp/sync-failure.out" 'prior configuration was restored and donor remains stopped'
[[ "$(<"$tmp/events")" == *$'lend donor parent gpu.example.test qwen:parent--donor'* ]]
[[ ! -s "$written_link" ]]

# Start consults the donor record, never derives a parent, and refuses a
# malformed record before detach/reclaim/start.
run_start() {
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$tmp/operator" \
    GDC_TEST_MODE=start GDC_TEST_DONOR_RECORD_FILE="$record" GDC_TEST_EVENTS="$tmp/events" \
    GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_SCP_LOG="$tmp/scp.log" \
    GDC_TEST_RECORD_READ_FAIL="${GDC_TEST_RECORD_READ_FAIL:-false}" \
    bash "$kit/scripts/phase-node-lent-start.sh" donor
}
: >"$tmp/events"
run_start >"$tmp/start.out"
[[ "$(<"$tmp/events")" == $'detach:parent:donor\nreclaim donor\nstart donor' ]]
printf '%s\n' '{}' >"$record"
: >"$tmp/events"
if run_start >"$tmp/malformed.out" 2>&1; then
  echo 'malformed donor record unexpectedly started a validator' >&2
  exit 1
fi
[[ ! -s "$tmp/events" ]]

# A failed record read is not evidence that lending never happened. Refuse
# before detach, reclaim or local start rather than converting it to an empty
# record and risking concurrent ML controllers.
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"gpu.example.test","node_id":"qwen:parent--donor","deployment":"/srv/dai/deploy"}' >"$record"
: >"$tmp/events"
if GDC_TEST_RECORD_READ_FAIL=true run_start >"$tmp/record-read-failure.out" 2>&1; then
  echo 'unreadable donor lending record unexpectedly started a validator' >&2
  exit 1
fi
has_text "$tmp/record-read-failure.out" 'cannot read the retained ML lending record for donor'
[[ ! -s "$tmp/events" ]]

printf 'PASS validator ML lending preserves parent endpoints, rejects unreachable routing, and reclaims only its recorded parent\n'
