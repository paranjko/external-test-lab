#!/usr/bin/env bash
# Exercise the new-JOIN post-sync continuation without a Host, signer, or
# public network. The fixture accepts only the retained signerless boundary.
set -Eeuo pipefail

PRODUCT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$tmp/bin"
cp "$PRODUCT_ROOT/scripts/phase-join-resume-new-canonical.sh" "$kit/scripts/"
cp "$PRODUCT_ROOT/scripts/lib-join-resume.sh" "$kit/scripts/"
cp "$PRODUCT_ROOT/scripts/lib-post-sync-join.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  IDENTITIES="$GDC_TEST_OPERATOR/state/identities"
  ACCOUNTS="$GDC_TEST_OPERATOR/accounts"
  STATE="$GDC_TEST_OPERATOR/state"
  GENESIS_PUBLIC_HOST=seed.fixture.test
  PUBLIC_EDGE_NODE=public-edge
}
node_name() { printf '%s\n' "$1"; }
participant_onboarding_state() {
  case "${1,,}" in
    active) printf 'active\n' ;;
    registered) printf 'registered\n' ;;
    *) printf 'unknown\n' ;;
  esac
}
step() { printf 'STEP %s\n' "$*" >>"$GDC_TEST_EVENTS"; }
start_stack() {
  printf 'stack:%s:%s\n' "$1" "${3:-default}" >>"$GDC_TEST_EVENTS"
  if [[ "$2" == /srv/dai/deploy/monitoring-agent && "${GDC_TEST_FAIL_MONITORING_ONCE:-false}" == true \
    && ! -e "$GDC_TEST_EVENTS.monitoring-failed" ]]; then
    : >"$GDC_TEST_EVENTS.monitoring-failed"
    return 87
  fi
}
record_join_state() { printf 'state:%s\n' "$2" >>"$GDC_TEST_EVENTS"; }
EOF

