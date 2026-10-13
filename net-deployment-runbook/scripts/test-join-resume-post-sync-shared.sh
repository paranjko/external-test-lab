#!/usr/bin/env bash
# Exercise the shared signerless pre-membership boundary for both receipt
# operations. No Host, public endpoint or signer is used by this fixture.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$tmp/bin"
cp "$ROOT/scripts/lib-join-resume.sh" "$kit/scripts/"
cp "$ROOT/scripts/lib-post-sync-join.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  IDENTITIES="$GDC_TEST_OPERATOR/state/identities"
  ACCOUNTS="$GDC_TEST_OPERATOR/accounts"
  STATE="$GDC_TEST_OPERATOR/state"
  PUBLIC_EDGE_NODE=public-edge
}
node_name() { printf '%s\n' "$1"; }
start_stack() { printf 'stack:%s:%s\n' "$1" "${3:-default}" >>"$GDC_TEST_EVENTS"; }
EOF
cat >"$kit/scripts/verify-join-receipt-chain.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == --receipt-dir && -d "$2" ]] || exit 64
head="$(find "$2" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)"
state="$(jq -er .state "$head")"
jq -cn --arg state "$state" '{last_state:$state,signer_ever_started:false}'
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
cat >"$kit/scripts/verify-post-sync-join-state.sh" <<'EOF'
#!/usr/bin/env bash
printf 'post-sync\n' >>"$GDC_TEST_EVENTS"
[[ "${GDC_TEST_POST_SYNC:-pass}" == pass ]]
EOF
cat >"$kit/scripts/restart-api-after-sync.sh" <<'EOF'
#!/usr/bin/env bash
printf 'restart-api:%s\n' "$1" >>"$GDC_TEST_EVENTS"
EOF
chmod 0755 "$kit/scripts"/*.sh

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SSH_LOG"
[[ "$1" == fixture && $# == 2 ]] || exit 41
staging_pattern="^rm -rf '/tmp/gdc-[A-Za-z0-9._-]+' && mkdir -p '/tmp/gdc-[A-Za-z0-9._-]+'$"
[[ "$2" =~ $staging_pattern || "$2" == "cd '/srv/dai/deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms" ]] || exit 42
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SCP_LOG"
[[ "$1" == -q && $# == 3 && "$3" == fixture:/tmp/gdc-* ]] || exit 51
[[ "$2" == "$GDC_TEST_KIT/scripts/verify-join-lineage-state.sh" || "$2" == */lineage-state-sync-receipt.json ]] || exit 52
EOF
chmod 0755 "$tmp/bin"/*

cat >"$kit/run-shared.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$GDC_TEST_KIT/scripts/lib.sh"
load_project
source "$GDC_TEST_KIT/scripts/lib-join-resume.sh"
NODE=fixture
RUN="$1"
join_resume_prepare_post_sync "$2"
EOF
chmod 0755 "$kit/run-shared.sh"

write_receipts() {
  local run="$1" operation="$2" profile_sha="$3" terminal="${4:-APPLICATION_ACTIVE}" state input
  mkdir -p "$run/receipts"
  for state in RUN_CREATED CANARY_VERIFIED PROMOTED CANONICAL_RUNNING APPLICATION_ACTIVE; do
    input="$run/receipts/$(printf '%04d' "$(( $(find "$run/receipts" -type f | wc -l) + 1 ))")-fixture.json"
    jq -cn --arg operation "$operation" --arg state "$state" --arg profile "$profile_sha" '
      {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:$operation,node_name:"fixture",state:$state,
       join_profile_sha256:$profile,network_observation_sha256:("a" * 64),generation_id:"fixture-run",
       identity_fingerprints:{participant_address:"gonka1fixtureparticipant",consensus_pubkey:"",p2p_node_id:"",warm_address:""},
       signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$input"
  done
  if [[ "$terminal" == MEMBERSHIP_RECONCILED ]]; then
    for state in CANONICAL_VERIFIED RECOVERY_ARCHIVE_READY MEMBERSHIP_RECONCILED; do
      input="$run/receipts/$(printf '%04d' "$(( $(find "$run/receipts" -type f | wc -l) + 1 ))")-fixture.json"
      jq -cn --arg operation "$operation" --arg state "$state" --arg profile "$profile_sha" '
        {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:$operation,node_name:"fixture",state:$state,
         join_profile_sha256:$profile,network_observation_sha256:("a" * 64),generation_id:"fixture-run",
         identity_fingerprints:{participant_address:"gonka1fixtureparticipant",consensus_pubkey:"",p2p_node_id:"",warm_address:""},
         signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$input"
    done
  fi
}

run_case() {
  local label="$1" operation="$2" post_sync="$3" terminal="${4:-APPLICATION_ACTIVE}" operator run profile rc=0 expected_state
  operator="$tmp/$label/operator"
  run="$tmp/$label/run"
  profile="$tmp/$label/profile.json"
  mkdir -p "$operator/state/identities" "$operator/accounts"
  printf '%s\n' '{"spec":{"network":{"chain_id":"gonka-devnet-community"},"components":{"core":{"expected_runtime":{"version":"0.2.15","commit":"1111111111111111111111111111111111111111"}},"dapi":{"expected_runtime":{"version":"0.2.15-post3","commit":"2222222222222222222222222222222222222222"}}}}}' >"$profile"
  profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
  printf '%s\n' '{"node_id":"0123456789abcdef0123456789abcdef01234567"}' >"$operator/state/identities/fixture.json"
  if [[ "$operation" == new ]]; then
    printf '%s\n' '{"address":"gonka1fixtureparticipant"}' >"$operator/accounts/fixture-cold.json"
  fi
  write_receipts "$run" "$operation" "$profile_sha" "$terminal"
  printf '%s\n' '{}' >"$run/lineage-state-sync-receipt.json"
  : >"$tmp/$label-events"; : >"$tmp/$label-ssh"; : >"$tmp/$label-scp"
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
    GDC_TEST_EVENTS="$tmp/$label-events" GDC_TEST_SSH_LOG="$tmp/$label-ssh" GDC_TEST_SCP_LOG="$tmp/$label-scp" \
    GDC_TEST_POST_SYNC="$post_sync" GDC_RUN_ID=fixture-run GDC_JOIN_PROFILE="$profile" \
    GDC_JOIN_OBSERVATION="$profile" GDC_JOIN_RESULT_OUTPUT="$run/join-result.json" \
    "$kit/run-shared.sh" "$run" "$operation" >"$tmp/$label.out" 2>"$tmp/$label.err" || rc=$?
  if [[ "$post_sync" == pass ]]; then
    [[ "$rc" == 0 ]] || { cat "$tmp/$label.err" >&2; return 1; }
    events="$(<"$tmp/$label-events")"
    [[ "$events" == *post-sync* && "$events" == *'stack:fixture:caddy'* && "$events" == *'stack:fixture:default'* ]] || return 1
    expected_state=CANONICAL_VERIFIED
    [[ "$terminal" == MEMBERSHIP_RECONCILED ]] && expected_state=MEMBERSHIP_RECONCILED
    [[ "$(jq -r .state "$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)")" == "$expected_state" ]]
  else
    [[ "$rc" != 0 ]] || return 1
    events="$(<"$tmp/$label-events")"
    [[ "$events" == *post-sync* && "$events" != *stack:* ]]
    [[ "$(jq -r .state "$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)")" == APPLICATION_ACTIVE ]]
  fi
}

run_case new-pass new pass
run_case restore-pass restore pass
run_case restore-current-checkpoint-refusal restore fail
run_case restore-membership-pass restore pass MEMBERSHIP_RECONCILED

# A receipt's operation selects its continuation. A syntactically complete
# new-JOIN chain must not be accepted by the restore handler.
operator="$tmp/operation-mismatch/operator"
run="$tmp/operation-mismatch/run"
profile="$tmp/operation-mismatch/profile.json"
mkdir -p "$operator/state/identities" "$operator/accounts"
printf '%s\n' '{"spec":{"network":{"chain_id":"gonka-devnet-community"},"components":{"core":{"expected_runtime":{"version":"0.2.15","commit":"1111111111111111111111111111111111111111"}},"dapi":{"expected_runtime":{"version":"0.2.15-post3","commit":"2222222222222222222222222222222222222222"}}}}}' >"$profile"
profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
printf '%s\n' '{"node_id":"0123456789abcdef0123456789abcdef01234567"}' >"$operator/state/identities/fixture.json"
write_receipts "$run" new "$profile_sha"
printf '%s\n' '{}' >"$run/lineage-state-sync-receipt.json"
: >"$tmp/operation-mismatch-events"; : >"$tmp/operation-mismatch-ssh"; : >"$tmp/operation-mismatch-scp"
rc=0
env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
  GDC_TEST_EVENTS="$tmp/operation-mismatch-events" GDC_TEST_SSH_LOG="$tmp/operation-mismatch-ssh" GDC_TEST_SCP_LOG="$tmp/operation-mismatch-scp" \
  GDC_TEST_POST_SYNC=pass GDC_RUN_ID=fixture-run GDC_JOIN_PROFILE="$profile" \
  GDC_JOIN_OBSERVATION="$profile" GDC_JOIN_RESULT_OUTPUT="$run/join-result.json" \
  "$kit/run-shared.sh" "$run" restore >"$tmp/operation-mismatch.out" 2>"$tmp/operation-mismatch.err" || rc=$?
[[ "$rc" != 0 ]]
[[ ! -s "$tmp/operation-mismatch-events" && ! -s "$tmp/operation-mismatch-ssh" && ! -s "$tmp/operation-mismatch-scp" ]]
[[ "$(jq -r .state "$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)")" == APPLICATION_ACTIVE ]]
printf 'PASS new and restore JOIN resumes share one signerless post-sync boundary and stop before a failed current checkpoint\n'
