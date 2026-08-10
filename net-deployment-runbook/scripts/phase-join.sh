#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
NODE="$(node_name "${1:-}")"
INDEX="$(node_index "$NODE")"
BASELINE="$STATE/phase-profiles/genesis.env"
if [[ ! -s "$BASELINE" ]]; then
  step 'Import public Genesis bootstrap for this independent Host join'
  "$ROOT/scripts/fetch-join-bootstrap.sh"
fi
[[ -s "$BASELINE" ]] || die 'public Genesis bootstrap did not provide a baseline profile'
grep -qx 'release_profile=v2026.07.23' "$BASELINE" || die 'join requires a Genesis formed from v2026.07.23'
record_phase_profile "join-${NODE}"
ML_TARGET="$(node_ml_host "$NODE" || printf '%s' "$NODE")"
if [[ "$(node_gpu_profile "$NODE")" == auto ]]; then
  step "Detect GPU profile for $NODE"
  detected_gpu_profile="$("$ROOT/scripts/detect-gpu-profile.sh" "$ML_TARGET")"
  updated_gpu_profiles=''
  for topology_node in "${GDC_NODES[@]}"; do
    topology_profile="$(node_gpu_profile "$topology_node")"
    [[ "$topology_node" == "$NODE" ]] && topology_profile="$detected_gpu_profile"
    updated_gpu_profiles+="${updated_gpu_profiles:+ }$topology_node=$topology_profile"
  done
  GDC_NODE_GPU_PROFILES="$updated_gpu_profiles"
  export GDC_NODE_GPU_PROFILES
  load_topology
  write_inventory
  printf 'READY %s GPU profile detected as %s\n' "$NODE" "$detected_gpu_profile"
fi
if [[ "${GDC_JOIN_SKIP_QUALIFICATION:-false}" == true ]]; then
  printf 'SKIP  ML qualification explicitly disabled by the joining Host operator\n'
else
  ensure_ml_qualification "$ML_TARGET"
fi
URL="$(node_url "$NODE")"
PUBLIC_HOST="${URL#https://}"
getent ahostsv4 "$PUBLIC_HOST" | grep -q . || die "$PUBLIC_HOST does not resolve to IPv4"
ACCOUNT="$ACCOUNTS/$NODE-cold.json"
IDENTITY="$IDENTITIES/$NODE.json"
[[ -s "$GENESIS/genesis.json" && -s "$GENESIS/genesis-seeds.txt" ]] || die 'run genesis first'

# Every joining Host creates and owns its local keyring passwords before it
# creates any account. No Genesis operator key, funding approval, or
# cross-operator secret transfer is needed.
if [[ ! -s "$SECRETS/operator.keyring" || ! -s "$SECRETS/$NODE.keyring" || ! -s "$SECRETS/$NODE.postgres" ]]; then
  step "Create scoped operator secrets for $NODE"
  "$ROOT/scripts/make-node-operator-secrets.sh" "$NODE" "$SECRETS"
fi

if [[ ! -s "$ACCOUNT" ]]; then
  step "Create $NODE cold account"
  "$ROOT/01-identities-genesis/create-cold-accounts.sh" "$SECRETS/operator.keyring" "$NODE"
fi
[[ -s "$ACCOUNT" ]] || die "missing public cold account for $NODE"

if [[ ! -s "$IDENTITY" ]]; then
  step "Create $NODE identity"
  "$ROOT/01-identities-genesis/collect-identities.sh" "$INVENTORY" "$SECRETS" "$IDENTITIES" "$GDC_HOME/mnemonics" "$NODE"
fi

