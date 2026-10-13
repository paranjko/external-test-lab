#!/usr/bin/env bash
# Run status readback through its real SSH paths. Standalone readiness probes
# are forbidden because the record, registry and model reads already establish
# availability without changing either Host.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

kit="$tmp/kit"
mkdir -p "$kit/scripts" "$tmp/bin"
cp "$ROOT/scripts/phase-ml-status.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
load_project() { :; }
topology_contains_node() { [[ "$1" == parent ]]; }
ssh_ready() {
  printf 'unexpected standalone readiness probe for %s\n' "$1" >&2
  exit 93
}
die() { printf '%s\n' "$*" >&2; exit 1; }
SH
chmod 0755 "$kit/scripts/lib.sh"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
printf '%s\n' "$args" >>"${GDC_TEST_SSH_LOG:?}"
if [[ "$args" == *'parent'*'gdc-ml-link.json'* ]]; then
  if [[ "${GDC_TEST_PARENT_UNREACHABLE:-false}" == true ]]; then exit 255; fi
  printf '%s\n' '{"schema_version":2,"validator_alias":"parent","ml_hosts":[{"ssh_alias":"donor","endpoint":"gpu.example.test","node_id":"qwen:parent--donor"}]}'
  exit 0
fi
if [[ "$args" == *'parent'*'node-config.json'* ]]; then
  printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000},{"id":"qwen:parent--donor","host":"gpu.example.test","inference_port":5000,"poc_port":5000}]'
  exit 0
fi
if [[ "$args" == *'parent'*'/admin/v1/nodes'* ]]; then
  printf '%s\n' '[{"node":{"id":"qwen:parent--donor","host":"gpu.example.test","inference_port":5000,"poc_port":5000}}]'
  exit 0
fi
if [[ "$args" == *'donor'*'/v1/models'* ]]; then
  if [[ "${GDC_TEST_DONOR_UNREACHABLE:-false}" == true ]]; then exit 255; fi
  printf '%s\n' '{"data":[{"id":"fixture-model"}]}'
  exit 0
fi
printf 'unexpected SSH command: %s\n' "$args" >&2
exit 92
SH
chmod 0755 "$tmp/bin/ssh"

run_status() {
  env PATH="$tmp/bin:$PATH" GDC_TEST_SSH_LOG="$tmp/ssh.log" \
    GDC_TEST_PARENT_UNREACHABLE="${1:-false}" \
    GDC_TEST_DONOR_UNREACHABLE="${2:-false}" \
    bash "$kit/scripts/phase-ml-status.sh" parent
}

: >"$tmp/ssh.log"
run_status false false >"$tmp/ok.out"
[[ "$(wc -l <"$tmp/ssh.log")" -eq 4 ]]
[[ "$(<"$tmp/ok.out")" == *'PASS additional ML endpoint node_id=qwen:parent--donor host=donor'* ]]

: >"$tmp/ssh.log"
rc=0
run_status true false >"$tmp/parent-unreachable.out" 2>&1 || rc=$?
[[ "$rc" == 1 ]]
[[ "$(<"$tmp/parent-unreachable.out")" == *'parent is unreachable'* ]]
[[ "$(wc -l <"$tmp/ssh.log")" -eq 1 ]]

: >"$tmp/ssh.log"
rc=0
run_status false true >"$tmp/unreachable.out" 2>&1 || rc=$?
[[ "$rc" == 1 ]]
[[ "$(<"$tmp/unreachable.out")" == *'additional ML Host donor is unreachable'* ]]
[[ "$(wc -l <"$tmp/ssh.log")" -eq 4 ]]

printf 'PASS ML status uses readback as its only SSH availability check\n'
