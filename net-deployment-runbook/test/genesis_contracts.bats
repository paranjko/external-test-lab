#!/usr/bin/env bats

setup() {
  RUNBOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATEWAY='gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
  GUARDIAN='gonkavaloper1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr'
}

teardown() {
  if [[ -n "${MOCK_CHAIN_PID:-}" ]]; then
    kill "$MOCK_CHAIN_PID" 2>/dev/null || true
    wait "$MOCK_CHAIN_PID" 2>/dev/null || true
  fi
}

wait_for_mock_chain() {
  for _ in $(seq 1 20); do
    curl -fsS --connect-timeout 1 --max-time 1 http://127.0.0.1:26657/status >/dev/null && return 0
    sleep 0.1
  done
  return 1
}

prepare_genesis_role_input() {
  local home_dir="$1"
  local role_input="$home_dir/role.env"
  cat >"$role_input" <<'EOF'
GDC_NODE_ALIASES=gdc-node0
GDC_NODE_PUBLIC_HOSTS=gdc-node0=127.0.0.1
GDC_NODE_P2P_PORTS=gdc-node0=5000
GDC_GENESIS_NODE=gdc-node0
GDC_PUBLIC_EDGE_NODE=gdc-node0
GDC_GATEWAY_NODE=gdc-node0
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_GENESIS_ROLE_INPUT=true
EOF
  printf '%s\n' "$role_input"
}

prepare_pinned_cli_fixture() {
  local isolated="$1"
  local bin_dir="$isolated/test-bin"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/inferenced" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == version ]] || exit 2
printf 'inferenced 0.2.14\n'
EOF
  chmod +x "$bin_dir/inferenced"
  printf '%s\n' "$bin_dir"
}

prepare_validator_identity() {
  local destination="$1" soft_seed="$2" kms_seed="$3" node_seed="$4"
  local pubkey_helper="$RUNBOOK/scripts/tmkms-softsign-public-key.sh"
  local node_public node_private
  install -d -m 0700 "$destination/tmkms/secrets" "$destination/tmkms/state" \
    "$destination/inference/config"
  printf '%s' "$soft_seed" | base64 >"$destination/tmkms/secrets/priv_validator_key.softsign"
  printf '%s' "$kms_seed" | base64 >"$destination/tmkms/secrets/kms-identity.key"
  cat >"$destination/tmkms/tmkms.toml" <<'EOF'
[[chain]]
id = "test-chain"
state_file = "/root/.tmkms/state/priv_validator_state.json"
[[providers.softsign]]
chain_ids = ["test-chain"]
key_type = "consensus"
path = "/root/.tmkms/secrets/priv_validator_key.softsign"
[[validator]]
chain_id = "test-chain"
addr = "tcp://node:26658"
secret_key = "/root/.tmkms/secrets/kms-identity.key"
protocol_version = "v0.34"
EOF
  jq -n '{height:"10",round:"0",step:6,block_id:{hash:("A" * 64),
    part_set_header:{total:1,hash:("B" * 64)}}}' \
    >"$destination/tmkms/state/priv_validator_state.json"
  printf '%s' "$node_seed" | base64 >"$BATS_TEST_TMPDIR/node-seed.base64"
  node_public="$("$pubkey_helper" "$BATS_TEST_TMPDIR/node-seed.base64")"
  printf '%s' "$node_seed" >"$BATS_TEST_TMPDIR/node-key.raw"
  printf '%s' "$node_public" | base64 -d >>"$BATS_TEST_TMPDIR/node-key.raw"
  node_private="$(base64 <"$BATS_TEST_TMPDIR/node-key.raw" | tr -d '\n')"
  jq -n --arg value "$node_private" \
    '{priv_key:{type:"tendermint/PrivKeyEd25519",value:$value}}' \
    >"$destination/inference/config/node_key.json"
  find "$destination" -type d -exec chmod 0700 {} +
  find "$destination" -type f -exec chmod 0600 {} +
}

