#!/usr/bin/env bash
# Exercise the actual post-canary verifier invocation without a Host. A
# canary that is caught up has its own current-checkpoint proof; the original
# receipt's TTL must not be reapplied at this boundary.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

remote="$tmp/remote"
mkdir -p "$remote"
IDENTITY="$tmp/identity.json"
jq -n '{node_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$IDENTITY"
cat >"$remote/verify-join-lineage-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == http://127.0.0.1:26657 ]]
[[ "$2" == "$GDC_TEST_REMOTE/lineage-receipt.json" ]]
[[ "$3" == --resume-current ]]
touch "$GDC_TEST_CALLED"
EOF
chmod 0755 "$remote/verify-join-lineage-state.sh"

run_verifier() (
  export NODE=fixture REMOTE="$remote" GDC_TEST_REMOTE="$remote" GDC_TEST_CALLED="$tmp/called"
  join_bootstrap_mode=state_sync
  join_canary_transport_step() {
    [[ "$1" == canary_verify && "$2" == canary_verified ]]
    shift 2
    "$@"
  }
  ssh() {
    [[ "$1" == fixture ]]
    shift
    bash -c "$1"
  }
  eval "$(sed -n '/^verify_caught_up_canary_lineage() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh")"
  verify_caught_up_canary_lineage
)

run_verifier
[[ -f "$tmp/called" ]] || { echo 'caught-up canary did not run the current-checkpoint verifier' >&2; exit 1; }

# The explicit single-Genesis-seed opt-in takes the separate full-sync
# common-checkpoint verifier, never the state-sync lineage verifier.
mkdir -p "$remote"
cat >"$remote/verify-genesis-single-seed-canary.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == "$GDC_TEST_REMOTE/lineage-receipt.json" ]]
[[ "$2" == http://127.0.0.1:26657 ]]
[[ "$3" =~ ^[0-9a-f]{40}$ ]]
[[ "$4" == "$GDC_TEST_REMOTE/genesis-single-seed-canary.json" ]]
touch "$GDC_TEST_FULL_SYNC_CALLED"
EOF
chmod 0755 "$remote/verify-genesis-single-seed-canary.sh"
(
  export NODE=fixture REMOTE="$remote" GDC_TEST_REMOTE="$remote" GDC_TEST_FULL_SYNC_CALLED="$tmp/full-sync-called" IDENTITY
  join_bootstrap_mode=genesis-single-seed
  join_canary_transport_step() { [[ "$1" == canary_verify && "$2" == canary_verified ]]; shift 2; "$@"; }
  ssh() { [[ "$1" == fixture ]]; shift; bash -c "$1"; }
  eval "$(sed -n '/^verify_caught_up_canary_lineage() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh")"
  verify_caught_up_canary_lineage
)
[[ -f "$tmp/full-sync-called" ]] || { echo 'full-sync canary did not run its single-seed verifier' >&2; exit 1; }

# Full-sync runtime config is created by the starting node container. Retry
# only an unreadable/empty file; once content is available, wrong settings
# must fail immediately rather than being retried as a readiness condition.
mkdir -p "$tmp/config-bin" "$tmp/config-deploy"
printf '%s\n' 'SYNC_WITH_SNAPSHOTS=false' 'GDC_JOIN_STATESYNC_ENABLE=false' >"$tmp/config-deploy/.env"
eval "$(sed -n '/^verify_full_sync_runtime_config() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh" \
  | sed "s|cd /srv/dai/deploy|cd '$tmp/config-deploy'|")"
