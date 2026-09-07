#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

command -v jq >/dev/null || { echo 'jq is required' >&2; exit 2; }

make_harness() {
  local harness
  harness="$(mktemp -d "$tmp/harness.XXXXXX")"
  mkdir -p "$harness/scripts" "$harness/state/gateway-migrations" "$harness/bin"
  cp "$ROOT/scripts/phase-gateway-migration.sh" "$harness/scripts/phase-gateway-migration.sh"
  cat >"$harness/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
die() { echo "ERROR $*" >&2; exit 1; }
step() { :; }
load_project() {
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  STATE="$GDC_HOME/state"
  GATEWAY_NODE=gateway
  PUBLIC_EDGE_NODE=edge
}
EOF
  cat >"$harness/scripts/phase-ops.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "id=${GDC_GATEWAY_MIGRATION_ID:-}" "project=${GDC_GATEWAY_MIGRATION_TARGET_PROJECT:-}" "port=${GDC_GATEWAY_MIGRATION_TARGET_PORT:-}" "target=$GDC_GATEWAY_VERSION" >>"$GDC_TEST_PHASE_OPS_LOG"
mkdir -p "$GDC_HOME/state/gateway-migrations"
source_version=v4
[[ "$GDC_GATEWAY_VERSION" == v4 ]] && source_version=v5
write_state() {
  printf '%s\n' \
    'schema_version=1' 'phase=preparing' \
    "remote_dir=/srv/dai/ops/gateway-migrations/new-$GDC_GATEWAY_VERSION" \
    "source_version=$source_version" "target_version=$GDC_GATEWAY_VERSION" \
    'source_port=18080' "target_port=${GDC_GATEWAY_MIGRATION_TARGET_PORT:-18085}" \
    "target_project=${GDC_GATEWAY_MIGRATION_TARGET_PROJECT:-new-project}" \
    'target_escrow_id=pending' >"$GDC_HOME/state/gateway-migrations/active.env"
}
write_state
EOF
  chmod +x "$harness/scripts/lib.sh" "$harness/scripts/phase-ops.sh"
  cat >"$harness/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *" status "* ]]; then
  printf '{"phase":"%s"}\n' "$GDC_TEST_REMOTE_PHASE"
else
  exit 0
fi
EOF
  chmod +x "$harness/bin/ssh"
  printf '%s' "$harness"
}

write_completed_state() {
  local home="$1" id="$2" target="${3:-v5}"
  mkdir -p "$home/state/gateway-migrations"
  printf '%s\n' \
    'schema_version=1' 'phase=completed' \
    "remote_dir=/srv/dai/ops/gateway-migrations/$id" \
    'source_version=v4' "target_version=$target" \
    'source_port=18080' 'target_port=18085' 'target_project=old-project' \
    'target_escrow_id=17' >"$home/state/gateway-migrations/active.env"
}

run_prepare() {
  local harness="$1" target="$2"
  GDC_HOME="$harness" PATH="$harness/bin:$PATH" \
    GDC_TEST_REMOTE_PHASE="${GDC_TEST_REMOTE_PHASE:-completed}" \
    GDC_TEST_PHASE_OPS_LOG="$harness/phase-ops.log" \
    "$harness/scripts/phase-gateway-migration.sh" prepare "$target"
}

for target in v5 v4; do
  harness="$(make_harness)"
  write_completed_state "$harness" "old-$target" v5
  old_state="$(<"$harness/state/gateway-migrations/active.env")"
  run_prepare "$harness" "$target" >/dev/null
  archive="$harness/state/gateway-migrations/completed/old-$target/active.env"
  [[ -f "$archive" && "$(<"$archive")" == "$old_state" ]]
  [[ -s "$harness/state/gateway-migrations/active.env" ]]
  [[ "$(<"$harness/state/gateway-migrations/active.env")" != "$old_state" ]]
  grep -Fxq "target=$target" "$harness/phase-ops.log"
  grep -Fxq 'id=' "$harness/phase-ops.log"
done

harness="$(make_harness)"
write_completed_state "$harness" collision v5
mkdir -p "$harness/state/gateway-migrations/completed/collision"
if run_prepare "$harness" v4 >/dev/null 2>"$tmp/collision.err"; then
  echo 'completed archive collision was not fail-closed' >&2
  exit 1
fi
[[ -s "$harness/state/gateway-migrations/active.env" ]]
grep -Fq 'archive already exists' "$tmp/collision.err"
[[ ! -s "$harness/phase-ops.log" ]]

harness="$(make_harness)"
write_completed_state "$harness" unverifiable v5
GDC_TEST_REMOTE_PHASE=prepared
if run_prepare "$harness" v5 >/dev/null 2>"$tmp/unverified.err"; then
  echo 'unverified completed state was not fail-closed' >&2
  exit 1
fi
[[ -s "$harness/state/gateway-migrations/active.env" ]]
grep -Fq 'disagrees with remote state' "$tmp/unverified.err"
[[ ! -e "$harness/state/gateway-migrations/completed/unverifiable" ]]

harness="$(make_harness)"
mkdir -p "$harness/state/gateway-migrations"
printf '%s\n' \
  'schema_version=1' 'phase=preparing' \
  'remote_dir=/srv/dai/ops/gateway-migrations/incomplete-id' \
  'source_version=v4' 'target_version=v5' 'source_port=18080' 'target_port=19085' \
  'target_project=retained-project' 'target_escrow_id=pending' \
  >"$harness/state/gateway-migrations/active.env"
GDC_TEST_REMOTE_PHASE=preparing run_prepare "$harness" v5 >/dev/null
grep -Fxq 'id=incomplete-id' "$harness/phase-ops.log"
grep -Fxq 'project=retained-project' "$harness/phase-ops.log"
grep -Fxq 'port=19085' "$harness/phase-ops.log"

orchestrator="$ROOT/scripts/phase-gateway-migration.sh"
mapfile -t refresh_lines < <(grep -nF '        refresh_target_before_cutover' "$orchestrator" | cut -d: -f1)
mapfile -t window_lines < <(grep -nF '        wait_cutover_window' "$orchestrator" | cut -d: -f1)
[[ "${#refresh_lines[@]}" == 2 && "${#window_lines[@]}" == 2 ]]
pending_line="$(grep -nF "mark '\$remote_dir' cutover_pending" "$orchestrator" | cut -d: -f1)"
install_line="$(grep -nF 'install_route "$target_port" target' "$orchestrator" | head -1 | cut -d: -f1)"
cutover_install_line="$(grep -nF 'install_route "$target_port" target' "$orchestrator" | tail -1 | cut -d: -f1)"
(( refresh_lines[0] < window_lines[0] && window_lines[0] < pending_line ))
(( refresh_lines[1] < window_lines[1] && window_lines[1] < cutover_install_line ))
(( install_line < cutover_install_line ))

printf 'PASS gateway migration completed-cycle rollover and cutover ordering\n'
