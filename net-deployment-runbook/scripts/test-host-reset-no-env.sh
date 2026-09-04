#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -Fq 'if [[ "$CLEAR_EDGE" == true ]]; then' "$ROOT/scripts/phase-node.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fake_bin="$tmp/bin"
home="$tmp/gdc-home"
mkdir -p "$fake_bin" "$home"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '[[ -z "${GDC_TEST_SSH_LOG:-}" ]] || printf "%s\\n" "$*" >>"$GDC_TEST_SSH_LOG"' \
  'if [[ "${1:-}" == -G && -n "${GDC_TEST_SSH_HOST:-}" ]]; then printf "hostname %s\\n" "$GDC_TEST_SSH_HOST"; exit 0; fi' \
  'if [[ -n "${GDC_TEST_EXTERNAL_ML_ENDPOINT:-}" && "$*" == *node-config.json* ]]; then printf "%s\\n" "$GDC_TEST_EXTERNAL_ML_ENDPOINT"; exit 0; fi' \
  'if [[ -n "${GDC_TEST_LINK_RECORD:-}" && "$*" == *gdc-ml-link.json* ]]; then printf "%s\\n" "$GDC_TEST_LINK_RECORD"; exit 0; fi' \
  'if [[ "${GDC_TEST_EXEC_REMOTE:-false}" == true && "$*" == *"bash -s" ]]; then command="${!#}"; PATH="${GDC_TEST_REMOTE_BIN}:$PATH" bash -c "$command"; exit $?; fi' \
  'exit 0' >"$fake_bin/ssh"
chmod +x "$fake_bin/ssh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  compose) printf '\''time="2026-01-01T00:00:00Z" level=warning msg="Warning: No resource found to remove for project \\"gdc-edge\\"."\n'\'' >&2 ;;' \
  '  ps|volume|network) ;;' \
  '  *) echo "unexpected test docker invocation: $*" >&2; exit 1 ;;' \
  'esac' >"$fake_bin/docker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_bin/systemctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case " $* " in *" /srv/dai/"*) exit 0 ;; esac' \
  'exec /usr/bin/rm "$@"' >"$fake_bin/rm"
chmod +x "$fake_bin/docker" "$fake_bin/systemctl" "$fake_bin/rm"

printf 'fixture archive\n' >"$home/gdc-node0-validator-backup.tar"
chmod 600 "$home/gdc-node0-validator-backup.tar"
env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$home" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/output"

grep -Fq 'PASS gdc-node0 reset' "$tmp/output"
grep -Fq 'READY preserved local validator recovery archive for gdc-node0' "$tmp/output"
grep -Fq 'END phase=node-reset-gdc-node0 status=0' "$tmp/output"
[[ -r "$home/gdc-node0-validator-backup.tar" ]]
[[ -f "$home/gdc-node0/state/.lifecycle.lock" ]]
[[ -f "$home/gdc-node0/state/active-run-id" ]]
[[ ! -e "$home/.env" ]]
[[ ! -e "$home/gdc-node0/state/active-role-config" ]]
[[ ! -e "$home/gdc-node0/state/role-inputs" ]]

# A second reset against an already-empty Compose project is normal. Docker
# emits a warning for that state, but the operator command must remain quiet
# and successful while retaining real cleanup failures.
idempotent_home="$tmp/gdc-idempotent-reset"
env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$idempotent_home" GDC_TEST_EXEC_REMOTE=true GDC_TEST_REMOTE_BIN="$fake_bin" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node1 >"$tmp/idempotent-output"
grep -Fq 'PASS gdc-node1 reset' "$tmp/idempotent-output"
! grep -Fq 'No resource found to remove for project' "$tmp/idempotent-output"

# Reset has no release-profile input. A previous run can be bound to another
# release profile, but its evidence must remain immutable and cannot block a
# new reset run.
profile_conflict_home="$tmp/gdc-profile-conflict"
profile_conflict_state="$profile_conflict_home/gdc-node1/state"
mkdir -p "$profile_conflict_home/gdc-node1/runs/old-profile" "$profile_conflict_state"
printf 'old-profile\n' >"$profile_conflict_state/active-run-id"
printf '%s\n' \
  'schema_version=2' \
  'run_id=old-profile' \
  'operator_data_home=placeholder' \
  'release_profile=v2026.08.06' \
  'release_profile_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  >"$profile_conflict_home/gdc-node1/runs/old-profile/manifest.env"