cat >"$tmp/config-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
attempt=0
[[ ! -r "$GDC_TEST_CONFIG_ATTEMPT" ]] || attempt="$(<"$GDC_TEST_CONFIG_ATTEMPT")"
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$GDC_TEST_CONFIG_ATTEMPT"
(( attempt >= GDC_TEST_CONFIG_READY_AFTER )) || exit 1
printf '%s\n' "$GDC_TEST_CONFIG_CONTENT"
EOF
cat >"$tmp/config-bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$tmp/config-bin/docker" "$tmp/config-bin/sleep"
run_config_gate() (
  export NODE=fixture GDC_TEST_CONFIG_ATTEMPT="$tmp/config-attempt" GDC_TEST_CONFIG_READY_AFTER="$1"
  export GDC_TEST_CONFIG_CONTENT="$2" PATH="$tmp/config-bin:$PATH"
  join_canary_transport_step() { [[ "$1" == canary_verify && "$2" == canary_caught_up ]]; shift 2; "$@"; }
  ssh() { [[ "$1" == fixture && "$2" == 'bash -s' ]]; shift 2; bash -s; }
  verify_full_sync_runtime_config
)
valid_config=$'enable = false\nrpc_servers = ""\ntrust_height = 0'
run_config_gate 3 "$valid_config"
[[ "$(<"$tmp/config-attempt")" == 3 ]] || { echo 'full-sync config readiness did not retry missing config' >&2; exit 1; }
rm -f "$tmp/config-attempt"
if run_config_gate 1 $'enable = true\nrpc_servers = "seed"\ntrust_height = 10' >"$tmp/wrong-config.out" 2>&1; then
  echo 'full-sync config verifier accepted state-sync settings' >&2
  exit 1
fi
[[ "$(<"$tmp/config-attempt")" == 1 ]] || { echo 'invalid full-sync config was retried instead of rejected' >&2; exit 1; }
rm -f "$tmp/config-attempt"
if run_config_gate 31 "$valid_config" >"$tmp/missing-config.out" 2>&1; then
  echo 'full-sync config readiness unexpectedly passed without a readable config' >&2
  exit 1
fi
[[ "$(<"$tmp/config-attempt")" == 30 ]] || { echo 'full-sync config readiness did not stop at its bounded retry limit' >&2; exit 1; }

