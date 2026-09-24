#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -Fq 'for foreign in /srv/dai/edge /srv/dai/ops /srv/dai/gonka-devnet-bot' "$ROOT/scripts/phase-node.sh"
grep -Fq '[[ ! -e /srv/dai || ( -d /srv/dai && ! -L /srv/dai ) ]]' "$ROOT/scripts/phase-node.sh"
! grep -Fq 'validator root contains a symlink' "$ROOT/scripts/phase-node.sh"
grep -Fq 'for managed_path in /srv/dai/deploy /srv/dai/deploy/monitoring-agent /srv/dai/deploy/edge /srv/dai/identity /srv/dai/signer; do' "$ROOT/scripts/phase-node.sh"
grep -Fq 'compose_down_dir "/srv/dai/deploy/monitoring-agent"' "$ROOT/scripts/phase-node.sh"
grep -Fq 'compose_down_dir "/srv/dai/deploy/edge"' "$ROOT/scripts/phase-node.sh"
grep -Fq 'rm -rf -- /srv/dai ' "$ROOT/scripts/phase-node.sh"
grep -Fq 'remove_compose_project "gdc-monitoring-agent-$NODE"' "$ROOT/scripts/phase-node.sh"
grep -Fq 'remove_compose_project "gdc-edge-$NODE"' "$ROOT/scripts/phase-node.sh"
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
  'if [[ "$*" == *"--remote capture"* ]]; then cat >/dev/null; printf "%s\\n" "{\"schema_version\":1,\"kind\":\"gdc-reset-dai-backup\",\"identity_present\":true,\"signer_stopped\":true,\"archive_path\":\"/srv/backup/reset-fixture-dai-backup.tar\",\"archive_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"; exit 0; fi' \
  'if [[ "$*" == *"gdc-identity-layout"* ]]; then cat >/dev/null; layout="${GDC_TEST_IDENTITY_LAYOUT:-none}"; case "$*" in *-ml*) layout="${GDC_TEST_ML_IDENTITY_LAYOUT:-none}" ;; esac; printf "gdc-identity-layout=%s\\n" "$layout"; exit 0; fi' \
  'if [[ "$*" == *"gdc-identity-discard"* ]]; then cat >/dev/null; exit 0; fi' \
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
  'exec "$(PATH=/usr/bin:/bin command -v rm)" "$@"' >"$fake_bin/rm"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output='' url=''
while (($#)); do
  case "$1" in
    -o) output="${2:-}"; shift 2 ;;
    -w|-H|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ -z "${GDC_TEST_CURL_LOG:-}" ]] || printf '%s\n' "$url" >>"$GDC_TEST_CURL_LOG"
host="${url#*://}"; host="${host%%/*}"
case "$host" in
  node1.*) seed=SEED1; node_id=89abcdef0123456789abcdef0123456789abcdef ;;
  *) seed=SEED0; node_id=0123456789abcdef0123456789abcdef01234567 ;;
esac
height_var="GDC_TEST_HEIGHT_$seed"; height="${!height_var:-1000}"
mode_var="GDC_TEST_PARTICIPANT_MODE_$seed"
mode="${!mode_var:-${GDC_TEST_PARTICIPANT_MODE:-unavailable}}"
# Each seed answers about its own chain state, and about its own tip.
if [[ "$url" == */status ]]; then
  [[ "$height" != none ]] || exit 7
  printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community"},"sync_info":{"latest_block_height":"%s","catching_up":%s}}}\n' \
    "$node_id" "$height" "${GDC_TEST_CATCHING_UP:-false}"
  exit 0
fi
case "$mode" in
  registered) printf '{"participant":{"index":"%s","address":"%s","status":1,"validator_key":"fixture"}}\n' "${url##*/}" "${url##*/}" >"$output"; printf 200 ;;
  absent) printf '{"code":5,"message":"not found"}\n' >"$output"; printf 404 ;;
  server_error) printf '{"code":13}\n' >"$output"; printf 503 ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$fake_bin/docker" "$fake_bin/systemctl" "$fake_bin/rm" "$fake_bin/curl"
