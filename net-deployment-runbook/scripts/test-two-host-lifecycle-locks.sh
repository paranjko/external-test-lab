#!/usr/bin/env bash
# Exercise the launcher against isolated operator state. ML mutations own the
# parent and donor locks in lexical order; unrelated reset cannot interleave,
# while the remove phase can complete its own nested donor reset.
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

fixture="$tmp/runbook"
mkdir -p "$fixture" "$tmp/bin"
cp "$ROOT/gdc.sh" "$fixture/gdc.sh"
cp -a "$ROOT/scripts" "$ROOT/profiles" "$fixture/"
cp -a "$ROOT/../model" "$fixture/../model"
# This test covers lifecycle ownership at the command boundary. Dedicated
# tests validate manifest construction, so the isolated fixture has no
# release profile dependency.
sed -i 's/ensure_run_manifest "[$]phase"/: # fixture manifest omitted/' "$fixture/gdc.sh"

cat >"$fixture/scripts/phase-ml-add.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'entered\n' >"${GDC_LOCK_TEST_ENTERED:?}"
while [[ ! -e "${GDC_LOCK_TEST_RELEASE:?}" ]]; do sleep 1; done
printf 'add-complete\n' >"${GDC_LOCK_TEST_DONE:?}"
SH
cat >"$fixture/scripts/phase-ml-remove.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
GDC_HOME="$GDC_DATA_ROOT" GDC_INTERNAL_DATA_ROOT="$GDC_DATA_ROOT" \
  "$ROOT/gdc.sh" host reset donor
printf 'remove-complete\n' >"${GDC_LOCK_TEST_DONE:?}"
SH
cat >"$fixture/scripts/phase-node.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == reset && "$2" == donor ]]
printf 'nested-reset\n' >"${GDC_LOCK_TEST_NESTED:?}"
SH
cat >"$fixture/scripts/phase-node-lent-start.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == donor ]]
printf 'entered-start\n' >"${GDC_LOCK_TEST_START_ENTERED:?}"
while [[ ! -e "${GDC_LOCK_TEST_START_RELEASE:?}" ]]; do sleep 1; done
printf 'start-complete\n' >"${GDC_LOCK_TEST_START_DONE:?}"
SH
chmod 0755 "$fixture/scripts/phase-ml-add.sh" "$fixture/scripts/phase-ml-remove.sh" "$fixture/scripts/phase-node.sh" "$fixture/scripts/phase-node-lent-start.sh"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == *'gdc-lent-ml-record'* && "$*" == *' donor '* ]] || exit 91
cat >/dev/null
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"gpu.example.test","node_id":"fixture:parent--donor"}'
SH
chmod 0755 "$tmp/bin/ssh"

operator="$tmp/operator"
mkdir -p "$operator"
cat >"$operator/.env" <<'ENV'
GDC_NODE_ALIASES="parent donor other"
GDC_NODE_PUBLIC_HOSTS="parent=127.0.0.1 donor=127.0.0.1 other=127.0.0.1"
GDC_NODE_P2P_PORTS="parent=5000 donor=5001 other=5002"
ENV

entered="$tmp/entered"
release="$tmp/release"
done_file="$tmp/done"
nested="$tmp/nested"
PATH="$tmp/bin:$PATH" GDC_HOME="$operator" GDC_LOCK_TEST_ENTERED="$entered" GDC_LOCK_TEST_RELEASE="$release" GDC_LOCK_TEST_DONE="$done_file" \
  bash "$fixture/gdc.sh" host setup parent add mlnode donor >"$tmp/add.log" 2>&1 &
add_pid=$!
for _ in $(seq 1 15); do
  [[ -e "$entered" ]] && break
  sleep 1
done
[[ -e "$entered" ]] || { cat "$tmp/add.log" >&2; exit 1; }

rc=0
PATH="$tmp/bin:$PATH" GDC_HOME="$operator" bash "$fixture/gdc.sh" host reset donor >"$tmp/interleaved-reset.log" 2>&1 || rc=$?
[[ "$rc" == 1 ]]
interleaved_log="$(<"$tmp/interleaved-reset.log")"
[[ "$interleaved_log" == *'another lifecycle phase is already running for this operator; wait for it to finish before starting another phase'* ]]
[[ "$(<"$operator/donor/state/.lifecycle.lock.d/pid")" == "$add_pid" ]]

touch "$release"
wait "$add_pid"
[[ "$(<"$done_file")" == add-complete ]]
[[ ! -e "$operator/parent/state/.lifecycle.lock.d" ]]
[[ ! -e "$operator/donor/state/.lifecycle.lock.d" ]]

rm -f -- "$done_file"
PATH="$tmp/bin:$PATH" GDC_HOME="$operator" GDC_LOCK_TEST_DONE="$done_file" GDC_LOCK_TEST_NESTED="$nested" \
  bash "$fixture/gdc.sh" host setup parent remove mlnode donor >"$tmp/remove.log" 2>&1
[[ "$(<"$nested")" == nested-reset ]]
[[ "$(<"$done_file")" == remove-complete ]]
[[ ! -e "$operator/parent/state/.lifecycle.lock.d" ]]
[[ ! -e "$operator/donor/state/.lifecycle.lock.d" ]]

start_entered="$tmp/start-entered"
start_release="$tmp/start-release"
start_done="$tmp/start-done"
PATH="$tmp/bin:$PATH" GDC_HOME="$operator" GDC_LOCK_TEST_START_ENTERED="$start_entered" GDC_LOCK_TEST_START_RELEASE="$start_release" GDC_LOCK_TEST_START_DONE="$start_done" \
  bash "$fixture/gdc.sh" host start donor >"$tmp/start.log" 2>&1 &
start_pid=$!
for _ in $(seq 1 15); do
  [[ -e "$start_entered" ]] && break
  sleep 1
done
[[ -e "$start_entered" ]] || { cat "$tmp/start.log" >&2; exit 1; }
[[ "$(<"$operator/parent/state/.lifecycle.lock.d/pid")" == "$start_pid" ]] || {
  printf 'start did not retain the recorded parent lifecycle lock\n' >&2
  exit 1
}
[[ "$(<"$operator/donor/state/.lifecycle.lock.d/pid")" == "$start_pid" ]] || {
  printf 'start did not retain the donor lifecycle lock\n' >&2
  exit 1
}

rc=0
PATH="$tmp/bin:$PATH" GDC_HOME="$operator" bash "$fixture/gdc.sh" host setup parent add mlnode other >"$tmp/interleaved-add.log" 2>&1 || rc=$?
[[ "$rc" == 1 ]]
interleaved_log="$(<"$tmp/interleaved-add.log")"
[[ "$interleaved_log" == *'another lifecycle phase is already running for this operator; wait for it to finish before starting another phase'* ]]
[[ "$(<"$operator/parent/state/.lifecycle.lock.d/pid")" == "$start_pid" ]]

touch "$start_release"
wait "$start_pid"
[[ "$(<"$start_done")" == start-complete ]]
[[ ! -e "$operator/parent/state/.lifecycle.lock.d" ]]
[[ ! -e "$operator/donor/state/.lifecycle.lock.d" ]]

printf 'PASS paired ML lifecycle locks reject interleaved donor and parent operations while allowing the owned nested reset\n'