validator_identity_digest() {
  local root="$1"
  (
    cd "$root"
    find . -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print $1}'
}

@test "community-lab renders a reproducible PoC timing profile" {
  output="$BATS_TEST_TMPDIR/overrides.json"

  run env GDC_RELEASE_PROFILE=v2026.07.23 GDC_DEPLOYMENT_PROFILE=community-lab \
    "$RUNBOOK/01-identities-genesis/render-genesis-overrides.sh" \
    --gateway-account "$GATEWAY" --genesis-guardian "$GUARDIAN" --output "$output"

  [ "$status" -eq 0 ]
  jq -e '
    .app_state.inference.params.epoch_params
    | .epoch_length == "70"
    and .confirmation_poc_safety_window == "10"
    and .poc_stage_duration == "4"
    and .poc_exchange_duration == "8"
    and .poc_validation_delay == "10"
    and .poc_validation_duration == "4"
    and .set_new_validators_delay == "1"
  ' "$output"
}

@test "cold account keeps its public address next to the mnemonic and refuses mismatch" {
  isolated="$BATS_TEST_TMPDIR/runbook"
  home_dir="$BATS_TEST_TMPDIR/operator"
  password_file="$home_dir/state/secrets/operator.keyring"
  cp -a "$RUNBOOK" "$isolated"
  cp "$RUNBOOK/test/fixtures/inferenced.sh" "$isolated/scripts/inferenced.sh"
  chmod +x "$isolated/scripts/inferenced.sh"
  cli_bin="$(prepare_pinned_cli_fixture "$isolated")"
  mkdir -p "$(dirname "$password_file")"
  printf 'test-password\n' >"$password_file"
  role_input="$(prepare_genesis_role_input "$home_dir")"

  run env PATH="$cli_bin:$PATH" GDC_HOME="$home_dir" GDC_ENV="$role_input" \
    "$isolated/01-identities-genesis/create-cold-accounts.sh" "$password_file" gdc-node0

  [ "$status" -eq 0 ]
  [ "$(<"$home_dir/mnemonics/gdc-node0-cold.address")" = "$GATEWAY" ]
  [ "$(stat -c '%a' "$home_dir/mnemonics/gdc-node0-cold.address")" = 600 ]

  printf 'gonka1pppppppppppppppppppppppppppppppppppppp\n' >"$home_dir/mnemonics/gdc-node0-cold.address"
  run env PATH="$cli_bin:$PATH" GDC_HOME="$home_dir" GDC_ENV="$role_input" \
    "$isolated/01-identities-genesis/create-cold-accounts.sh" "$password_file" gdc-node0

  [ "$status" -eq 1 ]
  [[ "$output" == *'cold-address backup disagrees with the keyring'* ]]
}

@test "cold account restores its local file keyring from its own mnemonic" {
  isolated="$BATS_TEST_TMPDIR/runbook"
  home_dir="$BATS_TEST_TMPDIR/operator"
  password_file="$home_dir/state/secrets/operator.keyring"
  cp -a "$RUNBOOK" "$isolated"
  cp "$RUNBOOK/test/fixtures/inferenced.sh" "$isolated/scripts/inferenced.sh"
  chmod +x "$isolated/scripts/inferenced.sh"
  cli_bin="$(prepare_pinned_cli_fixture "$isolated")"
  mkdir -p "$(dirname "$password_file")"
  printf 'test-password\n' >"$password_file"
  role_input="$(prepare_genesis_role_input "$home_dir")"

  run env PATH="$cli_bin:$PATH" GDC_HOME="$home_dir" GDC_ENV="$role_input" \
    "$isolated/01-identities-genesis/create-cold-accounts.sh" "$password_file" gdc-node0
  [ "$status" -eq 0 ]
  rm -f "$home_dir/stub-keyring/gdc-node0-cold"

  run env PATH="$cli_bin:$PATH" GDC_HOME="$home_dir" GDC_ENV="$role_input" \
    "$isolated/01-identities-genesis/create-cold-accounts.sh" "$password_file" gdc-node0

  [ "$status" -eq 0 ]
  [[ "$output" == *'ACCOUNTS  recovered=1'* ]]
  [ -e "$home_dir/stub-keyring/gdc-node0-cold" ]
  [ "$(jq -r .address "$home_dir/accounts/gdc-node0-cold.json")" = "$GATEWAY" ]
}

