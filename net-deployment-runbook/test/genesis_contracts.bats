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

@test "community-lab renders a reproducible PoC timing profile" {
  output="$BATS_TEST_TMPDIR/overrides.json"

  run env GDC_RELEASE_PROFILE=v2026.07.23 GDC_DEPLOYMENT_PROFILE=community-lab \
    "$RUNBOOK/01-identities-genesis/render-genesis-overrides.sh" \
    --gateway-account "$GATEWAY" --genesis-guardian "$GUARDIAN" --output "$output"

  [ "$status" -eq 0 ]
  jq -e '
    .app_state.inference.params.epoch_params
    | .epoch_length == "50"
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
  mkdir -p "$(dirname "$password_file")"
  printf 'test-password\n' >"$password_file"

  run env GDC_HOME="$home_dir" \
    "$isolated/01-identities-genesis/create-cold-accounts.sh" "$password_file" gdc-node0

  [ "$status" -eq 0 ]
  [ "$(<"$home_dir/mnemonics/gdc-node0-cold.address")" = "$GATEWAY" ]
  [ "$(stat -c '%a' "$home_dir/mnemonics/gdc-node0-cold.address")" = 600 ]

  printf 'gonka1pppppppppppppppppppppppppppppppppppppp\n' >"$home_dir/mnemonics/gdc-node0-cold.address"
  run env GDC_HOME="$home_dir" \
    "$isolated/01-identities-genesis/create-cold-accounts.sh" "$password_file" gdc-node0

  [ "$status" -eq 1 ]
  [[ "$output" == *'cold-address backup disagrees with the keyring'* ]]
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

@test "independent JOIN uses one GDC_HOME and the verified bootstrap client credential" {
  acceptance="$RUNBOOK/scripts/phase-join-acceptance.sh"
  bootstrap="$RUNBOOK/scripts/fetch-join-bootstrap.sh"
  renderer="$RUNBOOK/04-ops/render-ops.sh"

  run grep -F 'KEY_FILE="$SECRETS/gateway.join-client-key"' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F 'install -m 0600 "$tmp/gateway/join-client-key" "$SECRETS/gateway.join-client-key"' "$bootstrap"
  [ "$status" -eq 0 ]
  run grep -F 'install -m 0644 "$SECRETS/gateway.join-client-key" "$bootstrap_dir/gateway/join-client-key"' "$renderer"
  [ "$status" -eq 0 ]
  run grep -F 'GDC_OPERATOR_MODE' "$RUNBOOK/ROLE-JOIN.md" "$acceptance" "$bootstrap" "$renderer" "$RUNBOOK/scripts/lib.sh" "$RUNBOOK/scripts/phase-genesis.sh" "$RUNBOOK/.devcontainer/README.md"
  [ "$status" -eq 1 ]
  run grep -F 'GDC_JOIN_GATEWAY_CLIENT_KEY_FILE' "$RUNBOOK/ROLE-JOIN.md" "$acceptance" "$bootstrap" "$renderer" "$RUNBOOK/scripts/lib.sh" "$RUNBOOK/scripts/phase-genesis.sh" "$RUNBOOK/.devcontainer/README.md"
  [ "$status" -eq 1 ]
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
