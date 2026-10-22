#!/usr/bin/env bash
# Exercise a retained signerless canary continuation with closed transport.
# The fixture permits exactly the remote lifecycle steps required to reach the
# existing canonical continuation and proves a failed current checkpoint or a
# running signer cannot promote or start Core.
set -Eeuo pipefail

PRODUCT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$tmp/bin"
cp "$PRODUCT_ROOT/scripts/phase-join-resume-caught-up-canary.sh" "$kit/scripts/"
cp "$PRODUCT_ROOT/scripts/lib-join-resume.sh" "$kit/scripts/"
cp "$PRODUCT_ROOT/scripts/lib-post-sync-join.sh" "$kit/scripts/"
cp "$PRODUCT_ROOT/scripts/verify-genesis-single-seed-canary.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  IDENTITIES="$GDC_TEST_OPERATOR/state/identities"
  ACCOUNTS="$GDC_TEST_OPERATOR/accounts"
  STATE="$GDC_TEST_OPERATOR/state"
}
node_name() { printf '%s\n' "$1"; }
step() { printf 'step:%s\n' "$*" >>"$GDC_TEST_EVENTS"; }
EOF
cat >"$kit/scripts/verify-join-receipt-chain.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == --receipt-dir && -d "$2" ]] || exit 64
head="$(find "$2" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)"
jq -cn --arg state "$(jq -er .state "$head")" '{last_state:$state,signer_ever_started:false}'
EOF
cat >"$kit/scripts/record-join-receipt.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while (($#)); do
  case "$1" in
    --receipt-dir) receipts="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    *) exit 64 ;;
  esac
done
sequence="$(find "$receipts" -maxdepth 1 -type f -name '*.json' -printf x | wc -c)"
cp "$input" "$receipts/$(printf '%04d' "$((sequence + 1))")-fixture.json"
EOF
for continuation in phase-join-resume-new-canonical.sh phase-join-resume-canonical.sh; do
  cat >"$kit/scripts/$continuation" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'continuation:%s:%s\n' "$(basename "$0")" "$*" >>"$GDC_TEST_EVENTS"