@test "running Host recovery rejects a wrong cold mnemonic behind a retained keyring" {
  isolated="$BATS_TEST_TMPDIR/runbook"
  home_dir="$BATS_TEST_TMPDIR/operator"
  password_file="$home_dir/state/secrets/operator.keyring"
  cp -a "$RUNBOOK" "$isolated"
  cp "$RUNBOOK/test/fixtures/inferenced.sh" "$isolated/scripts/inferenced.sh"
  chmod +x "$isolated/scripts/inferenced.sh"
  cli_bin="$(prepare_pinned_cli_fixture "$isolated")"
  mkdir -p "$(dirname "$password_file")"
  printf 'test-password\n' >"$password_file"
  role_input="$(prepare_genesis_role_input "$home_dir")"

  run env PATH="$cli_bin:$PATH" GDC_HOME="$home_dir" GDC_ENV="$role_input" \
    "$isolated/01-identities-genesis/create-cold-accounts.sh" "$password_file" gdc-node0
  [ "$status" -eq 0 ]
  [ "$(jq -r .address "$home_dir/accounts/gdc-node0-cold.json")" = "$GATEWAY" ]

  printf '%s\n' \
    'wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong' \
    >"$home_dir/mnemonics/wrong-cold.mnemonic"
  run env PATH="$cli_bin:$PATH" GDC_HOME="$home_dir" GDC_ENV="$role_input" \
    "$isolated/scripts/derive-mnemonic-identity.sh" \
    "$home_dir/mnemonics/wrong-cold.mnemonic" "$password_file" cold-recovery-check "$GATEWAY"

  [ "$status" -eq 1 ]
  [[ "$output" == *'recovery mnemonic controls another account address'* ]]
  [ "$(jq -r .address "$home_dir/accounts/gdc-node0-cold.json")" = "$GATEWAY" ]
}

@test "gateway renderer rejects the zero-capacity limits that make a READY runtime return 429" {
  renderer="$RUNBOOK/04-ops/create-gateway.sh"

  run grep -F 'MAX_CONCURRENT_REQUESTS="${GDC_GATEWAY_MAX_CONCURRENT_REQUESTS:-4}"' "$renderer"
  [ "$status" -eq 0 ]
  run grep -F 'MAX_INPUT_TOKENS_IN_FLIGHT="${GDC_GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT:-4096}"' "$renderer"
  [ "$status" -eq 0 ]
  run grep -F 'must be a positive integer' "$renderer"
  [ "$status" -eq 0 ]
}

@test "gateway reconciliation uses public participant state rather than another Host account artifact" {
  renderer="$RUNBOOK/04-ops/create-gateway.sh"

  run grep -F 'OPS must use public chain state here' "$renderer"
  [ "$status" -eq 0 ]
  run grep -F 'active_participant_count' "$renderer"
  [ "$status" -eq 0 ]
  run grep -F 'Missing account artifact for' "$renderer"
  [ "$status" -ne 0 ]
}