env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$profile_conflict_home" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node1 >"$tmp/profile-conflict-output"
grep -Fq 'PASS gdc-node1 reset' "$tmp/profile-conflict-output"
[[ "$(<"$profile_conflict_state/active-run-id")" != old-profile ]]
[[ -f "$profile_conflict_home/gdc-node1/runs/old-profile/manifest.env" ]]

# A separately attached GPU is recorded in operator state. Host reset must
# clear both machines without requiring a role input or a second command.
paired_home="$tmp/gdc-paired-home"
mkdir -p "$paired_home/gdc-node0/state/ml-attached"
printf '%s\n' gdc-node0-ml >"$paired_home/gdc-node0/state/ml-attached/gdc-node0"
ssh_log="$tmp/paired-reset-ssh.log"
env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$paired_home" GDC_TEST_SSH_LOG="$ssh_log" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/paired-output"
grep -Fq 'READY detected linked GPU host gdc-node0-ml for gdc-node0 (operator state)' "$tmp/paired-output"
grep -Fq 'PASS gdc-node0-ml linked GPU reset' "$tmp/paired-output"
grep -Fq 'PASS gdc-node0 reset' "$tmp/paired-output"
grep -Fq 'gdc-node0-ml' "$ssh_log"
[[ ! -e "$paired_home/gdc-node0/state/ml-attached/gdc-node0" ]]

# A node config knows only an ML endpoint. Without the operator-owned alias
# association, reset must fail rather than guessing an alias from its name.
if env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$tmp/missing-ml-state" GDC_TEST_EXTERNAL_ML_ENDPOINT=203.0.113.10 \
  PATH="$fake_bin:$PATH" "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/missing-ml-output" 2>&1; then
  echo 'Host reset guessed a GPU SSH alias from an external ML endpoint' >&2
  exit 1
fi
grep -Fq 'cannot safely reset external GPU for gdc-node0' "$tmp/missing-ml-output"

# The Network Node deployment record is a second explicit source of the
# association. It lets the same operator reset a joined pair after local
# state was lost, without deriving an SSH alias from a host-name convention.
record_home="$tmp/gdc-record-home"
record='{"schema_version":1,"validator_alias":"gdc-node0","ml_ssh_alias":"operator-gpu","ml_endpoint":"203.0.113.10"}'
env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$record_home" GDC_TEST_EXTERNAL_ML_ENDPOINT=203.0.113.10 \
  GDC_TEST_SSH_HOST=203.0.113.10 GDC_TEST_LINK_RECORD="$record" \
  PATH="$fake_bin:$PATH" "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/record-output"
grep -Fq 'READY detected linked GPU host operator-gpu for gdc-node0 (Network Node deployment record)' "$tmp/record-output"
grep -Fq 'PASS operator-gpu linked GPU reset' "$tmp/record-output"

# Reproduce the cleanroom layout and prove that the public command works with
# no role input. The devcontainer-provided GDC_HOME keeps runtime state outside
# the clean checkout.
cleanroom_root="$tmp/workspace"
cleanroom_home="$tmp/workspaces/.data"
mkdir -p "$cleanroom_root"
cp -a "$ROOT/." "$cleanroom_root/"
env -u GDC_ENV -u GDC_NODE_ALIASES GDC_HOME="$cleanroom_home" \
  PATH="$fake_bin:$PATH" \
  "$cleanroom_root/gdc.sh" host reset gdc-node2 >"$tmp/cleanroom-output"
grep -Fq 'PASS gdc-node2 reset' "$tmp/cleanroom-output"
grep -Fq 'END phase=node-reset-gdc-node2 status=0' "$tmp/cleanroom-output"
[[ -f "$cleanroom_home/gdc-node2/state/.lifecycle.lock" ]]
[[ -f "$cleanroom_home/gdc-node2/state/active-run-id" ]]
[[ ! -e "$cleanroom_root/.env" ]]
[[ ! -e "$cleanroom_root/state" ]]

