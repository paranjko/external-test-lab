#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
on_genesis_error() {
  local rc=$?
  printf 'FAILED Genesis command at line %s (exit %s)\n' "$1" "$rc" >&2
  exit "$rc"
}
trap 'on_genesis_error "$LINENO"' ERR
load_project
assert_baseline_release
TIME_SPEC="${1:---time=+1m}"
[[ "$TIME_SPEC" =~ ^--time=\+([1-9][0-9]*)m$ ]] || die 'expected --time=+Nm'
GENESIS_LEAD_MINUTES="${BASH_REMATCH[1]}"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/genesis"
export EVIDENCE_PHASE_NAME=genesis
mkdir -p "$RUN"

continue_genesis_bootstrap() {
  step 'Start the public DevNet faucet for independent Host joins'
  "$ROOT/scripts/phase-ops.sh" faucet

  if [[ "${GDC_GENESIS_BOOTSTRAP_ACCESS:-true}" == true ]]; then
    step 'Install the configured public edge'
    GDC_PUBLIC_EDGE_VERIFY=false "$ROOT/scripts/phase-ops.sh" edge
    step 'Publish the complete JOIN bootstrap before independent operators can join'
    "$ROOT/scripts/phase-ops.sh" edge-node "$GENESIS_NODE"
    step 'Synchronize the published JOIN bootstrap on the public edge'
    GDC_PUBLIC_EDGE_VERIFY=false "$ROOT/scripts/phase-ops.sh" edge
    step 'Bootstrap authenticated inference for the single-validator network'
    "$ROOT/scripts/phase-bootstrap-access.sh"
    ops_env="$GDC_DATA_ROOT/.env"
    if [[ -s "$ops_env" ]] \
      && grep -Eq '^TELEGRAM_BOT_TOKEN=.+$' "$ops_env" \
      && ! grep -Eq '^TELEGRAM_BOT_TOKEN=replace-with-BotFather-token$' "$ops_env"; then
      step 'Refresh the Telegram inference consumer for the new gateway'
      GDC_ENV="$ops_env" "$ROOT/scripts/phase-gateway-access-key.sh" ensure telegram
      GDC_ENV="$ops_env" "$ROOT/scripts/phase-telegram-consumer.sh" apply
    else
      printf 'INFO Telegram consumer is not configured in the OPS environment; skipping its deployment\n'
    fi
    step 'Require bounded Genesis validator effectiveness before lifecycle success'
    "$ROOT/scripts/phase-join-acceptance.sh" "$GENESIS_NODE"
    step 'Create the Genesis validator recovery archive'
    "$ROOT/scripts/validator-backup.sh" create "$GENESIS_NODE"
    step 'Reconcile public monitoring from the fresh Genesis topology'
    "$ROOT/scripts/phase-ops.sh" monitoring
    step 'Verify the public status site'
    "$ROOT/scripts/phase-ops.sh" site
  else
    printf 'INCOMPLETE Genesis was created without bootstrap access; it is not a full lifecycle PASS\n' >&2
  fi
}

genesis_activation_is_current() {
  local address local_sha public_genesis participant
  [[ -e "$STATE/joined/$GENESIS_NODE" ]] || return 1
  [[ -s "$GENESIS/genesis.json" && -s "$ACCOUNTS/$GENESIS_NODE-cold.json" ]] || return 1
  address="$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")" || return 1
  local_sha="$(genesis_sha256 "$GENESIS/genesis.json")" || return 1
  public_genesis="$(mktemp)"
  if ! capture_canonical_genesis "https://${GENESIS_PUBLIC_HOST}/chain-rpc/genesis" "$public_genesis"; then
    rm -f "$public_genesis"
    return 1
  fi
  [[ "$(genesis_sha256 "$public_genesis")" == "$local_sha" ]] || { rm -f "$public_genesis"; return 1; }
  rm -f "$public_genesis"
  participant="$(ssh -T "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant/$address" 2>/dev/null || true)"
  jq -e '.participant.status == "ACTIVE" or .participant.status == "PARTICIPANT_STATUS_ACTIVE" or .participant.status == 1' <<<"$participant" >/dev/null 2>&1
}

if [[ -e "$STATE/joined/$GENESIS_NODE" ]]; then
  if ! genesis_activation_is_current; then
    die 'existing Genesis activation does not match the local ceremony or is not ACTIVE; reset the network before creating another Genesis'
  fi
  resume_sha="$(genesis_sha256 "$GENESIS/genesis.json")"
  write_phase_lineage "$RUN" "$CHAIN_ID" "$resume_sha" || die 'failed to bind resumed Genesis evidence to the active chain'
  printf 'READY resuming Genesis bootstrap from the verified ACTIVE participant\n'
  continue_genesis_bootstrap
  exit 0
fi

step 'Verify the operator inferenced CLI matches the selected release'
"$ROOT/scripts/ensure-inferenced-cli.sh"

# Genesis is the one-command path for a fresh, single-validator network.  It
# must not rely on an operator remembering preparatory phases from a previous
# rehearsal.  Scope host preparation and qualification to the requested
# Genesis alias; additional validators remain independent join operations.
GDC_PREPARE_HOSTS="$GENESIS_NODE" "$ROOT/scripts/phase-prepare.sh"
qualification_status=passed
if [[ "${GDC_GENESIS_SKIP_QUALIFICATION:-false}" == true ]]; then
  qualification_status=skipped_by_operator
  printf 'SKIP  ML qualification explicitly disabled by the Genesis operator\n'
else
  GDC_QUALIFY_HOSTS="$GENESIS_NODE" "$ROOT/scripts/phase-qualify-ml.sh"
  require_ml_qualification "$GENESIS_NODE"
