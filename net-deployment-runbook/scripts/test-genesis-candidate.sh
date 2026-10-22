#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
real_software="$tmp/real-genesis-software.json"
"$ROOT/scripts/render-genesis-software.sh" qwen2.5-7b-instruct-devnet "$real_software" >/dev/null
real_software_sha="$(sha256sum "$real_software" | awk '{print $1}')"
release_lock_sha="$(sha256sum "$ROOT/profiles/releases/v2026.10.06.lock" | awk '{print $1}')"
guard_env=(PATH="/usr/bin:/bin" GDC_HOME="$tmp/guard-home" GDC_GENESIS_RUNTIME_CONTEXT=verified-fragment
  GDC_GENESIS_SOFTWARE_FILE="$real_software" GDC_GENESIS_SOFTWARE_SHA256="$real_software_sha"
  GDC_GENESIS_RELEASE_LOCK_SHA256="$release_lock_sha" GDC_PROFILE_KIND=release IS_GENESIS=true
  GDC_GENESIS_PREPARE_ONLY=true MODEL_ID=Qwen/Qwen2.5-7B-Instruct)
env -i "${guard_env[@]}" bash -c 'ROOT="$1"; source "$ROOT/scripts/lib.sh"; assert_baseline_release' _ "$ROOT"
if env -i "${guard_env[@]}" GDC_GENESIS_PREPARE_ONLY=false \
  bash -c 'ROOT="$1"; source "$ROOT/scripts/lib.sh"; assert_baseline_release' _ "$ROOT" >"$tmp/guard-scope.out" 2>"$tmp/guard-scope.err"; then
  echo 'baseline guard accepted a Genesis runtime context outside the candidate lifecycle' >&2; exit 1
fi
grep -Fq 'valid only inside the explicit candidate lifecycle' "$tmp/guard-scope.err"
env -i "${guard_env[@]}" GDC_GENESIS_PREPARE_ONLY=false GDC_GENESIS_RESUME_CANDIDATE="$(printf 'a%.0s' {1..64})" \
  bash -c 'ROOT="$1"; source "$ROOT/scripts/lib.sh"; assert_baseline_release' _ "$ROOT"
cp "$real_software" "$tmp/drifted-software.json"
printf '\n' >>"$tmp/drifted-software.json"
if env -i "${guard_env[@]}" GDC_GENESIS_SOFTWARE_FILE="$tmp/drifted-software.json" \
  bash -c 'ROOT="$1"; source "$ROOT/scripts/lib.sh"; assert_baseline_release' _ "$ROOT" >"$tmp/guard-drift.out" 2>"$tmp/guard-drift.err"; then
  echo 'baseline guard accepted a drifted Genesis software fragment' >&2; exit 1
