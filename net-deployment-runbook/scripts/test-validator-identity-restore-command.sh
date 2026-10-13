#!/usr/bin/env bash
set +x
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/build-validator-identity-restore-command.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '01234567890123456789012345678901' | base64 >"$tmp/softsign"
consensus_key="$("$ROOT/scripts/tmkms-softsign-public-key.sh" "$tmp/softsign")"
state=/srv/dai
candidate=/tmp/gdc-gdc-node1-validator-restore-123
deployment_env=/srv/dai/deploy/.env
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
    state-injection) test_state="/srv/dai;$secret_canary" ;;
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

# An untouched TMKMS state is a valid archive state.  Exercise the remote
# restore path, not merely the command renderer, so it stays aligned with the
# archive verifier and signing-state comparator.
mkdir -p "$tmp/bin" "$tmp/candidate/tmkms/secrets" "$tmp/candidate/tmkms/state" \
  "$tmp/candidate/inference/config"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/chown"
chmod 700 "$tmp/bin/chown"
printf '01234567890123456789012345678901' | base64 >"$tmp/candidate/tmkms/secrets/priv_validator_key.softsign"
printf 'abcdefghijklmnopqrstuvwxyzABCDEF' | base64 >"$tmp/candidate/tmkms/secrets/kms-identity.key"
initial_key="$("$ROOT/scripts/tmkms-softsign-public-key.sh" "$tmp/candidate/tmkms/secrets/priv_validator_key.softsign")"
base64 -d "$tmp/candidate/tmkms/secrets/priv_validator_key.softsign" >"$tmp/node-key.raw"
printf '%s' "$initial_key" | base64 -d >>"$tmp/node-key.raw"
jq -cn --rawfile key <(base64 <"$tmp/node-key.raw" | tr -d '\n') \
  '{priv_key:{type:"tendermint/PrivKeyEd25519",value:$key}}' >"$tmp/candidate/inference/config/node_key.json"
printf '%s\n' '{"block_id":{"hash":"","part_set_header":{"total":0,"hash":""}},"height":"0","round":"0","step":0}' \
  >"$tmp/candidate/tmkms/state/priv_validator_state.json"
cat >"$tmp/candidate/tmkms/tmkms.toml" <<'EOF'
state_file = "/root/.tmkms/state/priv_validator_state.json"
path = "/root/.tmkms/secrets/priv_validator_key.softsign"
secret_key = "/root/.tmkms/secrets/kms-identity.key"
EOF
initial_digest="$(
  cd "$tmp/candidate"
  find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'
)"
PATH="$tmp/bin:$PATH" GDC_VALIDATOR_IDENTITY_REMOTE=true GDC_VALIDATOR_IDENTITY_TEST_MODE=true \
  "$CHECK" "$tmp/state" "$tmp/candidate" "$initial_key" "$tmp/deploy/.env" "$initial_digest" \
  >"$tmp/initial-state.out"
[[ "$(<"$tmp/initial-state.out")" == installed ]]
[[ -s "$tmp/state/signer/tmkms/state/priv_validator_state.json" ]]

printf 'PASS validator identity restore command validation and redaction\n'