fi
record_phase_profile genesis
printf 'ml_qualification=%s\n' "$qualification_status" >>"$STATE/phase-profiles/genesis.env"
printf 'PROFILE phase=genesis ml_qualification=%s\n' "$qualification_status"
genesis_identity_inputs=(
  "$SECRETS/operator.keyring"
  "$SECRETS/$GENESIS_NODE.keyring"
  "$SECRETS/$GENESIS_NODE.postgres"
  "$ACCOUNTS/$GENESIS_NODE-cold.json"
  "$ACCOUNTS/gdc-gateway-cold.json"
  "$ACCOUNTS/gdc-faucet-cold.json"
  "$IDENTITIES/$GENESIS_NODE.json"
)
identity_inputs_ready=true
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || identity_inputs_ready=false
done
# A host reset deliberately removes the remote inference directory while it
# preserves the operator's local account and identity evidence. Those local
# files alone cannot start a new Genesis: the node must also have the
# identity-bootstrap config.toml that init-identity.sh creates on the host.
if [[ "$identity_inputs_ready" == true ]] \
  && ! ssh -T "$GENESIS_NODE" "test -s '$DATA_ROOT/$GENESIS_NODE/inference/config/config.toml'"; then
  identity_inputs_ready=false
  printf 'READY remote Genesis identity state is absent; recreating it before Genesis\n'
fi
if [[ "$identity_inputs_ready" != true ]]; then
  step 'Create Genesis operator secrets, Genesis participant identities, and gateway account'
  "$ROOT/scripts/phase-identities.sh"
fi
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || die "Genesis identity input was not created: $input"
done
GENESIS_TIME="$(date -u -d "+${GENESIS_LEAD_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"

step "Build and verify the one-participant Genesis at $GENESIS_TIME"
"$ROOT/01-identities-genesis/build-genesis.sh" --inventory "$INVENTORY" --identities-dir "$IDENTITIES" --secrets-dir "$SECRETS" --genesis-time "$GENESIS_TIME" --output-dir "$GENESIS"
"$ROOT/01-identities-genesis/verify-genesis.sh" "$GENESIS/genesis.json" "$GENESIS/genesis.sha256" "$CHAIN_ID"
if ! GENESIS_SHA256="$(genesis_sha256 "$GENESIS/genesis.json")"; then
  die 'failed to calculate the canonical Genesis SHA-256'
fi
if ! write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"; then
  die 'failed to bind the Genesis evidence to this lifecycle run'
fi
for profile_field in genesis_sha256 genesis_overrides_sha256; do
  if ! profile_value="$(jq -er --arg field "$profile_field" '.[$field]' "$GENESIS/ceremony-record.json")"; then
    die "Genesis ceremony record is missing $profile_field"
  fi
  printf '%s=%s\n' "$profile_field" "$profile_value" >>"$STATE/phase-profiles/genesis.env"
  printf 'PROFILE phase=genesis %s=%s\n' "$profile_field" "$profile_value"
done

step "Render only $GENESIS_NODE"
NODE="$GENESIS_NODE"
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
GENESIS_RUNTIME_ID="$(runtime_id_for_participant "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")")"
record_runtime_identity "$NODE" "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")" "$GENESIS_RUNTIME_ID"
"$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNTS/$NODE-cold.json" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS" --output "$NODE_DIR/.env" >/dev/null
"$ROOT/02-node/render-node-config.sh" --node-name "$NODE" --runtime-id "$GENESIS_RUNTIME_ID" --output "$NODE_DIR/node-config.json" >/dev/null
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --output "$GENERATED/edge/$NODE.env"
"$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$NODE" --output "$GENERATED/agents/$NODE.env"

step "Install $NODE deployment"
ssh_ready "$NODE" || die "$NODE is unreachable; Genesis cannot be launched"
REMOTE="/tmp/gdc-deploy-$$-$NODE"
ssh "$NODE" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/02-node/" "$NODE:$REMOTE/02-node/"
rsync -a "$ROOT/03-join/" "$NODE:$REMOTE/03-join/"
rsync -a "$ROOT/04-ops/edge-node/" "$NODE:$REMOTE/edge/"
rsync -a "$ROOT/04-ops/agent/" "$NODE:$REMOTE/agent/"
scp -q "$NODE_DIR/.env" "$NODE:$REMOTE/node.env"
scp -q "$NODE_DIR/node-config.json" "$NODE:$REMOTE/node-config.json"
scp -q "$GENERATED/edge/$NODE.env" "$NODE:$REMOTE/edge.env"
scp -q "$GENERATED/agents/$NODE.env" "$NODE:$REMOTE/agent.env"
scp -q "$GENESIS/genesis.json" "$NODE:$REMOTE/genesis.json"
ssh -T "$NODE" "sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' --local-ml; sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; sudo '$REMOTE/agent/install-agent.sh' '$REMOTE/agent.env' --gpu; rm -rf '$REMOTE'"

step 'Start the Genesis participant'
start_stack "$NODE" /srv/dai/edge
start_stack "$NODE" /srv/dai/monitoring-agent
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh"

step 'Activate Genesis ML operations'
"$ROOT/03-join/wait-synced.sh" "https://$GENESIS_PUBLIC_HOST/chain-rpc" "https://$GENESIS_PUBLIC_HOST/chain-rpc"
record_join_state "$NODE" NODE_SYNCED "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
step 'Restart the Genesis API and colocated MLNode only after synchronization'
"$ROOT/03-join/restart-api-after-sync.sh" "$NODE"
"$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITIES/$NODE.json" "$INVENTORY"
"$ROOT/03-join/wait-active.sh" "https://$GENESIS_PUBLIC_HOST" "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
record_join_state "$NODE" ACTIVE "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
persist_runtime_topology
printf '\nGenesis launched with %s as the only participant.\n' "$NODE"

continue_genesis_bootstrap
