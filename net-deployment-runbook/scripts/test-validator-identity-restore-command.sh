#!/usr/bin/env bash
set +x
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/build-validator-identity-restore-command.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '01234567890123456789012345678901' | base64 >"$tmp/softsign"
consensus_key="$("$ROOT/scripts/tmkms-softsign-public-key.sh" "$tmp/softsign")"
state=/srv/dai/gdc-node1
candidate=/tmp/gdc-gdc-node1-validator-restore-123
deployment_env=/srv/dai/deploy/gdc-node1/.env
bundle_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

command_line="$("$CHECK" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256")"
arguments="$(bash -c '
  sudo() { command "$@"; }
  export -f sudo
  bash -c "$1"
' _ "$command_line" <<'EOF'
printf '%s\n' "$1" "$2" "$3" "$4" "$5"
EOF
)"
mapfile -t restored_arguments <<<"$arguments"
[[ "${restored_arguments[0]}" == "$state" ]]
[[ "${restored_arguments[1]}" == "$candidate" ]]
[[ "${restored_arguments[2]}" == "$consensus_key" ]]
[[ "${restored_arguments[3]}" == "$deployment_env" ]]
[[ "${restored_arguments[4]}" == "$bundle_sha256" ]]

secret_canary='ARCHIVE_SECRET_CANARY_51'
noncanonical_key="${consensus_key:0:42}B="
declare -a invalid_cases=(
  consensus-injection
  consensus-noncanonical
  bundle-injection
  state-injection
  deployment-mismatch
)
for test_case in "${invalid_cases[@]}"; do
  test_state="$state"
  test_candidate="$candidate"
  test_key="$consensus_key"
  test_environment="$deployment_env"
  test_digest="$bundle_sha256"
  case "$test_case" in
    consensus-injection) test_key="bad'; printf %s $secret_canary" ;;
    consensus-noncanonical) test_key="$noncanonical_key" ;;
    bundle-injection) test_digest="bad-$secret_canary" ;;
    state-injection) test_state="/srv/dai/gdc-node1;$secret_canary" ;;
    deployment-mismatch) test_environment="/srv/dai/deploy/$secret_canary/.env" ;;
  esac
  if "$CHECK" "$test_state" "$test_candidate" "$test_key" "$test_environment" "$test_digest" \
    >"$tmp/$test_case.out" 2>"$tmp/$test_case.err"; then
    echo "invalid restore command case was accepted: $test_case" >&2
    exit 1
  fi
  ! grep -Fq "$secret_canary" "$tmp/$test_case.out" "$tmp/$test_case.err"
done

if bash -x "$CHECK" "$state" "$candidate" "bad-$secret_canary" "$deployment_env" "$bundle_sha256" \
  >"$tmp/xtrace.out" 2>"$tmp/xtrace.err"; then
  echo 'xtrace rejection case unexpectedly succeeded' >&2
  exit 1
fi
! grep -Fq "$secret_canary" "$tmp/xtrace.out" "$tmp/xtrace.err"

printf 'PASS validator identity restore command validation and redaction\n'