@test "independent JOIN stages a verified one-file bootstrap without publishing credentials" {
  acceptance="$RUNBOOK/scripts/phase-join-acceptance.sh"
  bootstrap="$RUNBOOK/scripts/stage-network-bootstrap.sh"
  renderer="$RUNBOOK/04-ops/render-ops.sh"

  run grep -F 'KEY_FILE="$SECRETS/gateway.join-client-key"' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F 'gateway.join-client-key' "$bootstrap"
  [ "$status" -eq 0 ]
  run grep -F 'gateway.join-client-key' "$renderer"
  [ "$status" -ne 0 ]
  run grep -F 'GDC_OPERATOR_MODE' "$RUNBOOK/ROLE-JOIN.md" "$acceptance" "$bootstrap" "$renderer" "$RUNBOOK/scripts/lib.sh" "$RUNBOOK/scripts/phase-genesis.sh"
  [ "$status" -eq 1 ]
  run grep -F 'GDC_JOIN_GATEWAY_CLIENT_KEY_FILE' "$RUNBOOK/ROLE-JOIN.md" "$acceptance" "$bootstrap" "$renderer" "$RUNBOOK/scripts/lib.sh" "$RUNBOOK/scripts/phase-genesis.sh"
  [ "$status" -eq 1 ]
}

@test "protected existing validator identity is compared without remote writes" {
  [[ "${GDC_BATS_CONTAINER:-}" == true ]] || skip 'requires make bats-docker'
  state="$BATS_TEST_TMPDIR/state"
  candidate="$BATS_TEST_TMPDIR/candidate"
  helper="$RUNBOOK/scripts/build-validator-identity-restore-command.sh"
  pubkey_helper="$RUNBOOK/scripts/tmkms-softsign-public-key.sh"
  deployment_env="$BATS_TEST_TMPDIR/deploy/.env"
  prepare_validator_identity "$state" \
    01234567890123456789012345678901 \
    abcdefghijklmnopqrstuvwxyzABCDEF \
    12345678901234567890123456789012
  consensus_key="$("$pubkey_helper" "$state/tmkms/secrets/priv_validator_key.softsign")"
  cp -a "$state" "$candidate"
  chown -R root:root "$state"
  install -d -m 0700 "$(dirname "$deployment_env")"
  printf 'deployed=true\n' >"$deployment_env"
  before="$(find "$state" -type f -print0 | sort -z | xargs -0 sha256sum)"
  bundle_sha256="$(validator_identity_digest "$candidate")"

  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"

  [ "$status" -eq 0 ]
  [ "$output" = existing ]
  [ "$(find "$state" -type f -print0 | sort -z | xargs -0 sha256sum)" = "$before" ]

  for state_case in float negative overflow wrong-type; do
    candidate="$BATS_TEST_TMPDIR/state-$state_case-candidate"
    cp -a "$state" "$candidate"
    case "$state_case" in
      float) mutation='.block_id.part_set_header.total = 1.5' ;;
      negative) mutation='.block_id.part_set_header.total = -1' ;;
      overflow) mutation='.block_id.part_set_header.total = 4294967296' ;;
      wrong-type) mutation='.block_id.part_set_header.total = "1"' ;;
    esac
    jq "$mutation" "$state/tmkms/state/priv_validator_state.json" \
      >"$BATS_TEST_TMPDIR/state-$state_case.json"
    mv "$BATS_TEST_TMPDIR/state-$state_case.json" \
      "$candidate/tmkms/state/priv_validator_state.json"
    bundle_sha256="$(validator_identity_digest "$candidate")"

    run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
      "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"

    [ "$status" -ne 0 ]
    [[ "$output" == *'malformed TMKMS signing state'* ]]
    [ "$(find "$state" -type f -print0 | sort -z | xargs -0 sha256sum)" = "$before" ]
  done

  candidate="$BATS_TEST_TMPDIR/wrong-consensus-candidate"
  cp -a "$state" "$candidate"
  printf '12345678901234567890123456789012' | base64 >"$BATS_TEST_TMPDIR/other.softsign"
  wrong_consensus_key="$("$pubkey_helper" "$BATS_TEST_TMPDIR/other.softsign")"
  bundle_sha256="$(validator_identity_digest "$candidate")"

  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    "$helper" "$state" "$candidate" "$wrong_consensus_key" "$deployment_env" "$bundle_sha256"

  [ "$status" -ne 0 ]
  [[ "$output" == *'staged TMKMS key does not match the validator backup consensus identity'* ]]
  [ "$(find "$state" -type f -print0 | sort -z | xargs -0 sha256sum)" = "$before" ]

  candidate="$BATS_TEST_TMPDIR/mismatched-candidate"
  prepare_validator_identity "$candidate" \
    01234567890123456789012345678901 \
    ZYXWVUTSRQPONMLKJIHGFEDCBA987654 \
    12345678901234567890123456789012
  bundle_sha256="$(validator_identity_digest "$candidate")"

  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"

  [ "$status" -ne 0 ]
  [[ "$output" == *'running validator identity does not match the supplied backup'* ]]
  [ "$(find "$state" -type f -print0 | sort -z | xargs -0 sha256sum)" = "$before" ]
}