refute_grep() {
  if grep -Fq -- "$1" "$2"; then
    echo "unexpected '$1' in $2" >&2
    exit 1
  fi
}

env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$home" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/output"

grep -Fq 'PASS gdc-node0 reset' "$tmp/output"
grep -Fq 'external reset archive is retained for explicit recovery' "$tmp/output"
grep -Fq 'END phase=node-reset-gdc-node0 status=0' "$tmp/output"
[[ -r "$home/gdc-node0/state/reset/gdc-node0/latest-identity.json" ]]
reset_metadata="$(jq -r .metadata_path "$home/gdc-node0/state/reset/gdc-node0/latest-identity.json")"
[[ -r "$reset_metadata" ]]
[[ -f "$home/gdc-node0/state/.lifecycle.lock" ]]
[[ -f "$home/gdc-node0/state/active-run-id" ]]
[[ ! -e "$home/.env" ]]
[[ ! -e "$home/gdc-node0/state/active-role-config" ]]
[[ ! -e "$home/gdc-node0/state/role-inputs" ]]

# A completed incident is history, not a permanent reset dispatcher.
historical_home="$tmp/historical-recovery"
mkdir -p "$historical_home/recovery-GNK-LAB-2026-0001/hosts"
touch "$historical_home/recovery-GNK-LAB-2026-0001/confirmed" \
  "$historical_home/recovery-GNK-LAB-2026-0001/complete"
printf '{}\n' >"$historical_home/recovery-GNK-LAB-2026-0001/hosts/fixture-restored.json"
env -u GDC_ENV -u GDC_NODE_ALIASES GDC_HOME="$historical_home" PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset fixture-restored >"$tmp/historical-reset-output"
grep -Fq 'END phase=node-reset-fixture-restored status=0' "$tmp/historical-reset-output"
[[ -f "$historical_home/recovery-GNK-LAB-2026-0001/hosts/fixture-restored.json" ]]

# A second reset against an already-empty Compose project is normal. Docker
# emits a warning for that state, but the operator command must remain quiet
# and successful while retaining real cleanup failures.
idempotent_home="$tmp/gdc-idempotent-reset"
env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$idempotent_home" PATH="$fake_bin:$PATH" \
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
# Without a local cold account there is no registration to read, but the Host
# identity layout still decides whether reset may remove the deployment root:
# a first-generation signer lives inside it.
grep -Fq 'gdc-identity-layout' "$ssh_log"

# A GPU Host holds no validator identity. If the linked alias does, the
# association is wrong and reset must not remove that machine's state.
ml_conflict_home="$tmp/gdc-ml-conflict-home"
mkdir -p "$ml_conflict_home/gdc-node0/state/ml-attached"
printf '%s\n' gdc-node0-ml >"$ml_conflict_home/gdc-node0/state/ml-attached/gdc-node0"
if env -u GDC_ENV -u GDC_NODE_ALIASES \
  GDC_HOME="$ml_conflict_home" GDC_TEST_SSH_LOG="$tmp/ml-conflict-ssh.log" \
  GDC_TEST_ML_IDENTITY_LAYOUT=v2 PATH="$fake_bin:$PATH" \
  "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/ml-conflict-output" 2>&1; then
  echo 'reset removed a linked GPU Host that holds validator identity material' >&2
  exit 1
fi
grep -Fq 'gdc-node0-ml holds validator identity material and is linked as the GPU Host of gdc-node0' "$tmp/ml-conflict-output"
refute_grep "NODE='gdc-node0-ml'" "$tmp/ml-conflict-ssh.log"

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
# The cleanroom validates checked-in operator tooling, not untracked runtime
# evidence. git archive also prevents unreadable retained test artifacts from
# contaminating this copy.
git -C "$ROOT" archive HEAD | tar -xf - -C "$cleanroom_root"
[[ ! -e "$cleanroom_root/.data" ]]
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
grep -Fq '.lifecycle.lock.d' "$ROOT/scripts/phase-reset.sh"
! grep -Fq '.gdc.lock' "$ROOT/gdc.sh"
grep -Fq 'No resource found to remove for project' "$ROOT/scripts/phase-node.sh"
grep -Fq 'ERROR failed to remove managed Compose deployment directory=%s exit=%s' "$ROOT/scripts/phase-node.sh"
grep -Fq 'removed managed Compose resources without reading invalid env' "$ROOT/scripts/phase-node.sh"

