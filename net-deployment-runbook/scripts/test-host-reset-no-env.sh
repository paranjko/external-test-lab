#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  'while IFS= read -r _; do :; done' \
  'exit 0' >"$fake_bin/ssh"
chmod +x "$fake_bin/ssh"

env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$home" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/output"

grep -Fq 'PASS gdc-node0 reset' "$tmp/output"
grep -Fq 'END phase=node-reset-gdc-node0 status=0' "$tmp/output"
[[ -f "$home/.gdc.lock" ]]
[[ -f "$home/gdc-node0/state/active-run-id" ]]
[[ ! -e "$home/.env" ]]
[[ ! -e "$home/gdc-node0/state/active-role-config" ]]
[[ ! -e "$home/gdc-node0/state/role-inputs" ]]

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
[[ -f "$cleanroom_home/.gdc.lock" ]]
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

cleanroom_recipe="$(sed -n '/^cleanroom:/,/^[^[:space:]].*:/p' "$ROOT/Makefile")"
cleanroom_reset_recipe="$(sed -n '/^cleanroom-reset:/,/^[^[:space:]].*:/p' "$ROOT/Makefile")"
grep -Fq 'cleanroom: cleanroom-reset' <<<"$cleanroom_recipe"
grep -Fq 'cleanroom-fresh: cleanroom' "$ROOT/Makefile"
grep -Fq 'up --workspace-folder . --remove-existing-container' <<<"$cleanroom_reset_recipe"
! grep -Fq 'build --workspace-folder .' "$ROOT/Makefile"
grep -Fq '"GDC_HOME": "/workspaces/.data"' "$ROOT/.devcontainer/devcontainer.json"
grep -Fq '"workspaceFolder": "/workspace"' "$ROOT/.devcontainer/devcontainer.json"
grep -Fq 'readonly workspace_root=/workspace' "$ROOT/.devcontainer/initialize-cleanroom.sh"
grep -Fq 'readonly cleanroom_gdc_home=/workspaces/.data' "$ROOT/.devcontainer/initialize-cleanroom.sh"
grep -Fq 'expected_gdc_home=/workspaces/.data' "$ROOT/.devcontainer/verify-cleanroom.sh"
grep -Fq 'exec --workspace-folder . $(cmd)' "$ROOT/Makefile"
grep -Fq 'exec /workspace/gdc.sh "$@"' "$ROOT/.devcontainer/gdc"

printf 'PASS Host reset requires only an SSH alias and no role input\n'
