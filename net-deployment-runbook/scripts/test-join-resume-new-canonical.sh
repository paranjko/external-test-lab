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
start_stack() { printf 'stack:%s:%s\n' "$1" "${3:-default}" >>"$GDC_TEST_EVENTS"; }
record_join_state() { printf 'state:%s\n' "$2" >>"$GDC_TEST_EVENTS"; }
EOF

cat >"$kit/scripts/verify-join-receipt-chain.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"last_state":"APPLICATION_ACTIVE","signer_ever_started":false}'
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
  local label="$1" post_sync="$2" rc=0
  local operator="$tmp/$label/operator" run="$tmp/$label/run" profile="$tmp/$label/profile.json"
  mkdir -p "$operator/state/identities" "$operator/accounts" "$run/receipts"
  printf '%s\n' '{"spec":{"network":{"chain_id":"gonka-devnet-community"},"components":{"core":{"expected_runtime":{"version":"0.2.15","commit":"1111111111111111111111111111111111111111"}},"dapi":{"expected_runtime":{"version":"0.2.15-post3","commit":"2222222222222222222222222222222222222222"}}}}}' >"$profile"
  profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
  printf '%s\n' '{"node_id":"0123456789abcdef0123456789abcdef01234567","consensus_pubkey":"YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="}' >"$operator/state/identities/fixture.json"
  printf '%s\n' '{"address":"gonka1fixtureparticipant"}' >"$operator/accounts/fixture-cold.json"
  for state in RUN_CREATED CANARY_VERIFIED PROMOTED CANONICAL_RUNNING APPLICATION_ACTIVE; do
    jq -cn --arg state "$state" --arg profile "$profile_sha" '{run_id:"fixture-run",operation:"new",node_name:"fixture",state:$state,join_profile_sha256:$profile,identity_fingerprints:{participant_address:"gonka1fixtureparticipant"},signer_ever_started:false}' >"$run/receipts/$(printf '%04d' "$(( $(find "$run/receipts" -type f | wc -l) + 1 ))")-fixture.json"
  done
  printf '%s\n' '{}' >"$run/lineage-state-sync-receipt.json"
  : >"$tmp/$label-events"; : >"$tmp/$label-ssh"
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
    GDC_TEST_EVENTS="$tmp/$label-events" GDC_TEST_SSH_LOG="$tmp/$label-ssh" GDC_TEST_POST_SYNC="$post_sync" \
    GDC_RUN_ID=fixture-run GDC_JOIN_PROFILE="$profile" GDC_JOIN_OBSERVATION="$profile" \
    GDC_JOIN_RESULT_OUTPUT="$run/join-result.json" \
    "$kit/scripts/phase-join-resume-new-canonical.sh" fixture "$run" >"$tmp/$label.out" 2>"$tmp/$label.err" || rc=$?
  if [[ "$post_sync" == pass ]]; then
    [[ "$rc" == 0 ]] || { cat "$tmp/$label.err" >&2; return 1; }
    events="$(<"$tmp/$label-events")"
    [[ "$events" == *post-sync* && "$events" == *backup:create* && "$events" == *register* && "$events" == *membership:fixture:* ]] || return 1
    [[ "$(tail -n 1 "$tmp/$label-events")" == "membership:fixture:$run" ]]
    [[ "$(<"$tmp/$label-ssh")" != *'start-node.sh --enable-signer'* ]]
  else
    [[ "$rc" != 0 ]] || return 1
    events="$(<"$tmp/$label-events")"
    [[ "$events" == *post-sync* && "$events" != *stack:* && "$events" != *register* && "$events" != *membership:* && "$events" != *backup:* ]]
    [[ "$(<"$tmp/$label-ssh")" != *'start-node.sh --enable-signer'* ]]
  fi
}

run_case success pass
run_case current-checkpoint-refusal fail
printf 'PASS new-JOIN canonical resume reaches membership only after the promoted signerless current-state proof\n'