# Reset is a local lifecycle operation. It does not decide which account or
# validator key is live on-chain: the operator recovers that relationship with
# an explicit cold or validator archive on the subsequent JOIN.
address=gonka1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9
seed_identity_home() {
  local home="$1" node="$2"
  mkdir -p "$home/$node/state/identities" "$home/$node/state/joined" "$home/$node/accounts" "$home/$node/mnemonics"
  printf '%s\n' '{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}' \
    >"$home/$node/state/network-bootstrap.json"
  printf '{"address":"%s","name":"%s-cold"}\n' "$address" "$node" >"$home/$node/accounts/$node-cold.json"
  printf '{"node_name":"%s","node_id":"0123456789abcdef0123456789abcdef01234567","consensus_pubkey":"fixture","warm_address":"gonka1warm"}\n' "$node" \
    >"$home/$node/state/identities/$node.json"
  printf 'fixture mnemonic\n' >"$home/$node/mnemonics/$node-cold.mnemonic"
  touch "$home/$node/state/joined/$node"
}
run_identity_reset() {
  local name="$1" rc=0
  env -u GDC_ENV -u GDC_NODE_ALIASES \
    GDC_HOME="$tmp/$name" GDC_TEST_SSH_LOG="$tmp/$name-ssh.log" GDC_TEST_CURL_LOG="$tmp/$name-curl.log" \
    PATH="$fake_bin:$PATH" \
    "$ROOT/gdc.sh" host reset gdc-node0 >"$tmp/$name-output" 2>&1 || rc=$?
  return "$rc"
}

seed_identity_home "$tmp/full-reset" gdc-node0
run_identity_reset full-reset
grep -Fq 'READY removed 2 local identity record(s) for gdc-node0; external reset archive is retained for explicit recovery' "$tmp/full-reset-output"
grep -Fq 'PASS gdc-node0 reset' "$tmp/full-reset-output"
# Archive capture precedes deletion of the complete validator root. Reset never
# queries participant registration, so a down or divergent chain cannot leave
# an ambiguous local lifecycle state.
awk '/--remote capture/ {c=NR} /NODE=.gdc-node0. .*bash -s$/ {r=NR} END {exit !(c && r && c < r)}' "$tmp/full-reset-ssh.log"
[[ ! -e "$tmp/full-reset-curl.log" ]]
[[ ! -e "$tmp/full-reset/gdc-node0/accounts/gdc-node0-cold.json" && ! -e "$tmp/full-reset/gdc-node0/state/identities/gdc-node0.json" ]]
[[ -f "$tmp/full-reset/gdc-node0/mnemonics/gdc-node0-cold.mnemonic" ]]
recovery="$(find "$tmp/full-reset/gdc-node0/state" -maxdepth 1 -type d -name 'recovery-partial-*' | head -n 1)"
[[ -n "$recovery" && "$(stat -c %a "$recovery")" == 700 ]]
[[ -f "$recovery/gdc-node0-cold.json" && -f "$recovery/gdc-node0.json" ]]
"$ROOT/scripts/classify-join-state.sh" "$tmp/full-reset/gdc-node0/state/identities/gdc-node0.json" \
  "$tmp/full-reset/gdc-node0/accounts/gdc-node0-cold.json" "$tmp/full-reset/gdc-node0/state/joined/gdc-node0" '' \
  | jq -e '.classification == "new"' >/dev/null

printf 'PASS Host reset requires only an SSH alias and preserves explicit recovery material before a full validator-root deletion\n'