fi
grep -Fq 'verified Genesis runtime fragment changed after preflight' "$tmp/guard-drift.err"
mkdir -p "$tmp/scripts" "$tmp/profiles/releases" "$tmp/bin" "$tmp/01-identities-genesis" "$tmp/02-node" "$tmp/04-ops/edge-node" "$tmp/04-ops/agent" "$tmp/03-join"
cp "$ROOT/scripts/phase-genesis.sh" "$tmp/scripts/phase-genesis.sh"
cp "$ROOT/profiles/releases/v2026.07.23.lock" "$tmp/profiles/releases/"
printf 'fixture target lock\n' >"$tmp/profiles/releases/v2026.10.06.lock"
cat >"$tmp/scripts/lib.sh" <<'EOF'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "$*" >&2; exit 1; }
load_project() {
  GDC_HOME="$TEST_GDC_HOME"; STATE="$GDC_HOME/state"; GENESIS="$GDC_HOME/genesis"
  GDC_DATA_ROOT="$GDC_HOME"; GENESIS_NODE=node0; CHAIN_ID=fixture-chain
  GENESIS_PUBLIC_HOST=node0.example.test; PUBLIC_EDGE_NODE=node0
  INVENTORY="$GDC_HOME/inventory.env"; IDENTITIES="$GDC_HOME/identities"
  SECRETS="$GDC_HOME/secrets"; ACCOUNTS="$GDC_HOME/accounts"; GENERATED="$GDC_HOME/generated"
  DATA_ROOT=/srv/dai; MODEL_ID=Qwen/Qwen2.5-7B-Instruct
  mkdir -p "$STATE/phase-profiles" "$GENESIS" "$IDENTITIES" "$SECRETS" "$ACCOUNTS" "$GENERATED/nodes"
  printf 'fixture-inventory\n' >"$INVENTORY"
}
assert_baseline_release() { :; }
profile_hash() { printf '%064d' 1; }
ssh_ready() { return 0; }
step() { printf 'STEP %s\n' "$*"; }
record_phase_profile() { :; }
require_ml_qualification() { :; }
runtime_id_for_participant() { printf 'runtime-fixture'; }
record_runtime_identity() { :; }
start_stack() { printf '%s\n' "$*" >>"$TEST_SERVICES_LOG"; }
record_join_state() { printf 'record-join %s\n' "$*" >>"$TEST_PHASE_SCRIPT_LOG"; }
persist_runtime_topology() { :; }
genesis_sha256() { jq -eS '.' "$1" | sha256sum | awk '{print $1}'; }
capture_canonical_genesis() { cp "$TEST_CANDIDATE_GENESIS" "$2"; }
write_phase_lineage() { :; }
EOF
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SSH_LOG"
case "$*" in
  *'GDC_JOIN_STATESYNC_ENABLE'*) exit 0 ;;
  *'sudo test ! -e /srv/dai/deploy/compose.yaml'*) exit 0 ;;
  *"test -s '/srv/dai/inference/config/config.toml'"*) exit 0 ;;
  *'sudo -n bash -s --'*)
    remote_script="$(cat)"
    printf '%s\n' "$remote_script" >>"$TEST_REMOTE_SCRIPT_LOG"
    grep -Fq 'MLNODE_IMAGE' <<<"$remote_script"
    grep -Fq '/srv/dai/deploy/node-config.json' <<<"$remote_script"
    grep -Fq 'rendered-model-config' <<<"$remote_script"
    ! grep -Fq 'MLNODE_GENERIC_IMAGE' <<<"$remote_script"
    ! grep -Fq 'env_value MODEL_ID' <<<"$remote_script"
    [[ "${TEST_REMOTE_CANDIDATE_DRIFT:-false}" != true ]] || { echo 'GDC_RESUME_GATE_FAIL=candidate-shared-sha256' >&2; exit 41; }
    printf '%s\n' "{\"result\":{\"node_info\":{\"network\":\"fixture-chain\",\"id\":\"${TEST_REMOTE_NODE_ID:-0123456789abcdef0123456789abcdef01234567}\"}}}"
    exit 0 ;;
  *'sudo test -s /srv/dai/shared/genesis.json'*)
    [[ "${TEST_REMOTE_CANDIDATE_DRIFT:-false}" != true ]] || exit 41
    printf '%s\n' "{\"result\":{\"node_info\":{\"network\":\"fixture-chain\",\"id\":\"${TEST_REMOTE_NODE_ID:-0123456789abcdef0123456789abcdef01234567}\"}}}"
    exit 0 ;;
  *'curl -fsS http://127.0.0.1:1317/'*) printf '%s\n' '{"participant":{"status":"ACTIVE"}}'; exit 0 ;;
  *'install-node.sh'*) [[ "${TEST_FAIL_NODE_INSTALL:-false}" != true ]] || exit 23; exit 0 ;;
  *'rm -rf '*'/tmp/gdc-deploy-'*) exit 0 ;;
  *'./start-node.sh'*) exit 0 ;;
  *'./sync-node-config.sh'*) printf 'resume-sync\n' >>"$TEST_PHASE_SCRIPT_LOG"; exit 0 ;;
  *) printf '%s\n' "$*" >>"$TEST_UNEXPECTED_SSH_LOG"; exit 97 ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$TEST_SCP_LOG"\nexit 0\n' >"$tmp/bin/scp"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$TEST_RSYNC_LOG"\nexit 0\n' >"$tmp/bin/rsync"
chmod +x "$tmp/bin/scp" "$tmp/bin/rsync"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=''
while (($#)); do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
cp "$TEST_CANDIDATE_GENESIS" "$out"
printf '200'
EOF
cat >"$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEST_CLOCK_AFTER:-false}" == true && "$*" == '-u +%s' ]]; then
  printf '%s\n' "$(( $(/usr/bin/date -u +%s) + 3600 ))"
else
  exec /usr/bin/date "$@"
