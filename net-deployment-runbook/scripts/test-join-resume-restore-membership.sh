#!/usr/bin/env bash
# Exercise the actual restore continuation after an interruption immediately
# following MEMBERSHIP_RECONCILED. It must recheck post-sync state, not append
# that transition again, and must not reach signer control before its fence.
set -Eeuo pipefail

PRODUCT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
kit="$tmp/kit"
operator="$tmp/operator"
run="$tmp/run"
mkdir -p "$kit/scripts" "$tmp/bin" "$operator/state/identities" "$run/receipts"
cp "$PRODUCT_ROOT/scripts/phase-join-resume-canonical.sh" "$kit/scripts/"
cp "$PRODUCT_ROOT/scripts/lib-join-resume.sh" "$kit/scripts/"
cp "$PRODUCT_ROOT/scripts/lib-post-sync-join.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  IDENTITIES="$GDC_TEST_OPERATOR/state/identities"
  ACCOUNTS="$GDC_TEST_OPERATOR/accounts"
  STATE="$GDC_TEST_OPERATOR/state"
  PUBLIC_EDGE_NODE=public-edge
  GENESIS_PUBLIC_HOST=genesis.example.test
}
node_name() { printf '%s\n' "$1"; }
start_stack() { printf 'stack:%s:%s\n' "$1" "${3:-default}" >>"$GDC_TEST_EVENTS"; }
record_join_state() { printf 'state:%s\n' "$2" >>"$GDC_TEST_EVENTS"; }
participant_onboarding_state() { [[ "$1" == ACTIVE ]] && printf 'active\n'; }
node_ml_host() { return 1; }
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
count="$(find "$receipts" -maxdepth 1 -type f -name '*.json' -printf x | wc -c)"
cp "$input" "$receipts/$(printf '%04d' "$((count + 1))")-fixture.json"
EOF
cat >"$kit/scripts/verify-post-sync-join-state.sh" <<'EOF'
#!/usr/bin/env bash
printf 'post-sync\n' >>"$GDC_TEST_EVENTS"
EOF
cat >"$kit/scripts/resolve-reset-dai-backup.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{}'
EOF
cat >"$kit/scripts/same-host-restore.sh" <<'EOF'
#!/usr/bin/env bash
printf 'same-host-fence\n' >>"$GDC_TEST_EVENTS"
exit 77
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
[[ "$1" == -q && $# == 3 && "$3" == fixture:/tmp/gdc-* ]] || exit 51
[[ "$2" == "$GDC_TEST_KIT/scripts/verify-join-lineage-state.sh" || "$2" == */lineage-state-sync-receipt.json ]] || exit 52
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"participant":{"status":"ACTIVE"}}'
EOF
chmod 0755 "$tmp/bin"/*

profile="$tmp/profile.json"
printf '%s\n' '{"spec":{"network":{"chain_id":"gonka-devnet-community"},"components":{"core":{"expected_runtime":{"version":"0.2.15","commit":"1111111111111111111111111111111111111111"}},"dapi":{"expected_runtime":{"version":"0.2.15-post3","commit":"2222222222222222222222222222222222222222"}}}}}' >"$profile"
profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
printf '%s\n' '{"node_id":"0123456789abcdef0123456789abcdef01234567"}' >"$operator/state/identities/fixture.json"
for state in RUN_CREATED CANARY_VERIFIED PROMOTED CANONICAL_RUNNING APPLICATION_ACTIVE CANONICAL_VERIFIED RECOVERY_ARCHIVE_READY MEMBERSHIP_RECONCILED; do
  jq -cn --arg state "$state" --arg profile "$profile_sha" '
    {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:"restore",node_name:"fixture",state:$state,
     join_profile_sha256:$profile,network_observation_sha256:("a" * 64),generation_id:"fixture-run",
     identity_fingerprints:{participant_address:"gonka1fixtureparticipant",consensus_pubkey:"",p2p_node_id:"",warm_address:""},
     signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' \
    >"$run/receipts/$(printf '%04d' "$(( $(find "$run/receipts" -type f | wc -l) + 1 ))")-fixture.json"
done
printf '%s\n' '{}' >"$run/lineage-state-sync-receipt.json"
: >"$tmp/events"; : >"$tmp/ssh"

rc=0
env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
  GDC_TEST_EVENTS="$tmp/events" GDC_TEST_SSH_LOG="$tmp/ssh" \
  GDC_RUN_ID=fixture-run GDC_JOIN_PROFILE="$profile" GDC_JOIN_OBSERVATION="$profile" \
  GDC_JOIN_RESULT_OUTPUT="$run/join-result.json" \
  "$kit/scripts/phase-join-resume-canonical.sh" fixture "$run" >"$tmp/out" 2>"$tmp/err" || rc=$?
[[ "$rc" == 77 ]] || { cat "$tmp/out" "$tmp/err" "$tmp/ssh" >&2; exit 1; }
events="$(<"$tmp/events")"
[[ "$events" == *post-sync* && "$events" == *state:PERMISSIONS_RECONCILED* && "$events" == *same-host-fence* ]]
[[ "$events" != *state:MEMBERSHIP_RECONCILED* ]]
[[ "$(<"$tmp/ssh")" != *fence-existing-signer* && "$(<"$tmp/ssh")" != *'start-node.sh --enable-signer'* ]]
[[ "$(jq -r .state "$(find "$run/receipts" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort | tail -n1)")" == PERMISSIONS_RECONCILED ]]
printf 'PASS restore membership resume rechecks post-sync state without repeating membership or reaching signer control\n'