# The refresh immediately before a full-sync canary must carry the same sole
# source RPC through both live observation and lineage preflight.
refresh_root="$tmp/refresh-root"
refresh_run="$tmp/refresh-run"
refresh_state="$tmp/refresh-state"
phase_join_source="$ROOT/scripts/phase-join.sh"
mkdir -p "$refresh_root/scripts" "$refresh_run" "$refresh_state"
cat >"$refresh_root/scripts/observe-network-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >"$GDC_TEST_OBSERVE_ARGS"
while (($#)); do case "$1" in --output) output="$2"; shift 2 ;; *) shift ;; esac; done
cp "$GDC_TEST_OBSERVATION" "$output"
EOF
cat >"$refresh_root/scripts/preflight-join-lineage.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >"$GDC_TEST_PREFLIGHT_ARGS"
while (($#)); do case "$1" in --receipt) receipt="$2"; shift 2 ;; --env) env_file="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' '{"kind":"fixture-lineage"}' >"$receipt"
printf '%s\n' 'GDC_JOIN_BOOTSTRAP_MODE=full_sync' 'GDC_JOIN_LINEAGE_RECEIPT='"$receipt" >"$env_file"
EOF
chmod 0755 "$refresh_root/scripts/observe-network-state.sh" "$refresh_root/scripts/preflight-join-lineage.sh"
refresh_rpc='https://node0.example.test/chain-rpc'
refresh_bootstrap="$tmp/refresh-bootstrap.json"
printf '%s\n' '{"chain_id":"fixture","genesis":{"sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000"}]}' >"$refresh_bootstrap"
refresh_observation="$tmp/refresh-observation.json"
jq -n '{network_state_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",bootstrap:{url:"https://bootstrap.example.test/bootstrap.json",chain_id:"fixture",document_sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",genesis_sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},runtime:{core:{version:"0.2.16-post1",commit:"136041c81ea8ff38e7620d76af66a7c7fe7eec50"},dapi:{version:"0.2.16-post1",commit:"136041c81ea8ff38e7620d76af66a7c7fe7eec50"}},result:{state:"ready",reason:"none"}}' >"$refresh_observation"
(
  export ROOT="$refresh_root" RUN="$refresh_run" STATE="$refresh_state" NODE=fixture GDC_RUN_ID=refresh-fixture
  export GDC_JOIN_BOOTSTRAP_FILE="$refresh_bootstrap" GDC_JOIN_BOOTSTRAP_MODE=full_sync GDC_JOIN_SOURCE_RPC="$refresh_rpc"
  export GDC_JOIN_PROFILE="$tmp/refresh-profile.json"
  export GDC_TEST_OBSERVE_ARGS="$tmp/observe-args" GDC_TEST_PREFLIGHT_ARGS="$tmp/preflight-args" GDC_TEST_OBSERVATION="$refresh_observation"
  join_bootstrap_mode=genesis-single-seed
  # shellcheck disable=SC2034 # Consumed by the phase function extracted below.
  JOIN_OBSERVATION="$refresh_observation"
  step() { :; }
  verify_join_bootstrap_authority() { :; }
  eval "$(sed -n '/^refresh_lineage_for_canary() {$/,/^}$/p' "$phase_join_source")"
  refresh_lineage_for_canary
)
grep -Fq -- "--source-rpc $refresh_rpc" "$tmp/observe-args"
grep -Fq -- "--join-profile $tmp/refresh-profile.json" "$tmp/observe-args"
grep -Fq -- "--source-rpc $refresh_rpc" "$tmp/preflight-args"

# The control runs the same lifecycle boundary with the current-checkpoint
# marker removed. The remote verifier makes the old TTL-rechecking call fail.
if (
  export NODE=fixture REMOTE="$remote" GDC_TEST_REMOTE="$remote" GDC_TEST_CALLED="$tmp/control-called"
  # shellcheck disable=SC2034 # Consumed by the phase function extracted below.
  join_bootstrap_mode=state_sync
  join_canary_transport_step() { [[ "$1" == canary_verify && "$2" == canary_verified ]]; shift 2; "$@"; }
  ssh() { [[ "$1" == fixture ]]; shift; bash -c "$1"; }
  eval "$(sed -n '/^verify_caught_up_canary_lineage() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh" | sed 's/ --resume-current//')"
  verify_caught_up_canary_lineage
) >/dev/null 2>&1; then
  echo 'expired consumed receipt control unexpectedly passed' >&2
  exit 1
fi
[[ ! -e "$tmp/control-called" ]] || { echo 'expired consumed receipt control reached the verifier' >&2; exit 1; }

# Verify the actual fresh full-sync authority function with different raw
# distribution and canonical identity hashes, plus independent mismatch
# refusals. This exercises the chain-identity boundary without SSH or a Host.
hash_root="$tmp/hash-contract"
mkdir -p "$hash_root/genesis" "$hash_root/state"
cat >"$hash_root/genesis/genesis.json" <<'EOF'
{"app_name":"fixture","app_version":"v1","chain_id":"fixture","initial_height":1,"app_hash":null,"consensus":{"params":{"block":{"max_bytes":"22020096"}}}}
EOF
hash_raw="$(sha256sum "$hash_root/genesis/genesis.json" | awk '{print $1}')"
hash_identity="$(jq -eS 'del(.app_name,.app_version) | if has("app_hash") then .app_hash=(.app_hash//"") else . end | if has("initial_height") then .initial_height=(.initial_height|tostring) else . end | if .consensus.params? then .consensus_params=.consensus.params | del(.consensus) else . end' "$hash_root/genesis/genesis.json" | sha256sum | awk '{print $1}')"
hash_node=0123456789abcdef0123456789abcdef01234567
hash_rpc=https://seed.example.test/chain-rpc
hash_p2p=tcp://seed.example.test:5000
jq -n --arg raw "$hash_raw" --arg node "$hash_node" --arg rpc "$hash_rpc" --arg p2p "$hash_p2p" \
  '{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json",bootstrap_mode:"genesis-single-seed",chain_id:"fixture",genesis:{sha256:$raw},seeds:[{node_id:$node,rpc:$rpc,p2p:$p2p,api:"https://seed.example.test"}],brokers:[]}' >"$hash_root/bootstrap.json"
hash_bootstrap_sha="$(sha256sum "$hash_root/bootstrap.json" | awk '{print $1}')"
printf '%s@%s\n' "$hash_node" "${hash_p2p#tcp://}" >"$hash_root/genesis/genesis-seeds.txt"
jq -n --arg chain "fixture" --arg raw "$hash_raw" --arg identity "$hash_identity" --arg bootstrap "$hash_bootstrap_sha" \
  '{spec:{network:{chain_id:$chain,genesis_sha256:$identity,bootstrap_genesis_sha256:$raw,bootstrap_sha256:$bootstrap}}}' >"$hash_root/profile.json"
jq -n --arg chain "fixture" --arg raw "$hash_raw" --arg identity "$hash_identity" --arg node "$hash_node" --arg rpc "$hash_rpc" --arg p2p "$hash_p2p" \
  '{schema_version:1,kind:"gdc-host-join-lineage-preflight",runtime:{observation_sha256:("f"*64)},bootstrap:{mode:"full_sync",chain_id:$chain,genesis_sha256:$identity,distribution_sha256:$raw,seed:{node_id:$node,rpc_url:$rpc,p2p:$p2p}},trust_authority:{kind:"genesis_single_seed",rpc_url:$rpc},fault_domains:[{id:"genesis-single-seed",rpc_url:$rpc,chain_id:$chain,genesis_sha256:$identity}],checkpoints:null}' \
  >"$hash_root/state/lineage-preflight.json"
hash_receipt_sha="$(sha256sum "$hash_root/state/lineage-preflight.json" | awk '{print $1}')"
run_bootstrap_authority() (
  local receipt_path="${3:-$hash_root/state/lineage-preflight.json}"
  export NODE=fixture CHAIN_ID=fixture GENESIS="$hash_root/genesis" STATE="$hash_root/state"
  export GDC_JOIN_BOOTSTRAP_FILE="$hash_root/bootstrap.json" GDC_JOIN_BOOTSTRAP_MODE=full_sync
  export GDC_JOIN_BOOTSTRAP_SHA256="$hash_bootstrap_sha" GDC_JOIN_PROFILE="$1"
  export GDC_JOIN_SOURCE_RPC="$hash_rpc" GDC_JOIN_RPC_SERVER_1="$hash_rpc/" GDC_JOIN_RPC_SERVER_2=''
  export GDC_JOIN_TRUST_HEIGHT=0 GDC_JOIN_TRUST_HASH='' GDC_JOIN_SNAPSHOT_PEERS='' GDC_JOIN_TRUSTED_BLOCK_PERIOD=0
  export GDC_JOIN_LINEAGE_RECEIPT="$receipt_path" GDC_JOIN_LINEAGE_RECEIPT_SHA256="$2"
  die() { echo "$*" >&2; exit 1; }
  genesis_sha256() { jq -eS 'del(.app_name,.app_version) | if has("app_hash") then .app_hash=(.app_hash//"") else . end | if has("initial_height") then .initial_height=(.initial_height|tostring) else . end | if .consensus.params? then .consensus_params=.consensus.params | del(.consensus) else . end' "$1" | sha256sum | awk '{print $1}'; }
  eval "$(sed -n '/^verify_join_bootstrap_authority() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh")"
  verify_join_bootstrap_authority
)
run_bootstrap_authority "$hash_root/profile.json" "$hash_receipt_sha"
jq '.spec.network.genesis_sha256 = ("e"*64)' "$hash_root/profile.json" >"$hash_root/profile-wrong-identity.json"
if run_bootstrap_authority "$hash_root/profile-wrong-identity.json" "$hash_receipt_sha" >/dev/null 2>&1; then
  echo 'full-sync authority accepted wrong canonical profile identity' >&2; exit 1
fi
jq '.spec.network.bootstrap_genesis_sha256 = ("e"*64)' "$hash_root/profile.json" >"$hash_root/profile-wrong-distribution.json"
if run_bootstrap_authority "$hash_root/profile-wrong-distribution.json" "$hash_receipt_sha" >/dev/null 2>&1; then
  echo 'full-sync authority accepted wrong raw profile distribution digest' >&2; exit 1
fi
jq '.bootstrap.distribution_sha256 = ("e"*64)' "$hash_root/state/lineage-preflight.json" >"$hash_root/state/lineage-preflight-wrong.json"
if run_bootstrap_authority "$hash_root/profile.json" "$(sha256sum "$hash_root/state/lineage-preflight-wrong.json" | awk '{print $1}')" "$hash_root/state/lineage-preflight-wrong.json" >/dev/null 2>&1; then
  echo 'full-sync authority accepted lineage with wrong raw distribution digest' >&2; exit 1
fi

# Exercise the actual GDC confirmation-observer dispatcher handoff. A failed
# confirm must return before the later final-profile promotion point.
confirm_root="$tmp/confirm-observation"
mkdir -p "$confirm_root/mock-root/scripts" "$confirm_root/state"
cat >"$confirm_root/mock-root/scripts/observe-network-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${GDC_JOIN_PROFILE:-}" == "$GDC_TEST_CANDIDATE_PROFILE" ]]
printf '%s\n' "$*" >"$GDC_TEST_OBSERVER_ARGS"
[[ "${GDC_TEST_OBSERVER_FAIL:-false}" != true ]] || exit 42
while (($#)); do case "$1" in --output) output="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' '{"kind":"confirm-observation"}' >"$output"
EOF
chmod 0755 "$confirm_root/mock-root/scripts/observe-network-state.sh"
jq -n '{software:{}}' >"$confirm_root/bootstrap.json"
printf '%s\n' '{}' >"$confirm_root/candidate-profile.json"
run_confirm_observer() (
  export ROOT="$confirm_root/mock-root" GDC_HOME="$confirm_root/operator" GDC_RUN_ID=confirm-fixture
  export GDC_TEST_CANDIDATE_PROFILE="$confirm_root/candidate-profile.json"
  export GDC_TEST_OBSERVER_ARGS="$confirm_root/observer-args"
  export join_candidate_profile="$confirm_root/candidate-profile.json"
  # shellcheck disable=SC2034 # Inputs to the dispatcher function extracted below.
  join_bootstrap_file="$confirm_root/bootstrap.json" join_bootstrap_url=https://bootstrap.example.test/bootstrap.json join_chain_id=fixture
  # shellcheck disable=SC2034 # Array input to the dispatcher function extracted below.
  join_source_args=()
  eval "$(sed -n '/^wait_for_join_software_observation() {$/,/^}$/p' "$GDC_ROOT/gdc.sh")"
  wait_for_join_software_observation confirm-fixture "$confirm_root/state/confirmed-observation.json" 100 1
)
GDC_ROOT="$ROOT"
run_confirm_observer
grep -Fq -- "--join-profile $confirm_root/candidate-profile.json" "$confirm_root/observer-args"
[[ -s "$confirm_root/state/confirmed-observation.json" ]]
if GDC_TEST_OBSERVER_FAIL=true run_confirm_observer >"$confirm_root/failure.out" 2>&1; then
  echo 'GDC confirmation observer failure unexpectedly passed' >&2; exit 1
fi
[[ ! -e "$confirm_root/state/join-profile.v1.json" ]] || { echo 'failed confirm promoted a final Join Profile' >&2; exit 1; }

printf 'PASS caught-up signerless canary uses current-checkpoint lineage verification and distinguishes raw distribution from canonical identity\n'