@test "validator restore command rejects archive shell injection before SSH" {
  command_builder="$RUNBOOK/scripts/build-validator-identity-restore-command.sh"
  pubkey_helper="$RUNBOOK/scripts/tmkms-softsign-public-key.sh"
  printf '01234567890123456789012345678901' | base64 >"$BATS_TEST_TMPDIR/softsign"
  consensus_key="$("$pubkey_helper" "$BATS_TEST_TMPDIR/softsign")"
  bundle_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  run "$command_builder" \
    /srv/dai/gdc-node1 \
    /tmp/gdc-gdc-node1-validator-restore-123 \
    "$consensus_key" \
    /srv/dai/deploy/gdc-node1/.env \
    "$bundle_sha256"

  [ "$status" -eq 0 ]
  [[ "$output" == sudo\ env\ GDC_VALIDATOR_IDENTITY_REMOTE=true\ bash\ -s\ --* ]]

  malicious_key="bad'; printf '%s\\n' ARCHIVE_COMMAND_EXECUTED; : '"
  run "$command_builder" \
    /srv/dai/gdc-node1 \
    /tmp/gdc-gdc-node1-validator-restore-123 \
    "$malicious_key" \
    /srv/dai/deploy/gdc-node1/.env \
    "$bundle_sha256"

  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid consensus public key'* ]]
  [[ "$output" != *'ARCHIVE_COMMAND_EXECUTED'* ]]
}