cat >"$kit/scripts/verify-join-receipt-chain.sh" <<'EOF'
#!/usr/bin/env bash
jq -cn --arg state "${GDC_TEST_RESUME_STATE:-APPLICATION_ACTIVE}" '{last_state:$state,signer_ever_started:false}'
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
count="$(find "$receipts" -maxdepth 1 -type f -name '*.json' -printf x | wc -c)"
cp "$input" "$receipts/$(printf '%04d' "$((count + 1))")-fixture.json"
EOF
cat >"$kit/scripts/verify-post-sync-join-state.sh" <<'EOF'
#!/usr/bin/env bash
printf 'post-sync\n' >>"$GDC_TEST_EVENTS"
[[ "${GDC_TEST_POST_SYNC:-pass}" == pass ]]
EOF
cat >"$kit/scripts/validator-backup.sh" <<'EOF'
#!/usr/bin/env bash
printf 'backup:%s\n' "$1" >>"$GDC_TEST_EVENTS"
EOF
cat >"$kit/scripts/verify-participant-validator-key.sh" <<'EOF'
#!/usr/bin/env bash
printf 'key-verified\n' >>"$GDC_TEST_EVENTS"
EOF
cat >"$kit/scripts/phase-join-resume-membership.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'membership:%s:%s\n' "$1" "$2" >>"$GDC_TEST_EVENTS"
EOF
mkdir -p "$kit/03-join"
cat >"$kit/03-join/restart-api-after-sync.sh" <<'EOF'
#!/usr/bin/env bash
printf 'restart-api:%s\n' "$1" >>"$GDC_TEST_EVENTS"
EOF
cat >"$kit/03-join/wait-registered.sh" <<'EOF'
#!/usr/bin/env bash
printf 'registered:%s\n' "$2" >>"$GDC_TEST_EVENTS"
EOF
chmod 0755 "$kit/scripts"/*.sh "$kit/03-join"/*.sh

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SSH_LOG"
[[ "$1" == fixture && $# == 2 ]] || exit 41
staging_pattern="^rm -rf '/tmp/gdc-[A-Za-z0-9._-]+'( && mkdir -p '/tmp/gdc-[A-Za-z0-9._-]+')?$"
if [[ "$2" =~ $staging_pattern || "$2" == "cd '/srv/dai/deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms" ]]; then
  exit 0
fi
if [[ "$2" == 'cd /srv/dai/deploy && ./register-participant.sh .env >register-participant.log 2>&1' ]]; then
  printf 'register\n' >>"$GDC_TEST_EVENTS"
  exit 0
fi
exit 42
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -q && $# == 3 && "$3" == fixture:/tmp/gdc-* ]] || exit 51
[[ "$2" == "$GDC_TEST_KIT/scripts/verify-join-lineage-state.sh" || "$2" == */lineage-state-sync-receipt.json ]] || exit 52
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''; write=''
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -z "$output" ]] || printf '%s\n' '{}' >"$output"
[[ -z "$write" ]] || printf '404'
EOF
chmod 0755 "$tmp/bin"/*

run_case() {
  local label="$1" post_sync="$2" lineage_mode="${3:-state_sync}" tweak="${4:-none}" resume_state="${5:-APPLICATION_ACTIVE}" retry_mode="${6:-none}" rc=0
  local operator="$tmp/$label/operator" run="$tmp/$label/run" profile="$tmp/$label/profile.json" observation="$tmp/$label/observation.json"
  mkdir -p "$operator/state/identities" "$operator/accounts" "$run/receipts"
  if [[ "$lineage_mode" == full_sync ]]; then
    jq -n '{spec:{network:{chain_id:"gonka-devnet-community",genesis_sha256:("c"*64),bootstrap_genesis_sha256:("d"*64),bootstrap_sha256:("d"*64),bootstrap_url:"https://bootstrap.example.test/bootstrap.json"},components:{core:{expected_runtime:{version:"0.2.15",commit:("1"*40)}},dapi:{expected_runtime:{version:"0.2.15-post3",commit:("2"*40)}}}}}' >"$profile"
  else
    printf '%s\n' '{"spec":{"network":{"chain_id":"gonka-devnet-community"},"components":{"core":{"expected_runtime":{"version":"0.2.15","commit":"1111111111111111111111111111111111111111"}},"dapi":{"expected_runtime":{"version":"0.2.15-post3","commit":"2222222222222222222222222222222222222222"}}}}}' >"$profile"
  fi
  printf '%s\n' '{}' >"$observation"
  if [[ "$lineage_mode" == full_sync ]]; then
    jq -n '{network_state_id:("f"*64),bootstrap:{url:"https://bootstrap.example.test/bootstrap.json",document_sha256:("d"*64),chain_id:"gonka-devnet-community",genesis_sha256:("d"*64),chain_identity_sha256:("c"*64)},runtime:{core:{version:"test"}}}' >"$run/network-observation-canary.v1.json"
    jq -n --arg observation "$(sha256sum "$run/network-observation-canary.v1.json" | awk '{print $1}')" '{schema_version:1,kind:"gdc-host-join-lineage-preflight",bootstrap:{mode:"full_sync",chain_id:"gonka-devnet-community",genesis_sha256:("c"*64),distribution_sha256:("d"*64),seed:{node_id:("b"*40),rpc_url:"https://seed.fixture.test/chain-rpc",p2p:"tcp://seed.fixture.test:5000"}},fault_domains:[{id:"genesis-single-seed",rpc_url:"https://seed.fixture.test/chain-rpc",host:"seed.fixture.test",port:26657,ip:"192.0.2.10",chain_id:"gonka-devnet-community",genesis_sha256:("c"*64)}],trust_authority:{kind:"genesis_single_seed",rpc_url:"https://seed.fixture.test/chain-rpc"},runtime:{network_fingerprint:("f"*64),source:{kind:"bootstrap_software",id:("f"*64)},observation_sha256:$observation},checkpoints:null}' >"$run/lineage-preflight-canary.v1.json"
    jq -n '{schema_version:1,kind:"gdc-genesis-single-seed-canary",chain_id:"gonka-devnet-community",genesis_sha256:("c"*64),seed_node_id:("b"*40),seed_rpc:"https://seed.fixture.test/chain-rpc",join_node_id:"0123456789abcdef0123456789abcdef01234567",common_height:321,common_block:{height:321,block_id:("1"*64),app_hash:("2"*64)}}' >"$run/genesis-single-seed-canary.json"
    case "$tweak" in
      wrong-profile) jq '.spec.network.genesis_sha256 = ("e"*64)' "$profile" >"$profile.tmp"; mv "$profile.tmp" "$profile" ;;
      wrong-bootstrap-url) jq '.spec.network.bootstrap_url = "https://other.fixture.test/bootstrap.json"' "$profile" >"$profile.tmp"; mv "$profile.tmp" "$profile" ;;
      wrong-bootstrap-digest) jq '.spec.network.bootstrap_sha256 = ("e"*64)' "$profile" >"$profile.tmp"; mv "$profile.tmp" "$profile" ;;
      malformed-source) jq 'del(.fault_domains[0].rpc_url)' "$run/lineage-preflight-canary.v1.json" >"$run/source.tmp"; mv "$run/source.tmp" "$run/lineage-preflight-canary.v1.json" ;;
      wrong-fingerprint) jq '.runtime.network_fingerprint = ("e"*64)' "$run/lineage-preflight-canary.v1.json" >"$run/source.tmp"; mv "$run/source.tmp" "$run/lineage-preflight-canary.v1.json" ;;
      wrong-source-id) jq '.runtime.source.id = ("e"*64)' "$run/lineage-preflight-canary.v1.json" >"$run/source.tmp"; mv "$run/source.tmp" "$run/lineage-preflight-canary.v1.json" ;;
      wrong-observation-sha) jq '.runtime.observation_sha256 = ("e"*64)' "$run/lineage-preflight-canary.v1.json" >"$run/source.tmp"; mv "$run/source.tmp" "$run/lineage-preflight-canary.v1.json" ;;
      wrong-network-state-id) jq '.network_state_id = ("e"*64)' "$run/network-observation-canary.v1.json" >"$run/observation.tmp"; mv "$run/observation.tmp" "$run/network-observation-canary.v1.json" ;;
      wrong-distribution-digest) jq '.bootstrap.distribution_sha256 = ("e"*64)' "$run/lineage-preflight-canary.v1.json" >"$run/source.tmp"; mv "$run/source.tmp" "$run/lineage-preflight-canary.v1.json" ;;
      wrong-observation-raw-genesis) jq '.bootstrap.genesis_sha256 = ("e"*64)' "$run/network-observation-canary.v1.json" >"$run/observation.tmp"; mv "$run/observation.tmp" "$run/network-observation-canary.v1.json" ;;
      wrong-observation-canonical-genesis) jq '.bootstrap.chain_identity_sha256 = ("e"*64)' "$run/network-observation-canary.v1.json" >"$run/observation.tmp"; mv "$run/observation.tmp" "$run/network-observation-canary.v1.json" ;;
      wrong-seed) jq '.seed_node_id = ("e"*40)' "$run/genesis-single-seed-canary.json" >"$run/proof.tmp"; mv "$run/proof.tmp" "$run/genesis-single-seed-canary.json" ;;
      wrong-join) jq '.join_node_id = ("e"*40)' "$run/genesis-single-seed-canary.json" >"$run/proof.tmp"; mv "$run/proof.tmp" "$run/genesis-single-seed-canary.json" ;;
      conflicting-retained) printf '%s\n' 'immutable retained bytes' >"$run/lineage-state-sync-receipt.json" ;;
      none) ;;
      *) echo "unknown full-sync tweak: $tweak" >&2; return 1 ;;
    esac
  else
    printf '%s\n' '{}' >"$run/lineage-state-sync-receipt.json"
  fi
  profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
  observation_sha="$(sha256sum "$observation" | awk '{print $1}')"
  printf '%s\n' '{"node_id":"0123456789abcdef0123456789abcdef01234567","consensus_pubkey":"YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="}' >"$operator/state/identities/fixture.json"
  printf '%s\n' '{"address":"gonka1fixtureparticipant"}' >"$operator/accounts/fixture-cold.json"
  states=(RUN_CREATED CANARY_VERIFIED PROMOTED CANONICAL_RUNNING)
  case "$resume_state" in
    APPLICATION_ACTIVE) states+=(APPLICATION_ACTIVE) ;;
    CANONICAL_VERIFIED) states+=(APPLICATION_ACTIVE CANONICAL_VERIFIED) ;;
  esac
  for state in "${states[@]}"; do
    jq -cn --arg state "$state" --arg profile "$profile_sha" --arg observation "$observation_sha" '{run_id:"fixture-run",generation_id:"fixture-run",operation:"new",node_name:"fixture",state:$state,join_profile_sha256:$profile,network_observation_sha256:$observation,identity_fingerprints:{participant_address:"gonka1fixtureparticipant"},signer_ever_started:false}' >"$run/receipts/$(printf '%04d' "$(( $(find "$run/receipts" -type f | wc -l) + 1 ))")-fixture.json"
  done
  : >"$tmp/$label-events"; : >"$tmp/$label-ssh"
  run_phase() {
    env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
      GDC_TEST_EVENTS="$tmp/$label-events" GDC_TEST_SSH_LOG="$tmp/$label-ssh" GDC_TEST_POST_SYNC="$post_sync" GDC_TEST_RESUME_STATE="$resume_state" \
      GDC_TEST_FAIL_MONITORING_ONCE="$([[ "$retry_mode" == auxiliary-retry ]] && printf true || printf false)" \
      GDC_RUN_ID=fixture-run GDC_JOIN_PROFILE="$profile" GDC_JOIN_OBSERVATION="$observation" \
      GDC_JOIN_RESULT_OUTPUT="$run/join-result.json" \
      "$kit/scripts/phase-join-resume-new-canonical.sh" fixture "$run"
  }
  initial_receipts="$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' | wc -l)"
  if [[ "$retry_mode" == auxiliary-retry ]]; then
    [[ "$resume_state" == CANONICAL_VERIFIED ]] || return 1
    rc=0
    run_phase >"$tmp/$label-first.out" 2>"$tmp/$label-first.err" || rc=$?
    [[ "$rc" != 0 ]] || return 1
    first_events="$(<"$tmp/$label-events")"
    [[ "$first_events" == *post-sync* && "$first_events" == *'stack:fixture:default'* \
      && "$first_events" != *backup:* && "$first_events" != *register* && "$first_events" != *membership:* ]] || return 1
    [[ "$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' | wc -l)" == "$initial_receipts" ]] || return 1
    rc=0
    run_phase >"$tmp/$label-second.out" 2>"$tmp/$label-second.err" || rc=$?
  else
    run_phase >"$tmp/$label.out" 2>"$tmp/$label.err" || rc=$?
  fi
  if [[ "$post_sync" == pass ]]; then
    [[ "$rc" == 0 ]] || { cat "$tmp/$label.err" >&2; return 1; }
    events="$(<"$tmp/$label-events")"
    [[ "$events" == *post-sync* && "$events" == *backup:create* && "$events" == *register* && "$events" == *membership:fixture:* ]] || return 1
    [[ "$(tail -n 1 "$tmp/$label-events")" == "membership:fixture:$run" ]]
    [[ "$(<"$tmp/$label-ssh")" != *'start-node.sh --enable-signer'* ]]
    if [[ "$lineage_mode" == full_sync ]]; then
      if [[ "$tweak" == conflicting-retained ]]; then
        grep -Fxq 'immutable retained bytes' "$run/lineage-state-sync-receipt.json" || return 1
      else
        cmp -s "$run/lineage-preflight-canary.v1.json" "$run/lineage-state-sync-receipt.json" || return 1
      fi
    fi
  else
    [[ "$rc" != 0 ]] || return 1
    events="$(<"$tmp/$label-events")"
    if [[ "$lineage_mode" == full_sync ]]; then
      [[ -z "$events" ]] || return 1
    else
      [[ "$events" == *post-sync* && "$events" != *stack:* && "$events" != *register* && "$events" != *membership:* && "$events" != *backup:* ]]
    fi
    [[ "$(<"$tmp/$label-ssh")" != *'start-node.sh --enable-signer'* ]]
    if [[ "$lineage_mode" == full_sync ]]; then
      if [[ "$tweak" == conflicting-retained ]]; then
        grep -Fxq 'immutable retained bytes' "$run/lineage-state-sync-receipt.json" || return 1
      else
        [[ ! -e "$run/lineage-state-sync-receipt.json" && ! -L "$run/lineage-state-sync-receipt.json" ]] || return 1
      fi
      [[ ! -s "$tmp/$label-ssh" ]] || return 1
    fi
  fi
}

run_case success pass
run_case current-checkpoint-refusal fail
run_case canonical-verified-monitoring-retry pass state_sync none CANONICAL_VERIFIED auxiliary-retry
run_case full-sync-active-repair pass full_sync none
run_case full-sync-canonical-running-repair pass full_sync none CANONICAL_RUNNING
run_case full-sync-canonical-verified-repair pass full_sync none CANONICAL_VERIFIED
run_case full-sync-wrong-profile fail full_sync wrong-profile
run_case full-sync-wrong-bootstrap-url fail full_sync wrong-bootstrap-url
run_case full-sync-wrong-bootstrap-digest fail full_sync wrong-bootstrap-digest
run_case full-sync-wrong-distribution-digest fail full_sync wrong-distribution-digest
run_case full-sync-wrong-observation-raw-genesis fail full_sync wrong-observation-raw-genesis
run_case full-sync-wrong-observation-canonical-genesis fail full_sync wrong-observation-canonical-genesis
run_case full-sync-malformed-source fail full_sync malformed-source
run_case full-sync-wrong-fingerprint fail full_sync wrong-fingerprint
run_case full-sync-wrong-source-id fail full_sync wrong-source-id
run_case full-sync-wrong-observation-sha fail full_sync wrong-observation-sha
run_case full-sync-wrong-network-state-id fail full_sync wrong-network-state-id
run_case full-sync-wrong-seed fail full_sync wrong-seed
run_case full-sync-wrong-join fail full_sync wrong-join
run_case full-sync-no-overwrite fail full_sync conflicting-retained
bash "$PRODUCT_ROOT/scripts/test-preserve-join-result-before-resume.sh"
printf 'PASS new-JOIN canonical resume reaches membership only after the promoted signerless current-state proof\n'