fi
EOF
chmod +x "$tmp/bin/ssh" "$tmp/bin/curl" "$tmp/bin/date"
for name in ensure-inferenced-cli.sh phase-prepare.sh phase-qualify-ml.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/scripts/$name"; chmod +x "$tmp/scripts/$name"
done
cat >"$tmp/scripts/render-genesis-software.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cp "$TEST_GENESIS_SOFTWARE" "$2"
EOF
chmod +x "$tmp/scripts/render-genesis-software.sh"
cat >"$tmp/scripts/phase-identities.sh" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$TEST_IDENTITIES_LOG"
mkdir -p "$TEST_GDC_HOME/state/operator-home/keyring-file" "$TEST_GDC_HOME/identities" "$TEST_GDC_HOME/accounts" "$TEST_GDC_HOME/secrets"
printf 'private-keyring-fixture\n' >"$TEST_GDC_HOME/state/operator-home/keyring-file/keyring-test"
printf 'password\n' >"$TEST_GDC_HOME/secrets/operator.keyring"
printf 'keyring-fixture\n' >"$TEST_GDC_HOME/secrets/node0.keyring"
printf 'postgres-fixture\n' >"$TEST_GDC_HOME/secrets/node0.postgres"
printf '{"node_id":"0123456789abcdef0123456789abcdef01234567"}\n' >"$TEST_GDC_HOME/identities/node0.json"
printf '{"address":"gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' >"$TEST_GDC_HOME/accounts/node0-cold.json"
printf '{"address":"gonka1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n' >"$TEST_GDC_HOME/accounts/gdc-gateway-cold.json"
printf '{"address":"gonka1cccccccccccccccccccccccccccccccccccccccc"}\n' >"$TEST_GDC_HOME/accounts/gdc-faucet-cold.json"
EOF
chmod +x "$tmp/scripts/phase-identities.sh"
cat >"$tmp/01-identities-genesis/build-genesis.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${INFERENCED_HOME:-}" == "$TEST_GDC_HOME/runs/prepare-one/genesis/candidate-operator-home" ]]
[[ -s "$INFERENCED_HOME/keyring-file/keyring-test" ]]
[[ " $* " == *' --candidate-only '* ]]
output=''; time=''
while (($#)); do case "$1" in --output-dir) output="$2"; shift 2;; --genesis-time) time="$2"; shift 2;; *) shift;; esac; done
printf 'build\n' >>"$TEST_BUILD_LOG"
mkdir -p "$output"
jq -n --arg chain fixture-chain --arg time "$time" '{chain_id:$chain,genesis_time:$time,app_state:{}}' >"$output/genesis.json"
sha256sum "$output/genesis.json" | awk '{print $1"  genesis.json"}' >"$output/genesis.sha256"
genesis_sha="$(sha256sum "$output/genesis.json" | awk '{print $1}')"
printf 'node0@example.test:26656\n' >"$output/genesis-seeds.txt"
jq -n --arg hash "$genesis_sha" '{genesis_sha256:$hash,genesis_overrides_sha256:("f" * 64)}' >"$output/ceremony-record.json"
EOF
cat >"$tmp/01-identities-genesis/verify-genesis.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ -s "$1" && -s "$2" ]]
if [[ -s "$TEST_EXPECTED_CONFIG" ]]; then
  [[ $# == 5 && "$3" == fixture-chain && "$4" == --config-file && "$5" == "$TEST_EXPECTED_CONFIG" ]]
else
  [[ $# == 3 && "$3" == fixture-chain ]]
fi
printf '%s\n' "$*" >>"$TEST_VERIFY_LOG"
EOF
chmod +x "$tmp/01-identities-genesis/build-genesis.sh" "$tmp/01-identities-genesis/verify-genesis.sh"
for spec in 02-node/render-node-env.sh 02-node/render-node-config.sh 04-ops/edge-node/render-env.sh 04-ops/agent/render-env.sh 03-join/wait-synced.sh 03-join/restart-api-after-sync.sh 03-join/grant-ml-ops.sh 03-join/wait-active.sh; do
  if [[ "$spec" == 02-node/render-node-env.sh ]]; then
    cat >"$tmp/$spec" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "${0##*/}" >>"$TEST_PHASE_SCRIPT_LOG"
output=''
while (($#)); do
  if [[ "$1" == --output ]]; then output="$2"; shift 2; else shift; fi
done
{
  printf 'DAPI_EXPECTED_VERSION=%s\n' "$DAPI_EXPECTED_VERSION"
  printf 'DAPI_EXPECTED_COMMIT=%s\n' "$DAPI_EXPECTED_COMMIT"
} >"$output"
EOF
  else
    cat >"$tmp/$spec" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "${0##*/}" >>"$TEST_PHASE_SCRIPT_LOG"
while (($#)); do
  if [[ "$1" == --output ]]; then mkdir -p "$(dirname "$2")"; : >"$2"; exit 0; fi
  shift
done
exit 0
EOF
  fi
  chmod +x "$tmp/$spec"
done
cat >"$tmp/scripts/phase-ops.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$TEST_SERVICES_LOG"
[[ "$*" == faucet ]]
[[ "${GDC_HOME:-}" == "$TEST_GDC_HOME" ]]
[[ "${GDC_GENESIS_DIR:-}" == "$TEST_GDC_HOME/genesis-candidate" ]]
[[ "${GDC_GENESIS_CANDIDATE_SHA256:-}" == "$(sha256sum "$GDC_GENESIS_DIR/genesis.json" | awk '{print $1}')" ]]
[[ -s "$GDC_HOME/accounts/gdc-faucet-cold.json" ]]
printf 'genesis=%s\nnode-account=%s\nfaucet-account=%s\nsha256=%s\n' \
  "$GDC_GENESIS_DIR/genesis.json" \
  "$(jq -er '.account_path' "$GDC_HOME/genesis-candidate.json")" \
  "$GDC_HOME/accounts/gdc-faucet-cold.json" \
  "$GDC_GENESIS_CANDIDATE_SHA256" >>"$TEST_FAUCET_PATH_LOG"
EOF
chmod +x "$tmp/scripts/phase-ops.sh"
printf '%s\n' '{"app_state":{"inference":{"params":{"poc_params":{"model_id":"Qwen/Qwen2.5-7B-Instruct"}},"model_list":[{"id":"Qwen/Qwen2.5-7B-Instruct"}]}}}' >"$tmp/config.json"
cat >"$tmp/software.json" <<'EOF'
{"schema_version":1,"kind":"gdc-genesis-software-fragment","source":{"release_profile":"v2026.10.06","model_profile":"fixture"},"spec":{"deployment":{"software":{"model":{"id":"Qwen/Qwen2.5-7B-Instruct","revision":"1111111111111111111111111111111111111111","context_length":32768,"max_num_seqs":1,"gpu_memory_utilization":0.8,"dtype":"bfloat16","tensor_parallel_size":1},"components":{"node":{"version":"0.2.16-post1","commit":"136041c81ea8ff38e7620d76af66a7c7fe7eec50","image":"registry/core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"api":{"version":"0.2.16-post1","commit":"136041c81ea8ff38e7620d76af66a7c7fe7eec50","image":"registry/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"mlnode":{"image":"registry/ml@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}}}},"model_profile":{"vllm_args":""},"binary_sha256":{"inferenced":"2f6a31c3ecda063a84fcfd80782fe5b00908f9b678da9204d6c7acba602260de","decentralized_api":"332699b4ec760569f5670c6e1feb9d579c2a0c4ec6e0cc5095bf74ea1a37007f"}}
EOF
config_sha="$(sha256sum "$tmp/config.json" | awk '{print $1}')"
software_sha="$(sha256sum "$tmp/software.json" | awk '{print $1}')"
mkdir -p "$tmp/operator/state"
env_common=(PATH="$tmp/bin:/usr/bin:/bin" TEST_GDC_HOME="$tmp/operator" TEST_SSH_LOG="$tmp/ssh.log" TEST_SCP_LOG="$tmp/scp.log" TEST_RSYNC_LOG="$tmp/rsync.log" TEST_UNEXPECTED_SSH_LOG="$tmp/unexpected-ssh.log" TEST_REMOTE_SCRIPT_LOG="$tmp/remote-script.log" TEST_BUILD_LOG="$tmp/build.log" TEST_CANDIDATE_GENESIS="$tmp/operator/genesis-candidate/genesis.json" TEST_SERVICES_LOG="$tmp/services.log" TEST_FAUCET_PATH_LOG="$tmp/faucet-path.log" TEST_PHASE_SCRIPT_LOG="$tmp/phase-script.log" TEST_IDENTITIES_LOG="$tmp/identities.log" TEST_VERIFY_LOG="$tmp/verify.log" TEST_EXPECTED_CONFIG="$tmp/config.json" TEST_GENESIS_SOFTWARE="$tmp/software.json" GDC_GENESIS_CONFIG_FILE="$tmp/config.json" GDC_GENESIS_CONFIG_SHA256="$config_sha" GDC_GENESIS_SOFTWARE_FILE="$tmp/software.json" GDC_GENESIS_SOFTWARE_SHA256="$software_sha")

# Model an identity phase completed in an earlier attempt. The remote marker is
# at canonical DATA_ROOT/inference/config, so preparation must reuse the local
# identity rather than recreate keys.
mkdir -p "$tmp/operator/state/operator-home/keyring-file" "$tmp/operator/identities" "$tmp/operator/accounts" "$tmp/operator/secrets"
printf 'private-keyring-fixture\n' >"$tmp/operator/state/operator-home/keyring-file/keyring-test"
printf 'password\n' >"$tmp/operator/secrets/operator.keyring"
printf 'keyring-fixture\n' >"$tmp/operator/secrets/node0.keyring"
printf 'postgres-fixture\n' >"$tmp/operator/secrets/node0.postgres"
printf '{"node_id":"0123456789abcdef0123456789abcdef01234567"}\n' >"$tmp/operator/identities/node0.json"
printf '{"address":"gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' >"$tmp/operator/accounts/node0-cold.json"
printf '{"address":"gonka1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n' >"$tmp/operator/accounts/gdc-gateway-cold.json"
printf '{"address":"gonka1cccccccccccccccccccccccccccccccccccccccc"}\n' >"$tmp/operator/accounts/gdc-faucet-cold.json"

if env -i "${env_common[@]}" GDC_GENESIS_PREPARE_ONLY=true GDC_RUN_ID=bad-hash \
  GDC_GENESIS_CONFIG_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/hash.out" 2>"$tmp/hash.err"; then
  echo 'prepare accepted a mismatched reviewed config hash' >&2; exit 1
fi
[[ ! -s "$tmp/ssh.log" ]] || { echo 'config hash mismatch performed remote work' >&2; exit 1; }
grep -Fq 'reviewed Genesis config SHA-256 mismatch' "$tmp/hash.err"

if env -i "${env_common[@]}" GDC_GENESIS_PREPARE_ONLY=true GDC_RUN_ID=software-drift \
  GDC_GENESIS_SOFTWARE_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/software-drift.out" 2>"$tmp/software-drift.err"; then
  echo 'prepare accepted a mismatched reviewed software hash' >&2; exit 1
fi
[[ ! -s "$tmp/ssh.log" ]] || { echo 'software hash mismatch performed remote work' >&2; exit 1; }
grep -Fq 'reviewed Genesis software SHA-256 mismatch' "$tmp/software-drift.err"

if ! env -i "${env_common[@]}" GDC_GENESIS_PREPARE_ONLY=true GDC_RUN_ID=prepare-one \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/prepare.out" 2>"$tmp/prepare.err"; then
  cat "$tmp/prepare.out" "$tmp/prepare.err" >&2
  exit 1
fi
[[ -s "$tmp/operator/genesis-candidate.json" && -s "$tmp/operator/genesis-candidate/genesis.json" ]]
grep -Fq 'PREPARE ONLY' "$tmp/prepare.out"
grep -Fq "test -s '/srv/dai/inference/config/config.toml'" "$tmp/ssh.log"
[[ ! -s "$tmp/identities.log" ]] || { echo 'prepare recreated existing Genesis identities' >&2; exit 1; }
grep -Fq -- "--config-file $tmp/config.json" "$tmp/verify.log"
[[ -s "$tmp/operator/runs/prepare-one/genesis/candidate-operator-home/keyring-file/keyring-test" ]]
[[ "$(wc -l <"$tmp/build.log")" == 1 ]]
candidate_sha="$(jq -er '.candidate_sha256' "$tmp/operator/genesis-candidate.json")"
raw_candidate_sha="$(sha256sum "$tmp/operator/genesis-candidate/genesis.json" | awk '{print $1}')"
canonical_genesis_sha="$(jq -eS '.' "$tmp/operator/genesis-candidate/genesis.json" | sha256sum | awk '{print $1}')"
[[ "$candidate_sha" == "$raw_candidate_sha" ]] || { echo 'candidate approval hash is not the raw Genesis file hash' >&2; exit 1; }
[[ "$(jq -er '.canonical_genesis_sha256' "$tmp/operator/genesis-candidate.json")" == "$canonical_genesis_sha" ]] \
  || { echo 'candidate receipt canonical Genesis hash is wrong' >&2; exit 1; }
[[ "$candidate_sha" != "$canonical_genesis_sha" ]] \
  || { echo 'fixture did not distinguish raw and canonical Genesis hashes' >&2; exit 1; }

resolved_paths="$(env -i PATH="$tmp/bin:/usr/bin:/bin" ROOT="$ROOT" GDC_HOME="$tmp/operator" \
  GDC_GENESIS_DIR="$tmp/operator/genesis-candidate" GDC_GENESIS_CANDIDATE_SHA256="$candidate_sha" \
  bash -c 'source "$ROOT/scripts/lib.sh"; STATE="$GDC_HOME/state"; GENESIS_NODE=node0; CHAIN_ID=fixture-chain; initialize_project_state_paths; printf "%s\n%s\n" "$GENESIS/genesis.json" "$ACCOUNTS/node0-cold.json"')"
[[ "$resolved_paths" == "$tmp/operator/genesis-candidate/genesis.json"$'\n'"$tmp/operator/accounts/node0-cold.json" ]] \
  || { echo 'load_project path initializer did not select the receipt-bound Genesis and account' >&2; exit 1; }
if env -i PATH="$tmp/bin:/usr/bin:/bin" ROOT="$ROOT" GDC_HOME="$tmp/operator" \
  GDC_GENESIS_DIR="$tmp/operator/genesis-candidate" GDC_GENESIS_CANDIDATE_SHA256="$(printf 'f%.0s' {1..64})" \
  bash -c 'source "$ROOT/scripts/lib.sh"; STATE="$GDC_HOME/state"; GENESIS_NODE=node0; CHAIN_ID=fixture-chain; initialize_project_state_paths' \
  >"$tmp/bad-candidate-path.out" 2>&1; then
  echo 'path initializer accepted a mismatched candidate Genesis SHA-256' >&2; exit 1
fi
grep -Fq 'candidate Genesis path override hash does not match its approved artifact' "$tmp/bad-candidate-path.out"

if env -i "${env_common[@]}" GDC_GENESIS_APPLY_CANDIDATE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  GDC_GENESIS_DEFER_SERVICES=true GDC_RUN_ID=apply-two bash "$tmp/scripts/phase-genesis.sh" >"$tmp/bad-apply.out" 2>"$tmp/bad-apply.err"; then
  echo 'apply accepted an unapproved candidate hash' >&2; exit 1
fi
[[ "$(wc -l <"$tmp/build.log")" == 1 ]] || { echo 'apply rebuilt Genesis' >&2; exit 1; }
grep -Fq 'Genesis candidate hash does not match explicit approval' "$tmp/bad-apply.err"

if env -i "${env_common[@]}" TEST_FAIL_NODE_INSTALL=true GDC_GENESIS_APPLY_CANDIDATE="$candidate_sha" \
  GDC_GENESIS_DEFER_SERVICES=true GDC_RUN_ID=install-failure bash "$tmp/scripts/phase-genesis.sh" \
  >"$tmp/install-failure.out" 2>"$tmp/install-failure.err"; then
  cat "$tmp/install-failure.out" "$tmp/install-failure.err" "$tmp/ssh.log" >&2
  echo 'apply hid a remote Genesis node-install failure' >&2; exit 1
fi
grep -Fq 'install-node.sh' "$tmp/ssh.log"
grep -Eq 'exit 23|exit \(23\)|exit \(exit 23\)' "$tmp/install-failure.err" || grep -Fq 'FAILED Genesis command' "$tmp/install-failure.err"
[[ ! -s "$tmp/services.log" ]] || { echo 'deferred services started after failed node installation' >&2; exit 1; }

env -i "${env_common[@]}" GDC_GENESIS_APPLY_CANDIDATE="$candidate_sha" GDC_GENESIS_DEFER_SERVICES=true GDC_RUN_ID=apply-two \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/apply.out" 2>"$tmp/apply.err"
grep -Fq -- '--genesis-software ' "$tmp/ssh.log"
grep -Fq -- "--genesis-software-sha256 '$software_sha'" "$tmp/ssh.log"
grep -Fq 'genesis-software.json' "$tmp/scp.log"
grep -Fxq 'DAPI_EXPECTED_VERSION=0.2.16-post1' "$tmp/operator/generated/nodes/node0/.env"
grep -Fxq 'DAPI_EXPECTED_COMMIT=136041c81ea8ff38e7620d76af66a7c7fe7eec50' "$tmp/operator/generated/nodes/node0/.env"
grep -Fq 'deferred faucet, gateway, access, monitoring, and site services were not run' "$tmp/apply.out"
[[ "$(wc -l <"$tmp/build.log")" == 1 ]] || { echo 'apply rebuilt Genesis' >&2; exit 1; }
[[ ! -s "$tmp/services.log" ]] || { echo 'deferred services ran during apply' >&2; exit 1; }
! grep -Eq 'edge/install-edge\.sh|agent/install-agent\.sh|monitoring-agent|/deploy/edge|/srv/dai/edge' "$tmp/ssh.log"
! grep -Eq '04-ops/edge-node|04-ops/agent' "$tmp/rsync.log"
! grep -Eq 'edge\.env|agent\.env' "$tmp/scp.log"
[[ ! -e "$tmp/operator/generated/edge/node0.env" && ! -e "$tmp/operator/generated/agents/node0.env" ]]

mkdir -p "$tmp/operator/state/joined"
# Simulate interruption after exact install/start, before the joined marker.
# Expired genesis_time may pass only in explicit installed-candidate resume.
rm -f "$tmp/operator/state/joined/node0"
: >"$tmp/ssh.log"
: >"$tmp/phase-script.log"
: >"$tmp/services.log"
: >"$tmp/faucet-path.log"
if ! env -i "${env_common[@]}" TEST_CLOCK_AFTER=true GDC_GENESIS_RESUME_CANDIDATE="$candidate_sha" GDC_RUN_ID=postinstall-resume \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/postinstall-resume.out" 2>"$tmp/postinstall-resume.err"; then
  cat "$tmp/postinstall-resume.out" "$tmp/postinstall-resume.err" "$tmp/ssh.log" >&2
  exit 1
fi
grep -Fq 'Synchronize the installed MLNode configuration' "$tmp/postinstall-resume.out"
grep -Fq 'READY candidate Genesis participant is ACTIVE; starting only the faucet service' "$tmp/postinstall-resume.out"
grep -Fxq 'faucet' "$tmp/services.log"
grep -Fxq "genesis=$tmp/operator/genesis-candidate/genesis.json" "$tmp/faucet-path.log"
grep -Fxq "node-account=$tmp/operator/accounts/node0-cold.json" "$tmp/faucet-path.log"
grep -Fxq "faucet-account=$tmp/operator/accounts/gdc-faucet-cold.json" "$tmp/faucet-path.log"
grep -Fxq "sha256=$candidate_sha" "$tmp/faucet-path.log"
grep -Fq 'candidate-shared' "$tmp/remote-script.log"
grep -Fq '/srv/dai/deploy/.gdc-genesis-software' "$tmp/remote-script.log"
grep -Fq '/srv/dai/deploy/bootstrap-runtime/node/bin/inferenced' "$tmp/remote-script.log"
grep -Fq 'GDC_JOIN_STATESYNC_ENABLE' "$tmp/remote-script.log"
grep -Fq 'SYNC_WITH_SNAPSHOTS' "$tmp/remote-script.log"
grep -Fq 'MLNODE_IMAGE' "$tmp/remote-script.log"
grep -Fq '/srv/dai/deploy/node-config.json' "$tmp/remote-script.log"
grep -Fq 'rendered-model-config' "$tmp/remote-script.log"
grep -Fxq 'resume-sync' "$tmp/phase-script.log"
grep -Fq 'wait-synced.sh' "$tmp/phase-script.log"
grep -Fq 'restart-api-after-sync.sh' "$tmp/phase-script.log"
grep -Fq 'grant-ml-ops.sh' "$tmp/phase-script.log"
grep -Fq 'wait-active.sh' "$tmp/phase-script.log"
[[ -e "$tmp/operator/state/joined/node0" ]]
[[ "$(wc -l <"$tmp/build.log")" == 1 ]] || { echo 'installed-candidate resume rebuilt Genesis' >&2; exit 1; }
! grep -Eq 'install-node\.sh|start-node\.sh|phase-identities|phase-prepare|phase-qualify' "$tmp/ssh.log" "$tmp/phase-script.log"
[[ ! -s "$tmp/unexpected-ssh.log" ]] || { echo 'installed-candidate resume made an unexpected SSH call' >&2; exit 1; }

if env -i "${env_common[@]}" TEST_CLOCK_AFTER=true GDC_GENESIS_APPLY_CANDIDATE="$candidate_sha" GDC_GENESIS_DEFER_SERVICES=true GDC_RUN_ID=expired-apply \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/expired-apply.out" 2>"$tmp/expired-apply.err"; then
  echo 'apply reused an expired candidate even though a joined marker existed' >&2; exit 1
fi
grep -Fq 'candidate Genesis time has expired' "$tmp/expired-apply.err"

# Refuse a mismatch before ML sync, ACTIVE markers, or faucet deployment.
: >"$tmp/phase-script.log"
: >"$tmp/services.log"
: >"$tmp/faucet-path.log"
if env -i "${env_common[@]}" TEST_REMOTE_CANDIDATE_DRIFT=true GDC_GENESIS_RESUME_CANDIDATE="$candidate_sha" GDC_RUN_ID=resume-drift \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/resume-drift.out" 2>"$tmp/resume-drift.err"; then
  echo 'resume accepted a mismatched installed Genesis candidate' >&2; exit 1
fi
grep -Fq 'GDC_RESUME_GATE_FAIL=candidate-shared-sha256' "$tmp/resume-drift.err"
[[ ! -s "$tmp/phase-script.log" && ! -s "$tmp/services.log" ]]

if env -i "${env_common[@]}" TEST_REMOTE_NODE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GDC_GENESIS_RESUME_CANDIDATE="$candidate_sha" GDC_RUN_ID=resume-identity-drift \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/resume-identity-drift.out" 2>"$tmp/resume-identity-drift.err"; then
  echo 'resume accepted a different running node identity' >&2; exit 1
fi
grep -Fq 'running Genesis reports a different chain ID or node identity' "$tmp/resume-identity-drift.err"
[[ ! -s "$tmp/phase-script.log" && ! -s "$tmp/services.log" ]]

if ! env -i "${env_common[@]}" TEST_CLOCK_AFTER=true GDC_GENESIS_RESUME_CANDIDATE="$candidate_sha" GDC_RUN_ID=resume-three \
  bash "$tmp/scripts/phase-genesis.sh" >"$tmp/resume.out" 2>"$tmp/resume.err"; then
  cat "$tmp/resume.out" "$tmp/resume.err" >&2
  exit 1
fi
grep -Fq 'resuming only the faucet service' "$tmp/resume.out"
[[ "$(wc -l <"$tmp/build.log")" == 1 ]] || { echo 'resume rebuilt Genesis' >&2; exit 1; }
[[ "$(wc -l <"$tmp/services.log")" == 1 ]] || { echo 'resume started services beyond faucet or failed to start faucet' >&2; exit 1; }
grep -Fxq "genesis=$tmp/operator/genesis-candidate/genesis.json" "$tmp/faucet-path.log"
grep -Fxq "node-account=$tmp/operator/accounts/node0-cold.json" "$tmp/faucet-path.log"
grep -Fxq "faucet-account=$tmp/operator/accounts/gdc-faucet-cold.json" "$tmp/faucet-path.log"
[[ ! -s "$tmp/unexpected-ssh.log" ]] || { echo 'phase made an unexpected SSH call' >&2; exit 1; }

# Execute the exact embedded remote resume verifier against a disposable local
# filesystem fixture, including the real root-array node-config shape.
remote_root="$tmp/remote-dai"
mkdir -p "$remote_root/shared" "$remote_root/inference/config" \
  "$remote_root/deploy/bootstrap-runtime/node/bin" "$remote_root/deploy/bootstrap-runtime/api/bin"
cp "$tmp/operator/genesis-candidate/genesis.json" "$remote_root/shared/genesis.json"
cp "$tmp/operator/genesis-candidate/genesis.json" "$remote_root/inference/config/genesis.json"
cp "$tmp/software.json" "$remote_root/deploy/genesis-software.json"
printf 'fixture-core-binary\n' >"$remote_root/deploy/bootstrap-runtime/node/bin/inferenced"
printf 'fixture-api-binary\n' >"$remote_root/deploy/bootstrap-runtime/api/bin/decentralized-api"
core_binary_sha="$(sha256sum "$remote_root/deploy/bootstrap-runtime/node/bin/inferenced" | awk '{print $1}')"
api_binary_sha="$(sha256sum "$remote_root/deploy/bootstrap-runtime/api/bin/decentralized-api" | awk '{print $1}')"
jq --arg core "$core_binary_sha" --arg api "$api_binary_sha" \
  '.binary_sha256.inferenced = $core | .binary_sha256.decentralized_api = $api' \
  "$tmp/software.json" >"$tmp/software.with-binaries.json"
mv "$tmp/software.with-binaries.json" "$tmp/software.json"
software_sha="$(sha256sum "$tmp/software.json" | awk '{print $1}')"
cp "$tmp/software.json" "$remote_root/deploy/genesis-software.json"
jq -n --arg fragment "$software_sha" --slurpfile software "$tmp/software.json" '
  {kind:"gdc-genesis-runtime-install", fragment_sha256:$fragment,
   core:{version:$software[0].spec.deployment.software.components.node.version,
     commit:$software[0].spec.deployment.software.components.node.commit,
     image:$software[0].spec.deployment.software.components.node.image,
     binary_sha256:$software[0].binary_sha256.inferenced},
   dapi:{version:$software[0].spec.deployment.software.components.api.version,
     commit:$software[0].spec.deployment.software.components.api.commit,
     image:$software[0].spec.deployment.software.components.api.image,
     binary_sha256:$software[0].binary_sha256.decentralized_api}}
' >"$remote_root/deploy/.gdc-genesis-software"
jq -n --slurpfile software "$tmp/software.json" '
  ($software[0].spec.deployment.software.model) as $m |
  [{models:{($m.id):{args:["--tensor-parallel-size",($m.tensor_parallel_size|tostring),
    "--dtype",$m.dtype,"--revision",$m.revision,"--max-num-seqs",($m.max_num_seqs|tostring),
    "--gpu-memory-utilization",($m.gpu_memory_utilization|tostring),
    "--max-model-len",($m.context_length|tostring)]}}}]
' >"$remote_root/deploy/node-config.json"
cat >"$remote_root/deploy/.env" <<EOF
NODE_NAME=node0
IS_GENESIS=true
GDC_BOOTSTRAP_SOFTWARE=true
GDC_PROFILE_KIND=release
GDC_JOIN_STATESYNC_ENABLE=false
SYNC_WITH_SNAPSHOTS=false
INFERENCED_IMAGE=$(jq -er .spec.deployment.software.components.node.image "$tmp/software.json")
DAPI_IMAGE=$(jq -er .spec.deployment.software.components.api.image "$tmp/software.json")
MLNODE_IMAGE=$(jq -er .spec.deployment.software.components.mlnode.image "$tmp/software.json")
DAPI_EXPECTED_VERSION=0.2.16-post1
DAPI_EXPECTED_COMMIT=136041c81ea8ff38e7620d76af66a7c7fe7eec50
EOF
mkdir -p "$tmp/proof-bin"
cat >"$tmp/proof-bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"node_info":{"network":"fixture-chain","id":"0123456789abcdef0123456789abcdef01234567"}}}'
EOF
chmod +x "$tmp/proof-bin/curl"
awk '/<<.*REMOTE/{capture=1; next} capture && /^REMOTE$/{exit} capture{print}' \
  "$ROOT/scripts/phase-genesis.sh" | sed "s|/srv/dai|$remote_root|g" >"$tmp/remote-proof.sh"
candidate_sha="$(sha256sum "$remote_root/shared/genesis.json" | awk '{print $1}')"
PATH="$tmp/proof-bin:/usr/bin:/bin" bash "$tmp/remote-proof.sh" "$candidate_sha" "$software_sha" \
  node0 0.2.16-post1 136041c81ea8ff38e7620d76af66a7c7fe7eec50 >"$tmp/remote-proof.out"
jq -e '.result.node_info.network == "fixture-chain"' "$tmp/remote-proof.out" >/dev/null
jq '.[0].models["Qwen/Qwen2.5-7B-Instruct"].args += ["--incorrect-drift"]' \
  "$remote_root/deploy/node-config.json" >"$tmp/node-config-drift.json"
mv "$tmp/node-config-drift.json" "$remote_root/deploy/node-config.json"
if PATH="$tmp/proof-bin:/usr/bin:/bin" bash "$tmp/remote-proof.sh" "$candidate_sha" "$software_sha" \
  node0 0.2.16-post1 136041c81ea8ff38e7620d76af66a7c7fe7eec50 >"$tmp/remote-proof-drift.out" 2>"$tmp/remote-proof-drift.err"; then
  echo 'remote resume proof accepted drifted rendered model arguments' >&2; exit 1
fi
grep -Fq 'GDC_RESUME_GATE_FAIL=rendered-model-config' "$tmp/remote-proof-drift.err"
echo 'Genesis candidate boundary tests: PASS'