@test "schema-v1 backup without ml_host requires the live split topology binding" {
  backup="$RUNBOOK/scripts/validator-backup.sh"
  evaluator="$RUNBOOK/scripts/evaluate-running-host-recovery.sh"
  consensus_key="$(printf '01234567890123456789012345678901' | base64 | tr -d '\n')"
  warm_key="$(printf '123456789012345678901234567890123' | base64 | tr -d '\n')"
  jq -n --arg consensus "$consensus_key" --arg warm "$warm_key" '
    {node_name:"gdc-node4",node_id:"0123456789abcdef0123456789abcdef01234567",
     consensus_pubkey:$consensus,warm_address:"gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
     warm_pubkey_b64:$warm}
  ' >"$BATS_TEST_TMPDIR/identity.json"
  jq -n --slurpfile identity "$BATS_TEST_TMPDIR/identity.json" '
    {schema_version:1,node_name:"gdc-node4",created_at:"2026-08-20T12:00:00Z",
     chain_id:"test-chain",genesis_sha256:("a" * 64),
     participant_address:"gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
     identity:$identity[0]}
  ' >"$BATS_TEST_TMPDIR/manifest.json"

  run env GDC_VALIDATOR_BACKUP_TEST_MODE=true "$backup" validate-manifest \
    "$BATS_TEST_TMPDIR/manifest.json" "$BATS_TEST_TMPDIR/identity.json" gdc-node4
  [ "$status" -eq 0 ]

  jq '.unexpected = true' "$BATS_TEST_TMPDIR/manifest.json" \
    >"$BATS_TEST_TMPDIR/extra-manifest.json"
  run env GDC_VALIDATOR_BACKUP_TEST_MODE=true "$backup" validate-manifest \
    "$BATS_TEST_TMPDIR/extra-manifest.json" "$BATS_TEST_TMPDIR/identity.json" gdc-node4
  [ "$status" -ne 0 ]
  [[ "$output" == *'manifest metadata is malformed or inconsistent'* ]]

  jq '.ml_host = "bad alias"' "$BATS_TEST_TMPDIR/manifest.json" \
    >"$BATS_TEST_TMPDIR/malformed-manifest.json"
  run env GDC_VALIDATOR_BACKUP_TEST_MODE=true "$backup" validate-manifest \
    "$BATS_TEST_TMPDIR/malformed-manifest.json" "$BATS_TEST_TMPDIR/identity.json" gdc-node4
  [ "$status" -ne 0 ]
  [[ "$output" == *'manifest metadata is malformed or inconsistent'* ]]

  runtime_id='qwen3-0.6b:gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
  printf '%s\n' \
    '{"schema_version":1,"validator_alias":"gdc-node4","ml_ssh_alias":"gdc-node4-ml","ml_endpoint":"192.0.2.44"}' \
    >"$BATS_TEST_TMPDIR/live-link.json"
  jq -n --arg runtime_id "$runtime_id" \
    '[{id:$runtime_id,host:"192.0.2.44"}]' >"$BATS_TEST_TMPDIR/live-runtime.json"

  run "$evaluator" topology \
    gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 false '' \
    "$BATS_TEST_TMPDIR/live-link.json" "$BATS_TEST_TMPDIR/live-runtime.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .backup_topology_binding <<<"$output")" = live-running-host ]

  run "$evaluator" topology \
    gdc-node4 "$runtime_id" gdc-node4-other 192.0.2.44 false '' \
    "$BATS_TEST_TMPDIR/live-link.json" "$BATS_TEST_TMPDIR/live-runtime.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *'running split-GPU binding disagrees'* ]]

  run "$evaluator" topology \
    gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.45 false '' \
    "$BATS_TEST_TMPDIR/live-link.json" "$BATS_TEST_TMPDIR/live-runtime.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *'running split-GPU binding disagrees'* ]]
}

@test "recovery topology rejects another or extra deployed runtime identity" {
  evaluator="$RUNBOOK/scripts/evaluate-running-host-recovery.sh"
  runtime_id='qwen3-0.6b:gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
  wrong_runtime_id='qwen3-0.6b:gonka1pppppppppppppppppppppppppppppppppppppp'
  printf '%s\n' \
    '{"schema_version":1,"validator_alias":"gdc-node4","ml_ssh_alias":"gdc-node4-ml","ml_endpoint":"192.0.2.44"}' \
    >"$BATS_TEST_TMPDIR/link.json"
  jq -n --arg runtime_id "$wrong_runtime_id" \
    '[{id:$runtime_id,host:"192.0.2.44"}]' >"$BATS_TEST_TMPDIR/wrong-runtime.json"

  run "$evaluator" topology \
    gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 false '' \
    "$BATS_TEST_TMPDIR/link.json" "$BATS_TEST_TMPDIR/wrong-runtime.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *'another or malformed runtime identity'* ]]

  jq -n --arg runtime_id "$runtime_id" '[
    {id:$runtime_id,host:"192.0.2.44"},
    {id:"qwen3-0.6b:gonka1extra",host:"192.0.2.44"}
  ]' >"$BATS_TEST_TMPDIR/extra-runtime.json"

  run "$evaluator" topology \
    gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 false '' \
    "$BATS_TEST_TMPDIR/link.json" "$BATS_TEST_TMPDIR/extra-runtime.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *'another or malformed runtime identity'* ]]
}