if env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$home" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset -unsafe-alias >"$tmp/invalid-output" 2>&1; then
  echo 'Host reset accepted an option-shaped SSH alias' >&2
  exit 1
fi
grep -Fq 'invalid SSH alias' "$tmp/invalid-output"

# More than one reset alias is exactly shorthand for sequential one-host
# resets: every alias gets its own phase and all are attempted in order.
multi_home="$tmp/gdc-multi-home"
env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$multi_home" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node0 gdc-node1 gdc-node2 gdc-node3 gdc-node4 >"$tmp/multi-output"
grep -Fq 'BEGIN phase=node-reset-gdc-node0' "$tmp/multi-output"
grep -Fq 'END phase=node-reset-gdc-node0 status=0' "$tmp/multi-output"
grep -Fq 'BEGIN phase=node-reset-gdc-node1' "$tmp/multi-output"
grep -Fq 'END phase=node-reset-gdc-node1 status=0' "$tmp/multi-output"
grep -Fq 'BEGIN phase=node-reset-gdc-node2' "$tmp/multi-output"
grep -Fq 'END phase=node-reset-gdc-node2 status=0' "$tmp/multi-output"
grep -Fq 'BEGIN phase=node-reset-gdc-node3' "$tmp/multi-output"
grep -Fq 'END phase=node-reset-gdc-node3 status=0' "$tmp/multi-output"
grep -Fq 'BEGIN phase=node-reset-gdc-node4' "$tmp/multi-output"
grep -Fq 'END phase=node-reset-gdc-node4 status=0' "$tmp/multi-output"
for alias in gdc-node0 gdc-node1 gdc-node2 gdc-node3 gdc-node4; do
  [[ -f "$multi_home/$alias/state/.lifecycle.lock" ]]
done
[[ ! -e "$multi_home/gdc-node0/gdc-node1" ]]

cleanroom_recipe="$(sed -n '/^cleanroom:/,/^[^[:space:]].*:/p' "$ROOT/Makefile")"
cleanroom_reset_recipe="$(sed -n '/^cleanroom-reset:/,/^[^[:space:]].*:/p' "$ROOT/Makefile")"
grep -Fq 'cleanroom: cleanroom-reset' <<<"$cleanroom_recipe"
grep -Fq 'CLEANROOM_DEVCONTAINER_CONFIG := .devcontainer/cleanroom/devcontainer.json' "$ROOT/Makefile"
grep -Fq 'up --config $(CLEANROOM_DEVCONTAINER_CONFIG) --workspace-folder . --remove-existing-container' <<<"$cleanroom_reset_recipe"
! grep -Fq 'build --workspace-folder .' "$ROOT/Makefile"
cleanroom_config="$ROOT/.devcontainer/cleanroom/devcontainer.json"
grep -Fq '"GDC_HOME": "/home/operator/.gdc-data"' "$cleanroom_config"
grep -Fq '"workspaceFolder": "/home/operator"' "$cleanroom_config"
grep -Fq '"workspaceMount": "type=tmpfs,target=/tmp/empty-workspace"' "$cleanroom_config"
grep -Fq 'target=/home/operator/.gdc-data,type=bind' "$cleanroom_config"
grep -Fq 'exec --config $(CLEANROOM_DEVCONTAINER_CONFIG) --workspace-folder . $(cmd)' "$ROOT/Makefile"
grep -Fq 'lock_file="$STATE/.lifecycle.lock"' "$ROOT/gdc.sh"
! grep -Fq '.gdc.lock' "$ROOT/gdc.sh"
grep -Fq 'No resource found to remove for project' "$ROOT/scripts/phase-node.sh"
grep -Fq 'ERROR failed to remove managed Compose deployment directory=%s exit=%s' "$ROOT/scripts/phase-node.sh"
grep -Fq 'removed managed Compose resources without reading invalid env' "$ROOT/scripts/phase-node.sh"

printf 'PASS Host reset requires only an SSH alias and no role input\n'