step "Render $NODE"
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
env_args=(--inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNT" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS")
ML_HOST="$(node_ml_host "$NODE" || true)"
if [[ -n "$ML_HOST" ]]; then
  callback_address="$(getent ahostsv4 "$(node_public_host "$NODE")" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  if [[ ! "$callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    callback_address="$(ssh -G "$NODE" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}' || true)"
  fi
  [[ "$callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot determine callback IPv4 for $NODE"
  env_args+=(--poc-callback-url "http://$callback_address:9100" --ml-callback-bind 0.0.0.0)
fi
"$ROOT/02-node/render-node-env.sh" "${env_args[@]}" --output "$NODE_DIR/.env" >/dev/null
config_args=(--node-name "$NODE" --node-index "$INDEX" --profile "$(node_gpu_profile "$NODE")" --output "$NODE_DIR/node-config.json")
if [[ -n "$ML_HOST" ]]; then
  ML_ENDPOINT="$(ssh -G "$ML_HOST" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
  [[ -n "$ML_ENDPOINT" ]] || die "cannot determine network GPU endpoint from SSH alias $ML_HOST"
  config_args+=(--ml-host "$ML_ENDPOINT" --ml-poc-port 5000)
fi
"$ROOT/02-node/render-node-config.sh" "${config_args[@]}" >/dev/null
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --output "$GENERATED/edge/$NODE.env" >/dev/null
"$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$NODE" --output "$GENERATED/agents/$NODE.env" >/dev/null

step "Install $NODE deployment"
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
local_ml=(); gpu=()
[[ -z "$ML_HOST" ]] && local_ml=(--local-ml) && gpu=(--gpu)
ssh -T "$NODE" "sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' ${local_ml[*]}; sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; sudo '$REMOTE/agent/install-agent.sh' '$REMOTE/agent.env' ${gpu[*]}; rm -rf '$REMOTE'"

step "Start $NODE"
start_stack "$NODE" /srv/dai/edge
start_stack "$NODE" /srv/dai/monitoring-agent
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh"

step "Wait until $NODE is synchronized"
"$ROOT/03-join/wait-synced.sh" "$URL/chain-rpc" "https://$GENESIS_PUBLIC_HOST/chain-rpc"
ADDRESS="$(jq -r .address "$ACCOUNT")"
participant_body="$(curl --connect-timeout 5 --max-time 10 -fsS "https://$GENESIS_PUBLIC_HOST/v2/participants/$ADDRESS" 2>/dev/null || true)"
participant_status="$(jq -r '.participant.status // empty' <<<"$participant_body" 2>/dev/null || true)"
participant_state="$(participant_onboarding_state "$participant_status")"
case "$participant_state" in
  active)
    already_registered=true
    already_active=true
    ;;
  new)
    already_registered=false
    already_active=false
    ;;
  registered)
    already_registered=true
    already_active=false
    ;;
  invalid)
    die "$NODE participant is INVALID; recovery requires an explicit chain-state decision, not duplicate funding"
    ;;
esac

if [[ "$already_registered" == true ]]; then
  printf 'READY %s participant already registered with status=%s; skip duplicate registration\n' "$NODE" "$participant_status"
else
  step "Register $NODE before funding"
  registration_timeout="${GDC_JOIN_REGISTRATION_TIMEOUT_SECONDS:-300}"
  [[ "$registration_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_JOIN_REGISTRATION_TIMEOUT_SECONDS must be positive'
  registration_deadline=$((SECONDS + registration_timeout))
  registration_succeeded=false
  while (( SECONDS < registration_deadline )); do
    if ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./register-participant.sh .env >register-participant.log 2>&1"; then
      registration_succeeded=true
      break
    fi
    registration_log="$(ssh "$NODE" "tail -100 /srv/dai/deploy/$NODE/register-participant.log" 2>/dev/null || true)"
    # The registration endpoint is served through the currently active chain
    # participant. It can legitimately return a transient 5xx response while
    # that edge is restarting or changing PoC phase. Retry only that class;
    # malformed identities, authentication errors and other deterministic
    # failures must surface immediately instead of becoming a 30-minute wait.
    if grep -Eq '(^|[^0-9])5[0-9]{2}([^0-9]|$)|Service Temporarily Unavailable' <<<"$registration_log"; then
      printf 'WAIT  %s registration endpoint returned transient 5xx\n' "$NODE"
      sleep 5
      continue
    fi
    printf '%s\n' "$registration_log" >&2
    die "$NODE registration command failed without a retryable server response"
  done
  [[ "$registration_succeeded" == true ]] || {
    ssh "$NODE" "tail -100 /srv/dai/deploy/$NODE/register-participant.log" >&2 || true
    die "$NODE registration endpoint did not accept the participant within ${registration_timeout}s"
  }
  "$ROOT/03-join/wait-registered.sh" "https://$GENESIS_PUBLIC_HOST" "$ADDRESS" "$registration_timeout" || {
    ssh "$NODE" "tail -100 /srv/dai/deploy/$NODE/register-participant.log" >&2 || true
    exit 1
  }
fi
if [[ "$already_active" == true ]]; then
  printf 'READY %s is already ACTIVE; skip duplicate funding and ML permission transactions\n' "$NODE"
else
  step "Claim bounded public DevNet funding for $NODE"
  "$ROOT/scripts/claim-devnet-faucet.sh" "$ADDRESS"
  step "Grant ML operational permissions for $NODE"
  "$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITY" "$INVENTORY"
  step "Wait until $NODE is ACTIVE"
  "$ROOT/03-join/wait-active.sh" "https://$GENESIS_PUBLIC_HOST" "$ADDRESS"
fi
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
if [[ -n "$ML_HOST" ]]; then
  step "Attach network GPU $ML_HOST to $NODE"
  "$ROOT/scripts/phase-ml-attach.sh" "$NODE"
fi
printf '\n%s joined successfully.\n' "$NODE"