@test "interrupted validator identity restore resumes installation until deployment exists" {
  [[ "${GDC_BATS_CONTAINER:-}" == true ]] || skip 'requires make bats-docker'
  state="$BATS_TEST_TMPDIR/state"
  candidate="$BATS_TEST_TMPDIR/candidate"
  deployment_env="$BATS_TEST_TMPDIR/deploy/.env"
  helper="$RUNBOOK/scripts/build-validator-identity-restore-command.sh"
  pubkey_helper="$RUNBOOK/scripts/tmkms-softsign-public-key.sh"
  prepare_validator_identity "$candidate" \
    01234567890123456789012345678901 \
    abcdefghijklmnopqrstuvwxyzABCDEF \
    12345678901234567890123456789012
  consensus_key="$("$pubkey_helper" "$candidate/tmkms/secrets/priv_validator_key.softsign")"
  bundle_sha256="$(validator_identity_digest "$candidate")"

  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    GDC_VALIDATOR_IDENTITY_TEST_INTERRUPT=before-activate \
    "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"
  [ "$status" -ne 0 ]
  [ ! -e "$state" ]

  candidate="$BATS_TEST_TMPDIR/retry-candidate"
  prepare_validator_identity "$candidate" \
    01234567890123456789012345678901 \
    abcdefghijklmnopqrstuvwxyzABCDEF \
    12345678901234567890123456789012
  bundle_sha256="$(validator_identity_digest "$candidate")"
  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"
  [ "$status" -eq 0 ]
  [ "$output" = installed ]
  [ "$(<"$state/.gdc-validator-identity-restore.sha256")" = "$bundle_sha256" ]

  candidate="$BATS_TEST_TMPDIR/resume-candidate"
  prepare_validator_identity "$candidate" \
    01234567890123456789012345678901 \
    abcdefghijklmnopqrstuvwxyzABCDEF \
    12345678901234567890123456789012
  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"
  [ "$status" -eq 0 ]
  [ "$output" = installed ]

  install -d -m 0700 "$(dirname "$deployment_env")"
  printf 'deployed=true\n' >"$deployment_env"
  candidate="$BATS_TEST_TMPDIR/running-candidate"
  prepare_validator_identity "$candidate" \
    01234567890123456789012345678901 \
    abcdefghijklmnopqrstuvwxyzABCDEF \
    12345678901234567890123456789012
  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"
  [ "$status" -eq 0 ]
  [ "$output" = existing ]
}

@test "partial validator identity state is never accepted as resumable" {
  [[ "${GDC_BATS_CONTAINER:-}" == true ]] || skip 'requires make bats-docker'
  state="$BATS_TEST_TMPDIR/partial-state"
  candidate="$BATS_TEST_TMPDIR/partial-candidate"
  deployment_env="$BATS_TEST_TMPDIR/deploy-partial/.env"
  helper="$RUNBOOK/scripts/build-validator-identity-restore-command.sh"
  pubkey_helper="$RUNBOOK/scripts/tmkms-softsign-public-key.sh"
  prepare_validator_identity "$candidate" \
    01234567890123456789012345678901 \
    abcdefghijklmnopqrstuvwxyzABCDEF \
    12345678901234567890123456789012
  consensus_key="$("$pubkey_helper" "$candidate/tmkms/secrets/priv_validator_key.softsign")"
  bundle_sha256="$(validator_identity_digest "$candidate")"
  install -d -m 0700 "$state/tmkms/secrets"
  cp "$candidate/tmkms/secrets/priv_validator_key.softsign" \
    "$state/tmkms/secrets/priv_validator_key.softsign"

  run env GDC_VALIDATOR_IDENTITY_TEST_MODE=true GDC_VALIDATOR_IDENTITY_REMOTE=true \
    "$helper" "$state" "$candidate" "$consensus_key" "$deployment_env" "$bundle_sha256"

  [ "$status" -ne 0 ]
  [[ "$output" == *'partial, mixed, or ambiguous'* ]]
}