EOF
done
chmod 0755 "$kit/scripts"/*.sh

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" != -T ]] || shift
[[ "$1" == fixture ]] || exit 41
shift
[[ $# == 1 ]] || exit 42
command="$1"
printf 'ssh:%s\n' "$command" >>"$GDC_TEST_EVENTS"
case "$command" in
  "cd '/srv/dai/deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")
    [[ "${GDC_TEST_SIGNER:-off}" != running ]] || printf 'tmkms-container\n'
    ;;
  "cd '/srv/dai/deploy' && docker compose --env-file .env -f compose.yaml ps -q node") printf 'canary-container\n' ;;
  "rm -rf '/tmp/gdc-"*"-canary-resume-fixture-run-fixture' && mkdir -p '/tmp/gdc-"*"-canary-resume-fixture-run-fixture'") ;;
  "cd '/srv/dai/deploy' && ./wait-state-sync-canary.sh '/srv/dai/deploy' 'https://seed.example.test/chain-rpc'")
    [[ "${GDC_TEST_WAIT:-pass}" == pass ]] || exit 61
    printf 'PASS mock full-sync caught-up wait\n'
    ;;
  "bash -s -- '/srv/dai/deploy'")
    [[ "${GDC_TEST_CONFIG_READY:-true}" == true ]] || exit 62
    env PATH="$GDC_TEST_REMOTE_BIN:$PATH" \
      GDC_TEST_CONFIG_FILE="$GDC_TEST_CONFIG_FILE" \
      GDC_TEST_CONFIG_ATTEMPT_FILE="$GDC_TEST_CONFIG_ATTEMPT_FILE" \
      GDC_TEST_CONFIG_READY_AFTER="$GDC_TEST_CONFIG_READY_AFTER" \
      bash -s -- "$GDC_TEST_REMOTE_DEPLOY"
    ;;
  *verify-genesis-single-seed-canary.sh*)
    [[ "$command" == *" http://127.0.0.1:26657 "* ]] || exit 64
    [[ "${GDC_TEST_SINGLE_SEED_VERIFY:-pass}" == pass ]] || exit 63
    ;;
  "bash '/tmp/gdc-"*"-canary-resume-fixture-run-fixture/verify-join-lineage-state.sh' http://127.0.0.1:26657 '/tmp/gdc-"*"-canary-resume-fixture-run-fixture/lineage-receipt.json' --resume-current")
    [[ "${GDC_TEST_CURRENT:-pass}" == pass ]]
    ;;
  "cd '/srv/dai/deploy' && ./verify-state-sync-config.sh '/srv/dai/deploy' '/tmp/gdc-"*"-canary-resume-fixture-run-fixture/lineage-receipt.json' --consumed-trust") ;;
  "cd '/srv/dai/deploy' && ./record-state-sync-canary.sh '/srv/dai/deploy' '/tmp/gdc-"*"-canary-resume-fixture-run-fixture/lineage-receipt.json'") ;;
  "sudo '/srv/dai/deploy/stop-state-sync-canary.sh' '/srv/dai/deploy'") : >"$GDC_TEST_STOPPED" ;;
  "sudo '/srv/dai/deploy/promote-state-sync-generation.sh' 'fixture' '/srv/dai/data.generations/fixture-run' '/srv/dai/data'") [[ -e "$GDC_TEST_STOPPED" ]] && : >"$GDC_TEST_PROMOTED" ;;
  "cd '/srv/dai/deploy' && ./ensure-warm-key.sh --expected-address 'gonka1fixturewarm'")
    [[ "$(cat)" == 'fixture warm mnemonic' ]]
    ;;
  "cd '/srv/dai/deploy' && ./start-node.sh") [[ -e "$GDC_TEST_PROMOTED" ]] && : >"$GDC_TEST_STARTED" ;;
  *) exit 43 ;;
esac
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'scp:%s\n' "$*" >>"$GDC_TEST_EVENTS"
[[ "$1" == -q && $# == 3 ]] || exit 51
if [[ "$2" == "$GDC_TEST_KIT/scripts/verify-join-lineage-state.sh" && "$3" =~ ^fixture:/tmp/gdc-(new|restore)-canary-resume-fixture-run-fixture/verify-join-lineage-state\.sh$ ]]; then
  exit 0
fi
if [[ "$2" == "$GDC_TEST_KIT/scripts/verify-genesis-single-seed-canary.sh" && "$3" =~ ^fixture:/tmp/gdc-(new|restore)-canary-resume-fixture-run-fixture/verify-genesis-single-seed-canary\.sh$ ]]; then
  exit 0
fi
if [[ "$2" == "$GDC_TEST_RUN/lineage-preflight-canary.v1.json" && "$3" =~ ^fixture:/tmp/gdc-(new|restore)-canary-resume-fixture-run-fixture/lineage-receipt\.json$ ]]; then
  exit 0
fi
if [[ "$2" =~ ^fixture:/tmp/gdc-(new|restore)-canary-resume-fixture-run-fixture/lineage-receipt\.json$ && "$3" == "$GDC_TEST_RUN/lineage-state-sync-receipt.json" ]]; then
  exit 0
fi
if [[ "$2" =~ ^fixture:/tmp/gdc-(new|restore)-canary-resume-fixture-run-fixture/genesis-single-seed-canary\.json$ && "$3" == "$GDC_TEST_RUN/genesis-single-seed-canary.json" ]]; then
  jq -n '{schema_version:1,kind:"gdc-genesis-single-seed-canary",chain_id:"gonka-devnet-community",genesis_sha256:("c"*64),seed_node_id:("b"*40),seed_rpc:"https://seed.example.test/chain-rpc",join_node_id:("a"*40),common_height:123,common_block:{height:123,block_id:("1"*64),app_hash:("2"*64)}}' >"$3"
  exit 0
fi
exit 52
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
attempt=0
[[ ! -r "$GDC_TEST_CONFIG_ATTEMPT_FILE" ]] || attempt="$(<"$GDC_TEST_CONFIG_ATTEMPT_FILE")"
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$GDC_TEST_CONFIG_ATTEMPT_FILE"
(( attempt >= GDC_TEST_CONFIG_READY_AFTER )) || exit 1
cat "$GDC_TEST_CONFIG_FILE"
EOF
chmod 0755 "$tmp/bin"/*

write_receipt() {
  local destination="$1" operation="$2" state="$3" profile="$4" observation="$5"
  jq -cn --arg operation "$operation" --arg state "$state" \
    --arg profile "$(sha256sum "$profile" | awk '{print $1}')" \
    --arg observation "$(sha256sum "$observation" | awk '{print $1}')" '
    {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:$operation,node_name:"fixture",state:$state,
     join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:"fixture-run",
     identity_fingerprints:{participant_address:"gonka1fixtureparticipant",consensus_pubkey:"",p2p_node_id:"",warm_address:""},
     signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$destination"
}

run_case() {
  local label="$1" operation="$2" current="$3" signer="$4" mode="${5:-state_sync}" state="${6:-CANARY_CAUGHT_UP}" verify="${7:-pass}" tweak="${8:-none}" no_ssh=false rc=0
  local operator="$tmp/$label/operator" run="$tmp/$label/run" profile="$tmp/$label/profile.json"
  local remote_deploy="$tmp/$label/remote-deploy" remote_bin="$tmp/$label/remote-bin" observation="$tmp/$label/observation.json"
  mkdir -p "$operator/state/identities" "$operator/accounts" "$operator/mnemonics" "$run/receipts" "$remote_deploy" "$remote_bin"
  printf '%s\n' '{"warm_address":"gonka1fixturewarm","node_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$operator/state/identities/fixture.json"
  printf '%s\n' '{"address":"gonka1fixtureparticipant"}' >"$operator/accounts/fixture-cold.json"
  printf '%s\n' 'fixture warm mnemonic' >"$operator/mnemonics/fixture-warm.mnemonic"
  jq -cn '{spec:{network:{chain_id:"gonka-devnet-community",genesis_sha256:("c"*64),bootstrap_genesis_sha256:("d"*64),bootstrap_sha256:("d"*64),bootstrap_url:"https://bootstrap.example.test/bootstrap.json"},state_acquisition:{mode:"pending",providers:[],minimum_providers:0}}}' >"$profile"
  printf '%s\n' '{}' >"$observation"
  if [[ "$mode" == full_sync ]]; then
    jq -n '{network_state_id:("e"*64),bootstrap:{url:"https://bootstrap.example.test/bootstrap.json",document_sha256:("d"*64),chain_id:"gonka-devnet-community",genesis_sha256:("d"*64),chain_identity_sha256:("c"*64)},runtime:{core:{version:"test"}}}' >"$run/network-observation-canary.v1.json"
    observation_sha="$(sha256sum "$run/network-observation-canary.v1.json" | awk '{print $1}')"
    jq -n --arg observation "$observation_sha" '{schema_version:1,kind:"gdc-host-join-lineage-preflight",bootstrap:{mode:"full_sync",chain_id:"gonka-devnet-community",genesis_sha256:("c"*64),distribution_sha256:("d"*64),seed:{node_id:("b"*40),rpc_url:"https://seed.example.test/chain-rpc",p2p:"tcp://seed.example.test:5000"}},fault_domains:[{id:"genesis-single-seed",rpc_url:"https://seed.example.test/chain-rpc",host:"seed.example.test",port:26657,ip:"192.0.2.10",chain_id:"gonka-devnet-community",genesis_sha256:("c"*64)}],trust_authority:{kind:"genesis_single_seed",rpc_url:"https://seed.example.test/chain-rpc"},runtime:{network_fingerprint:("e"*64),source:{kind:"bootstrap_software",id:("e"*64)},observation_sha256:$observation},checkpoints:null}' >"$run/lineage-preflight-canary.v1.json"
  else
    jq -n '{bootstrap:{mode:"state_sync"}}' >"$run/lineage-preflight-canary.v1.json"
  fi
  write_receipt "$run/receipts/0001-fixture.json" "$operation" RUN_CREATED "$profile" "$observation"
  write_receipt "$run/receipts/0002-fixture.json" "$operation" "$state" "$profile" "$observation"
  case "$tweak" in
    profile-mismatch)
      jq '.spec.network.genesis_sha256 = ("d"*64)' "$profile" >"$profile.tmp"
      mv "$profile.tmp" "$profile"
      no_ssh=true
      ;;
    lineage-mismatch)
      jq '.bootstrap.genesis_sha256 = ("d"*64)' "$run/lineage-preflight-canary.v1.json" >"$run/lineage.tmp"
      mv "$run/lineage.tmp" "$run/lineage-preflight-canary.v1.json"
      no_ssh=true
      ;;
    observation-raw-mismatch)
      jq '.bootstrap.genesis_sha256 = ("e"*64)' "$run/network-observation-canary.v1.json" >"$run/observation.tmp"
      mv "$run/observation.tmp" "$run/network-observation-canary.v1.json"
      ;;
    observation-canonical-mismatch)
      jq '.bootstrap.chain_identity_sha256 = ("e"*64)' "$run/network-observation-canary.v1.json" >"$run/observation.tmp"
      mv "$run/observation.tmp" "$run/network-observation-canary.v1.json"
      ;;
    distribution-mismatch)
      jq '.bootstrap.distribution_sha256 = ("e"*64)' "$run/lineage-preflight-canary.v1.json" >"$run/lineage.tmp"
      mv "$run/lineage.tmp" "$run/lineage-preflight-canary.v1.json"
      ;;
    existing-proof)
      printf '%s\n' 'retained immutable evidence' >"$run/genesis-single-seed-canary.json"
      no_ssh=true
      ;;
    none) ;;
    *) echo "unknown fixture tweak: $tweak" >&2; return 1 ;;
  esac
  : >"$tmp/$label-events"
  rm -f "$tmp/$label-stopped" "$tmp/$label-promoted" "$tmp/$label-started" "$tmp/$label/config-attempts"
  printf 'SYNC_WITH_SNAPSHOTS=false\nGDC_JOIN_STATESYNC_ENABLE=false\n' >"$remote_deploy/.env"
  printf 'enable = false\nrpc_servers = ""\ntrust_height = 0\n' >"$tmp/$label/full-sync-config.toml"
  cat >"$remote_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
attempt=0
[[ ! -r "$GDC_TEST_CONFIG_ATTEMPT_FILE" ]] || attempt="$(<"$GDC_TEST_CONFIG_ATTEMPT_FILE")"
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$GDC_TEST_CONFIG_ATTEMPT_FILE"
(( attempt >= GDC_TEST_CONFIG_READY_AFTER )) || exit 1
cat "$GDC_TEST_CONFIG_FILE"
EOF
  chmod 0755 "$remote_bin/docker"
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
    GDC_TEST_RUN="$run" GDC_TEST_EVENTS="$tmp/$label-events" GDC_TEST_STOPPED="$tmp/$label-stopped" \
    GDC_TEST_PROMOTED="$tmp/$label-promoted" GDC_TEST_STARTED="$tmp/$label-started" \
    GDC_TEST_CURRENT="$current" GDC_TEST_SIGNER="$signer" GDC_TEST_SINGLE_SEED_VERIFY="$verify" \
    GDC_TEST_REMOTE_DEPLOY="$remote_deploy" GDC_TEST_REMOTE_BIN="$remote_bin" \
    GDC_TEST_CONFIG_FILE="$tmp/$label/full-sync-config.toml" GDC_TEST_CONFIG_ATTEMPT_FILE="$tmp/$label/config-attempts" \
    GDC_TEST_CONFIG_READY_AFTER=2 GDC_HOME="$operator" GDC_RUN_ID=fixture-run \
    GDC_JOIN_PROFILE="$profile" GDC_JOIN_OBSERVATION="$observation" GDC_JOIN_RESULT_OUTPUT="$run/join-result.json" \
    "$kit/scripts/phase-join-resume-caught-up-canary.sh" fixture "$run" "$operation" >"$tmp/$label.out" 2>"$tmp/$label.err" || rc=$?
  events="$(<"$tmp/$label-events")"
  if [[ "$current" == pass && "$signer" == off && "$verify" == pass && "$tweak" == none ]]; then
    [[ "$rc" == 0 ]] || { cat "$tmp/$label.err" >&2; return 1; }
    [[ -e "$tmp/$label-stopped" && -e "$tmp/$label-promoted" && -e "$tmp/$label-started" ]]
    [[ "$(jq -r .state "$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)")" == CANONICAL_RUNNING ]]
    if [[ "$operation" == new ]]; then
      [[ "$events" == *'continuation:phase-join-resume-new-canonical.sh:fixture '* ]]
    else
      [[ "$events" == *'continuation:phase-join-resume-canonical.sh:fixture '* ]]
    fi
    if [[ "$mode" == full_sync ]]; then
      [[ -s "$run/genesis-single-seed-canary.json" ]]
      cmp -s "$run/lineage-preflight-canary.v1.json" "$run/lineage-state-sync-receipt.json"
      [[ "$(<"$tmp/$label/config-attempts")" == 2 ]]
      [[ "$events" == *'verify-genesis-single-seed-canary.sh'* ]]
      if [[ "$state" == CANARY_RUNNING ]]; then
        [[ "$events" == *'wait-state-sync-canary.sh'* ]]
        caught_up_receipt="$(find "$run/receipts" -maxdepth 1 -type f -name '0003-*.json' -print -quit)"
        [[ -n "$caught_up_receipt" && "$(jq -r .state "$caught_up_receipt")" == CANARY_CAUGHT_UP ]]
      else
        [[ "$events" != *'wait-state-sync-canary.sh'* ]]
      fi
    fi
  else
    [[ "$rc" != 0 ]]
    [[ ! -e "$tmp/$label-stopped" && ! -e "$tmp/$label-promoted" && ! -e "$tmp/$label-started" ]]
    [[ "$(jq -r .state "$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)")" == "$state" ]]
    if [[ "$no_ssh" == true ]]; then [[ -z "$events" ]]; fi
    if [[ "$tweak" == existing-proof ]]; then
      grep -Fxq 'retained immutable evidence' "$run/genesis-single-seed-canary.json"
    fi
  fi
}

run_case new-success new pass off
run_case restore-success restore pass off
run_case divergent-current new fail off
run_case signer-running new pass running
run_case full-sync-running new pass off full_sync CANARY_RUNNING
run_case full-sync-caught-up new pass off full_sync CANARY_CAUGHT_UP
run_case full-sync-proof-failure new pass off full_sync CANARY_RUNNING fail
run_case full-sync-profile-mismatch new pass off full_sync CANARY_RUNNING pass profile-mismatch
run_case full-sync-lineage-mismatch new pass off full_sync CANARY_CAUGHT_UP pass lineage-mismatch
run_case full-sync-observation-raw-mismatch new pass off full_sync CANARY_CAUGHT_UP pass observation-raw-mismatch
run_case full-sync-observation-canonical-mismatch new pass off full_sync CANARY_CAUGHT_UP pass observation-canonical-mismatch
run_case full-sync-distribution-mismatch new pass off full_sync CANARY_CAUGHT_UP pass distribution-mismatch
run_case full-sync-no-evidence-overwrite new pass off full_sync CANARY_CAUGHT_UP pass existing-proof
printf 'PASS caught-up canary resume preserves state-sync and proves full-sync CANARY_RUNNING/CANARY_CAUGHT_UP before promotion\n'