@test "container host mock restarts DAPI and colocated MLNode only after sync" {
  [[ "${GDC_BATS_CONTAINER:-}" == true ]] || skip 'requires make bats-docker'
  fake_bin="$BATS_TEST_TMPDIR/mock-bin"
  mock_log="$BATS_TEST_TMPDIR/docker.log"
  install -d -m 0755 "$fake_bin" /srv/dai/deploy/gdc-node1
  cp "$RUNBOOK/test/fixtures/mock-host-bin/"* "$fake_bin/"
  chmod +x "$fake_bin/"*
  : >/srv/dai/deploy/gdc-node1/compose.yaml
  : >/srv/dai/deploy/gdc-node1/compose.ml-local.yaml
  printf 'true\n' >/srv/dai/deploy/gdc-node1/.local-ml
  python3 "$RUNBOOK/test/fixtures/mock-chain-server.py" >/dev/null 2>&1 &
  MOCK_CHAIN_PID=$!
  wait_for_mock_chain

  run env PATH="$fake_bin:$PATH" GDC_MOCK_DOCKER_LOG="$mock_log" \
    GDC_API_RESTART_WAIT_SECONDS=5 "$RUNBOOK/03-join/restart-api-after-sync.sh" gdc-node1

  [ "$status" -eq 0 ]
  [[ "$output" == *'READY post-sync services restarted: api mlnode'* ]]
  grep -Fxq 'restart api mlnode' "$mock_log"
  grep -Fxq 'ps api mlnode --format {{.Service}} {{.State}}' "$mock_log"
}

@test "DinD Host runs the real Compose restart for DAPI and MLNode" {
  [[ "${GDC_BATS_DIND:-}" == true ]] || skip 'requires make bats-dind'
  fake_bin="$BATS_TEST_TMPDIR/transport-bin"
  deploy_dir=/srv/dai/deploy/gdc-node1
  install -d -m 0755 "$fake_bin" "$deploy_dir"
  cp "$RUNBOOK/test/fixtures/mock-host-bin/ssh" "$fake_bin/"
  cp "$RUNBOOK/test/fixtures/mock-host-bin/sudo" "$fake_bin/"
  chmod +x "$fake_bin/"*
  install -d -m 0755 "$deploy_dir/mock-chain"
  printf '%s\n' '{"result":{"sync_info":{"catching_up":false}}}' >"$deploy_dir/mock-chain/status"
  cat >"$deploy_dir/compose.yaml" <<'YAML'
services:
  chain:
    image: busybox:1.36
    network_mode: host
    command: ["httpd", "-f", "-p", "26657", "-h", "/www"]
    volumes:
      - ./mock-chain:/www:ro
  api:
    image: busybox:1.36
    command: ["sh", "-c", "sleep infinity"]
YAML
  cat >"$deploy_dir/compose.ml-local.yaml" <<'YAML'
services:
  mlnode:
    image: busybox:1.36
    command: ["sh", "-c", "sleep infinity"]
YAML
  printf 'true\n' >"$deploy_dir/.local-ml"
  docker compose -f "$deploy_dir/compose.yaml" -f "$deploy_dir/compose.ml-local.yaml" -p gdc-node1 up -d
  wait_for_mock_chain

  run env PATH="$fake_bin:$PATH" GDC_API_RESTART_WAIT_SECONDS=15 \
    "$RUNBOOK/03-join/restart-api-after-sync.sh" gdc-node1

  [ "$status" -eq 0 ]
  [[ "$output" == *'READY post-sync services restarted: api mlnode'* ]]
  run docker compose -f "$deploy_dir/compose.yaml" -f "$deploy_dir/compose.ml-local.yaml" -p gdc-node1 ps --format '{{.Service}} {{.State}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'api running'* ]]
  [[ "$output" == *'mlnode running'* ]]
}
