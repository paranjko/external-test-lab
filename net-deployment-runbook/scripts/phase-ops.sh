#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
COMPONENT="${1:-}"
EDGE_NODE="${2:-}"
[[ "$COMPONENT" =~ ^(gateway|faucet|monitoring|site|explorer|edge|edge-node)$ ]] || die 'expected: ops gateway, ops faucet, ops monitoring, ops site, ops explorer, ops edge, or ops edge-node ssh-alias'
if [[ "$COMPONENT" == edge-node ]]; then
  topology_contains_node "$EDGE_NODE" || die "ops edge-node requires an alias from GDC_NODE_ALIASES: $EDGE_NODE"
fi
if [[ "$COMPONENT" == explorer ]]; then
  exec "$ROOT/scripts/phase-explorer.sh"
fi
if [[ "$COMPONENT" == gateway ]]; then
  GDC_GATEWAY_VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
  [[ "$GDC_GATEWAY_VERSION" =~ ^v[34]$ ]] || die 'GDC_GATEWAY_VERSION must be v3 or v4'
  supported_protocols="${DEVSHARD_SUPPORTED_PROTOCOLS:-$DEVSHARD_PROTOCOL_VERSION}"
  case " $supported_protocols " in
    *" $GDC_GATEWAY_VERSION "*) ;;
    *) die "DevShard $GDC_GATEWAY_VERSION is not supported by the pinned upstream artifact; supported: $supported_protocols" ;;
  esac
  GDC_GATEWAY_PUBLIC_URL="${GDC_GATEWAY_PUBLIC_URL:-https://$API_HOST}"
  GDC_GATEWAY_PUBLIC_URL="${GDC_GATEWAY_PUBLIC_URL%/}"
  export GDC_GATEWAY_VERSION
fi
OPS_RENDER="$GENERATED/ops"
GATEWAY_ENV="$OPS_RENDER/gateway.env"
FAUCET_ENV="$OPS_RENDER/faucet.env"
REMOTE="/tmp/gdc-ops-$$"
SITE_INDEX_RENDER=''
FAUCET_OPTION=''
FAUCET_SIGNER_HOME=''

# Only the authenticated Grafana service needs an OPS credential.  Genesis
# calls this phase for the public faucet, which has no Grafana authority.
if [[ "$COMPONENT" == monitoring ]]; then
  if [[ -z "${GDC_GRAFANA_ADMIN_PASSWORD:-}" && -r "$SECRETS/grafana.admin" ]]; then
    GDC_GRAFANA_ADMIN_PASSWORD="$(<"$SECRETS/grafana.admin")"
    export GDC_GRAFANA_ADMIN_PASSWORD
  fi
  [[ -n "${GDC_GRAFANA_ADMIN_PASSWORD:-}" ]] || die 'ops monitoring requires GDC_GRAFANA_ADMIN_PASSWORD owned by OPS'
fi

step 'Render monitoring and public status configuration'
"$ROOT/04-ops/render-ops.sh" --inventory "$INVENTORY" --output-dir "$OPS_RENDER" >/dev/null

reconcile_public_grafana() {
  local start_caddy="${1:-false}" node="$PUBLIC_EDGE_NODE" edge_env edge_remote
  edge_env="$GENERATED/edge/$node.env"
  edge_remote="${REMOTE}-edge"
  mkdir -p "$(dirname "$edge_env")"
  "$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$node" --output "$edge_env" >/dev/null
  ssh "$node" "rm -rf '$edge_remote' && mkdir -p '$edge_remote'"
  rsync -a "$ROOT/04-ops/edge-node/" "$node:$edge_remote/edge/"
  scp -q "$edge_env" "$node:$edge_remote/edge.env"
  if [[ "$start_caddy" == true ]]; then
    ssh -T "$node" "sudo '$edge_remote/edge/install-edge.sh' '$edge_remote/edge.env'; rm -rf '$edge_remote'; cd /srv/dai/edge && docker compose --profile public-edge up -d --force-recreate public-grafana caddy >/srv/dai/edge/start-edge.log 2>&1"
  else
    # Monitoring changes both Grafana provisioning and its least-privilege
    # Prometheus/consumer routes. Recreate Caddy with the same rendered edge
    # contract; otherwise the file on disk changes while the running container
    # keeps serving the old bind-mounted inode.
    ssh -T "$node" "sudo '$edge_remote/edge/install-edge.sh' '$edge_remote/edge.env'; rm -rf '$edge_remote'; cd /srv/dai/edge && docker compose --profile public-edge up -d --force-recreate public-grafana caddy >/srv/dai/edge/start-public-grafana.log 2>&1"
  fi
}

GATEWAY_OPTION=''
CADDY_START_COMMAND='docker compose up -d --force-recreate caddy'
if [[ "$COMPONENT" == edge ]]; then
  step 'Install the public edge configuration without changing chain state'
  reconcile_public_grafana true
  step 'Verify the status site is served through the public edge TLS'
  site_ready=false
  for _ in $(seq 1 30); do
    if curl -fsS "https://$SITE_HOST/" | grep -q 'EXTERNAL TEST LAB'; then
      site_ready=true
      break
    fi
    printf 'WAIT  public status site after edge restart\n'
    sleep 1
  done
  [[ "$site_ready" == true ]] || die 'public edge does not serve the current homepage contract'
  "$ROOT/scripts/verify-public-grafana.sh"
  printf 'PASS public edge %s serves %s\n' "$PUBLIC_EDGE_NODE" "$SITE_HOST"
  exit 0
fi
if [[ "$COMPONENT" == edge-node ]]; then
  step "Install the participant edge configuration on $EDGE_NODE"
  edge_env="$GENERATED/edge/$EDGE_NODE.env"
  edge_remote="${REMOTE}-edge-$EDGE_NODE"
  mkdir -p "$(dirname "$edge_env")"
  "$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$EDGE_NODE" --output "$edge_env" >/dev/null
  ssh "$EDGE_NODE" "rm -rf '$edge_remote' && mkdir -p '$edge_remote'"
  rsync -a "$ROOT/04-ops/edge-node/" "$EDGE_NODE:$edge_remote/edge/"
  scp -q "$edge_env" "$EDGE_NODE:$edge_remote/edge.env"
  ssh -T "$EDGE_NODE" "sudo '$edge_remote/edge/install-edge.sh' '$edge_remote/edge.env'; rm -rf '$edge_remote'; cd /srv/dai/edge && docker compose up -d --force-recreate caddy"
  printf 'PASS participant edge installed on %s\n' "$EDGE_NODE"
  exit 0
fi
case "$COMPONENT" in
  faucet)
    [[ -s "$ACCOUNTS/gdc-faucet-cold.json" ]] || die 'faucet account is absent; create a fresh Genesis first'
    [[ -s "$GENESIS/genesis.json" ]] || die 'faucet Genesis is absent; create a fresh Genesis first'
    faucet_genesis_sha256="$(genesis_sha256 "$GENESIS/genesis.json")"
    [[ "$faucet_genesis_sha256" =~ ^[0-9a-f]{64}$ ]] || die 'faucet Genesis SHA-256 is invalid'
    faucet_amount="${GDC_FAUCET_CLAIM_NGONKA:-100000000000}"
    faucet_initial="${GDC_FAUCET_INITIAL_NGONKA:-5000000000000}"
    [[ "$faucet_amount" =~ ^[1-9][0-9]*$ ]] || die 'GDC_FAUCET_CLAIM_NGONKA must be positive'
    [[ "$faucet_initial" =~ ^[1-9][0-9]*$ ]] || die 'GDC_FAUCET_INITIAL_NGONKA must be positive'
    (( faucet_amount <= faucet_initial )) || die 'GDC_FAUCET_CLAIM_NGONKA must not exceed GDC_FAUCET_INITIAL_NGONKA'
    FAUCET_SIGNER_HOME="$("$ROOT/scripts/prepare-faucet-signer.sh")"
    write_env "$FAUCET_ENV" \
      "FAUCET_CHAIN_ID=$CHAIN_ID" \
      "FAUCET_GENESIS_SHA256=$faucet_genesis_sha256" \
      'FAUCET_RPC_URL=http://127.0.0.1:26657' \
      'FAUCET_KEY_NAME=gdc-faucet-cold' \
      "FAUCET_KEYRING_PASSWORD=$(<"$SECRETS/operator.keyring")" \
      "FAUCET_AMOUNT_NGONKA=$faucet_amount" \
      "FAUCET_MAX_CLAIMS_PER_IP=${GDC_FAUCET_MAX_CLAIMS_PER_IP:-3}" \
      "FAUCET_WINDOW_SECONDS=${GDC_FAUCET_WINDOW_SECONDS:-86400}"
    FAUCET_OPTION="--faucet-env '$REMOTE/rendered/faucet.env'"
    START_COMMAND='docker compose up -d --build --force-recreate faucet'
    ENDPOINT="https://${GENESIS_PUBLIC_HOST}/faucet/health"
    ;;
  gateway)
    step "Provide the pinned $GDC_GATEWAY_VERSION gateway image on $GATEWAY_NODE"
    "$ROOT/scripts/build-gateway-image.sh" >"$STATE/gateway-image-$GDC_GATEWAY_VERSION.txt"
    step 'Reconcile the gateway creator reserve before escrow reuse or replacement'
    gateway_min_spendable="${GDC_GATEWAY_MIN_SPENDABLE_NGONKA:-100000000000}"
    [[ "$gateway_min_spendable" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_MIN_SPENDABLE_NGONKA must be positive'
    gateway_reserve_temp_count="${GDC_GATEWAY_ROTATION_TEMP_COUNT:-2}"
    gateway_reserve_target_count="${GDC_GATEWAY_ROTATION_TARGET_COUNT:-2}"
    [[ "$gateway_reserve_temp_count" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_ROTATION_TEMP_COUNT must be positive'
    [[ "$gateway_reserve_target_count" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_ROTATION_TARGET_COUNT must be positive'
    gateway_rotation_slots=$((gateway_reserve_temp_count + gateway_reserve_target_count + 1))
    gateway_live_min_amount="$("$ROOT/scripts/inferenced.sh" query inference params \
      --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" --chain-id "$CHAIN_ID" --output json \
      | jq -er '(.params // .).devshard_escrow_params.min_amount')"
    gateway_rotation_amount="${GDC_GATEWAY_ESCROW_AMOUNT_NGONKA:-$gateway_live_min_amount}"
    [[ "$gateway_rotation_amount" =~ ^[1-9][0-9]*$ ]] || die 'gateway rotation escrow amount must be positive'
    gateway_reserve_headroom=$((gateway_rotation_amount * gateway_rotation_slots))
    (( gateway_reserve_headroom >= gateway_rotation_amount )) || die 'gateway reserve headroom overflows shell integer range'
    "$ROOT/04-ops/ensure-gateway-reserve.sh" \
      "$INVENTORY" "$ACCOUNTS/gdc-gateway-cold.json" "$gateway_min_spendable" "$gateway_reserve_headroom"
    # Re-running `ops gateway` switches or verifies a protocol runtime; it is
    # not authority to mint another escrow.  The escrow reconciler can rotate
    # the configured ID while this command is not running, so the deployed
    # gateway runtime is authoritative.  Consult it before the rendered file:
    # the latter is merely a snapshot and may point at a pruned escrow.
    if [[ -z "${GDC_ESCROW_ID:-}" ]]; then
      active_gateway_escrow="$(ssh -T "$GATEWAY_NODE" 'set -Eeuo pipefail
        [[ -r /srv/dai/ops/gateway.env ]] || exit 0
        set -a; . /srv/dai/ops/gateway.env; set +a
        curl -fsS http://127.0.0.1:18080/v1/admin/devshards \
          -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
          | jq -er "[.devshards[] | select(.active == true and (.runtime.phase // \"\") == \"active\" and (.runtime.requests_blocked // false) == false) | .id | tostring] | first // empty"' 2>/dev/null || true)"
      if [[ "$active_gateway_escrow" =~ ^[1-9][0-9]*$ ]]; then
        export GDC_ESCROW_ID="$active_gateway_escrow"
        printf 'READY reuse active gateway escrow %s from deployed runtime\n' "$GDC_ESCROW_ID"
      elif [[ -s "$GATEWAY_ENV" ]]; then
        previous_escrow="$(awk -F= '$1 == "DEVSHARD_ESCROW_ID" { print $2; exit }' "$GATEWAY_ENV")"
        if [[ "$previous_escrow" =~ ^[1-9][0-9]*$ ]]; then
          previous_state="$("$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$previous_escrow" \
            --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" --chain-id "$CHAIN_ID" --output json 2>/dev/null || true)"
          if jq -e '.found == true and (.escrow.settled // false) == false' <<<"$previous_state" >/dev/null 2>&1; then
            export GDC_ESCROW_ID="$previous_escrow"
          else
            printf 'READY discard retired gateway escrow %s from rendered configuration\n' "$previous_escrow"
          fi
        fi
      fi
    fi
    if [[ -z "${GDC_ESCROW_ID:-}" ]]; then
      step 'Create a replacement gateway escrow from the reconciled reserve'
    else
      step "Reuse committed gateway escrow $GDC_ESCROW_ID after reserve reconciliation"
    fi
    step 'Create DevShard escrow and gateway credentials'
    "$ROOT/04-ops/create-gateway.sh" "$INVENTORY" "$SECRETS" "$GATEWAY_ENV"
    gateway_default_max_tokens="$(awk -F= '$1 == "GATEWAY_DEFAULT_MAX_TOKENS" { print $2 }' "$GATEWAY_ENV")"
    [[ "$gateway_default_max_tokens" =~ ^[1-9][0-9]*$ ]] || die 'gateway default max tokens is missing or invalid'
    gateway_rotation_escrow_amount="$(awk -F= '$1 == "DEVSHARD_ROTATION_ESCROW_AMOUNT" { print $2 }' "$GATEWAY_ENV")"
    [[ "$gateway_rotation_escrow_amount" =~ ^[1-9][0-9]*$ ]] || die 'gateway rotation escrow amount is missing or invalid'
    gateway_max_concurrent_requests="$(awk -F= '$1 == "GATEWAY_MAX_CONCURRENT_REQUESTS" { print $2 }' "$GATEWAY_ENV")"
    gateway_max_concurrent_per_weight="${GDC_GATEWAY_MAX_CONCURRENT_PER_10000_WEIGHT:-1000000000}"
    gateway_max_input_tokens="$(awk -F= '$1 == "GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT" { print $2 }' "$GATEWAY_ENV")"
    gateway_participant_request_burst="$(awk -F= '$1 == "GATEWAY_PARTICIPANT_REQUEST_BURST" { print $2 }' "$GATEWAY_ENV")"
    gateway_participant_recovery_per_minute="$(awk -F= '$1 == "GATEWAY_PARTICIPANT_RECOVERY_PER_MINUTE" { print $2 }' "$GATEWAY_ENV")"
    gateway_pre_poc_blocks="${GDC_GATEWAY_PRE_POC_BLOCKS:-5}"
    gateway_rotation_temp_count="${GDC_GATEWAY_ROTATION_TEMP_COUNT:-2}"
    gateway_rotation_target_count="${GDC_GATEWAY_ROTATION_TARGET_COUNT:-2}"
    gateway_rotation_enabled="${GDC_GATEWAY_ESCROW_ROTATION_ENABLED:-true}"
    gateway_rotation_settlement_enabled="${GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED:-true}"
    [[ "$gateway_max_concurrent_requests" =~ ^[0-9]+$ ]] || die 'gateway max concurrent requests is missing or invalid'
    [[ "$gateway_max_concurrent_per_weight" =~ ^[0-9]+$ ]] || die 'GDC_GATEWAY_MAX_CONCURRENT_PER_10000_WEIGHT must be non-negative'
    [[ "$gateway_max_input_tokens" =~ ^[0-9]+$ ]] || die 'gateway max input tokens in flight is missing or invalid'
    [[ "$gateway_participant_request_burst" =~ ^[1-9][0-9]*$ ]] || die 'gateway participant request burst is missing or invalid'
    [[ "$gateway_participant_recovery_per_minute" =~ ^[1-9][0-9]*$ ]] || die 'gateway participant recovery per minute is missing or invalid'
    [[ "$gateway_pre_poc_blocks" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_PRE_POC_BLOCKS must be positive'
    [[ "$gateway_rotation_temp_count" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_ROTATION_TEMP_COUNT must be positive'
    [[ "$gateway_rotation_target_count" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_ROTATION_TARGET_COUNT must be positive'
    [[ "$gateway_rotation_enabled" =~ ^(true|false)$ ]] || die 'GDC_GATEWAY_ESCROW_ROTATION_ENABLED must be true or false'
    [[ "$gateway_rotation_settlement_enabled" =~ ^(true|false)$ ]] || die 'GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED must be true or false'
    GATEWAY_OPTION="--gateway-env '$REMOTE/rendered/gateway.env'"
    # `gateway.env` is both container input and Compose interpolation input:
    # it selects the protocol-isolated state volume before the service is
    # created. `env_file:` alone is too late for `${...}` in compose.yaml.
    # The gateway immediately probes every participant endpoint on its first
    # inference.  Bring up the public TLS ingress first and prove it accepts
    # the participant health route; otherwise that first probe can race Caddy
    # startup, fail with connection refused, and leave the gateway limiter
    # occupied until its long execution timeout.
    # `API_HOST` is the separately published gateway API domain.  It can be
    # served by another edge during a reset and is therefore not evidence that
    # this gateway node's Caddy is ready.  The runtime self-probe targets the
    # gateway participant host, so wait for that exact ingress instead.
    gateway_ingress_host="$(node_public_host "$GATEWAY_NODE")"
    START_COMMAND="docker compose up -d --force-recreate caddy; deadline=\$((SECONDS + 120)); while (( SECONDS < deadline )); do curl -fsS --connect-timeout 3 --max-time 10 'https://$gateway_ingress_host/health' >/dev/null && break; sleep 2; done; curl -fsS --connect-timeout 3 --max-time 10 'https://$gateway_ingress_host/health' >/dev/null; docker compose --env-file .env --env-file gateway.env up -d devshard-gateway"
    CADDY_START_COMMAND=true
    ENDPOINT="$GDC_GATEWAY_PUBLIC_URL"
    ;;
  monitoring)
    step 'Deploy monitoring that observes published node endpoints'
    # Prometheus and Grafana mount generated provisioning/configuration files.
    # `up -d` alone does not reload an already-running container, leaving a
    # newly rendered dashboard/scrape config silently stale.
    START_COMMAND='docker compose up -d --force-recreate prometheus alertmanager blackbox grafana'
    ENDPOINT="http://$(node_public_host "$GATEWAY_NODE"):3000"
    ;;
  site)
    SITE_INDEX_RENDER="$OPS_RENDER/site/index.html"
    SITE_ASSETS_RENDER="$OPS_RENDER/site/assets"
    "$ROOT/scripts/render-site-revision.sh" "$ROOT/04-ops/site/index.html" "$SITE_INDEX_RENDER"
    mkdir -p "$SITE_ASSETS_RENDER"
    rsync -a --exclude src/ "$ROOT/04-ops/site/" "$SITE_ASSETS_RENDER/"
    "$ROOT/scripts/build-site-js.sh" --output "$SITE_ASSETS_RENDER"
    cp "$SITE_INDEX_RENDER" "$SITE_ASSETS_RENDER/index.html"
    START_COMMAND=true
    # install-ops replaces Caddyfile atomically. A bind mount of a single file
    # keeps the old inode inside a running container, so `caddy reload` would
    # reload stale routes and silently omit /status/<participant> proxies.
    # Recreate only Caddy to bind the rendered file; the gateway and chain
    # services remain running.
    CADDY_START_COMMAND='docker compose up -d --force-recreate caddy'
    ENDPOINT="http://$(node_public_host "$GATEWAY_NODE"):8081"
    ;;
esac

step "Install $COMPONENT operations component on $GATEWAY_NODE"
ssh "$GATEWAY_NODE" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/04-ops/" "$GATEWAY_NODE:$REMOTE/04-ops/"
[[ -z "${SITE_ASSETS_RENDER:-}" ]] || rsync -a --delete "$SITE_ASSETS_RENDER/" "$GATEWAY_NODE:$REMOTE/04-ops/site/"
rsync -a "$OPS_RENDER/" "$GATEWAY_NODE:$REMOTE/rendered/"
if [[ -n "$FAUCET_SIGNER_HOME" ]]; then
  rsync -a "$FAUCET_SIGNER_HOME/" "$GATEWAY_NODE:$REMOTE/faucet-signer/"
fi
printf 'WAIT  start %s operations component\n' "$COMPONENT"
if ssh -T "$GATEWAY_NODE" "set -Eeuo pipefail
  if [[ -d '$REMOTE/faucet-signer' ]]; then
    sudo install -d -m 0700 /srv/dai/gonka-devnet-faucet/operator-home /srv/dai/gonka-devnet-faucet/data
    sudo cp -a '$REMOTE/faucet-signer/.' /srv/dai/gonka-devnet-faucet/operator-home/
    sudo chmod -R go-rwx /srv/dai/gonka-devnet-faucet
  fi
  sudo '$REMOTE/04-ops/install-ops.sh' --component '$COMPONENT' --render-dir '$REMOTE/rendered' $GATEWAY_OPTION $FAUCET_OPTION
  rm -rf '$REMOTE'
  {
    cd /srv/dai/edge && docker compose down
    cd /srv/dai/ops && $START_COMMAND && $CADDY_START_COMMAND
  } >/srv/dai/ops/start-$COMPONENT.log 2>&1"; then
  printf 'READY %s endpoint %s\n' "$COMPONENT" "$ENDPOINT"
else
  ssh "$GATEWAY_NODE" "tail -100 /srv/dai/ops/start-$COMPONENT.log" >&2 || true
  exit 1
fi

if [[ "$COMPONENT" == faucet ]]; then
  step 'Verify the public DevNet faucet route'
  curl -fsS --connect-timeout 5 --max-time 15 "$ENDPOINT" | jq -e '.status == "ok"' >/dev/null
  printf 'PASS public DevNet faucet: %s\n' "$ENDPOINT"
fi

if [[ "$COMPONENT" == gateway ]]; then
  step 'Resolve the active committed escrow after reconciliation'
  # Rotation may retire the rendered escrow while this command is running.
  # Observe the gateway's current choice and chain state together; never POST
  # activate for a stale ID or fight the reconciler's routing decision.
  gateway_active_escrow=''
  gateway_active_timeout="${GDC_GATEWAY_ACTIVE_ESCROW_TIMEOUT_SECONDS:-180}"
  [[ "$gateway_active_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_ACTIVE_ESCROW_TIMEOUT_SECONDS must be positive'
  gateway_active_deadline=$((SECONDS + gateway_active_timeout))
  while (( SECONDS < gateway_active_deadline )); do
    candidate="$(ssh -T "$GATEWAY_NODE" 'set -Eeuo pipefail
      set -a; . /srv/dai/ops/gateway.env; set +a
      curl -fsS http://127.0.0.1:18080/v1/admin/devshards \
        -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
        | jq -er "[.devshards[] | select(.active == true and (.runtime.phase // \"\") == \"active\" and (.runtime.requests_blocked // false) == false) | .id | tostring] | first // empty"' 2>/dev/null || true)"
    if [[ "$candidate" =~ ^[1-9][0-9]*$ ]]; then
      candidate_state="$("$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$candidate" \
        --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" --chain-id "$CHAIN_ID" --output json 2>/dev/null || true)"
      if jq -e '.found == true and (.escrow.settled // false) == false' <<<"$candidate_state" >/dev/null 2>&1; then
        gateway_active_escrow="$candidate"
        break
      fi
    fi
    sleep 2
  done
  [[ "$gateway_active_escrow" =~ ^[1-9][0-9]*$ ]] || die 'gateway has no active committed runtime after reconciliation'
  sed -i -E "s/^DEVSHARD_ESCROW_ID=.*/DEVSHARD_ESCROW_ID=$gateway_active_escrow/" "$GATEWAY_ENV"
  ssh -T "$GATEWAY_NODE" "sudo sed -i -E 's/^DEVSHARD_ESCROW_ID=.*/DEVSHARD_ESCROW_ID=$gateway_active_escrow/' /srv/dai/ops/gateway.env"
  printf 'READY gateway reconciler selected committed escrow %s\n' "$gateway_active_escrow"
  step 'Configure authenticated access for the governed model'
  # A new per-protocol gateway state volume intentionally starts without
  # persisted model access settings.  The runtime defaults to admin_only,
  # which would make an apparently ACTIVE public gateway reject every client
  # key.  Keep the route authenticated rather than making inference public.
  # These settings persist in gateway.db.  Apply the environment-derived
  # default explicitly so an existing state volume cannot retain an unsafe
  # value from a previous deployment.
  ssh "$GATEWAY_NODE" "set -Eeuo pipefail; set -a; . /srv/dai/ops/gateway.env; set +a; curl -fsS -X POST http://127.0.0.1:18080/v1/admin/settings -H \"Authorization: Bearer \$DEVSHARD_ADMIN_API_KEY\" -H 'Content-Type: application/json' -d '{\"default_request_max_tokens\":$gateway_default_max_tokens,\"max_concurrent_requests\":$gateway_max_concurrent_requests,\"max_concurrent_requests_per_10000_weight\":$gateway_max_concurrent_per_weight,\"poc_max_concurrent_requests_per_10000_weight\":$gateway_max_concurrent_per_weight,\"max_input_tokens_in_flight\":$gateway_max_input_tokens,\"participant_throttle\":{\"request_burst\":$gateway_participant_request_burst,\"recovery_per_minute\":$gateway_participant_recovery_per_minute},\"model_limits\":[{\"model_id\":\"$MODEL_ID\",\"max_concurrent_requests\":$gateway_max_concurrent_requests,\"max_input_tokens_in_flight\":$gateway_max_input_tokens,\"access_mode\":\"api_key\"}],\"escrow_rotation\":{\"enabled\":$gateway_rotation_enabled,\"settlement_enabled\":$gateway_rotation_settlement_enabled,\"pre_poc_blocks\":$gateway_pre_poc_blocks,\"models\":[{\"model_id\":\"$MODEL_ID\",\"temp_count\":$gateway_rotation_temp_count,\"target_count\":$gateway_rotation_target_count,\"amount\":$gateway_rotation_escrow_amount,\"private_key_env\":\"DEVSHARD_PRIVATE_KEY\"}]}}' | jq -e '.default_request_max_tokens == $gateway_default_max_tokens and .max_concurrent_requests == $gateway_max_concurrent_requests and .max_concurrent_requests_per_10000_weight == $gateway_max_concurrent_per_weight and .poc_max_concurrent_requests_per_10000_weight == $gateway_max_concurrent_per_weight and .max_input_tokens_in_flight == $gateway_max_input_tokens and .participant_throttle.request_burst == $gateway_participant_request_burst and .participant_throttle.recovery_per_minute == $gateway_participant_recovery_per_minute and (.model_limits[] | select(.model_id == \"$MODEL_ID\" and .max_concurrent_requests == $gateway_max_concurrent_requests and .max_input_tokens_in_flight == $gateway_max_input_tokens and .access_mode == \"api_key\")) and .escrow_rotation.enabled == $gateway_rotation_enabled and .escrow_rotation.settlement_enabled == $gateway_rotation_settlement_enabled and .escrow_rotation.pre_poc_blocks == $gateway_pre_poc_blocks and .escrow_rotation.models[0].temp_count == $gateway_rotation_temp_count and .escrow_rotation.models[0].target_count == $gateway_rotation_target_count and .escrow_rotation.models[0].amount == $gateway_rotation_escrow_amount' >/dev/null"
  step 'Verify gateway runtime, client authentication, and public route'
  gateway_ready=false
    gateway_ready_timeout="${GDC_GATEWAY_READY_TIMEOUT_SECONDS:-600}"
    [[ "$gateway_ready_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_READY_TIMEOUT_SECONDS must be positive'
    deadline=$((SECONDS + gateway_ready_timeout))
  while (( SECONDS < deadline )); do
    if ssh "$GATEWAY_NODE" 'set -Eeuo pipefail
      set -a; . /srv/dai/ops/gateway.env; set +a
      curl -fsS http://127.0.0.1:18080/v1/status \
        | jq -e "(.devshards // [.]) | any((.active // true) == true and .phase == \"active\" and .requests_blocked == false and .chain_phase == \"Inference\")" >/dev/null
      curl -fsS http://127.0.0.1:18080/v1/admin/devshards -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
        | jq -e --arg model "$DEVSHARD_MODEL" ".limiter.models[\$model] as \$limits | ((.settings.max_concurrent_requests == 0 and .settings.max_concurrent_requests_per_10000_weight <= 0) or \$limits.effective_max_concurrent_requests > 0)" >/dev/null
      height="$(curl -fsS http://127.0.0.1:26657/status | jq -er ".result.sync_info.latest_block_height | tonumber")"
      read -r epoch_length poc_duration poc_exchange_duration validation_delay validation_duration validators_delay < <(
        curl -fsS http://127.0.0.1:1317/productscience/inference/inference/params \
          | jq -r ".params.epoch_params | [.epoch_length,.poc_stage_duration,.poc_exchange_duration,.poc_validation_delay,.poc_validation_duration,.set_new_validators_delay] | map(tonumber) | @tsv"
      )
      position=$((height % epoch_length))
      safe_start=$((poc_duration + poc_exchange_duration + validation_delay + validation_duration + validators_delay + 1))
      safe_end=$((epoch_length - 10))
      (( position >= safe_start && position <= safe_end ))'; then
      gateway_ready=true
      break
    fi
    printf 'WAIT  gateway runtime active\n'
    sleep 3
  done
  [[ "$gateway_ready" == true ]] || die 'gateway did not become ACTIVE before timeout'
  ssh "$GATEWAY_NODE" 'test "$(stat -c %a /srv/dai/ops/gateway.env)" = 600'
  admin_key="$(<"$SECRETS/gateway.admin-key")"
  client_key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
  unauth_status="$(curl -sk -o /dev/null -w '%{http_code}' "$GDC_GATEWAY_PUBLIC_URL/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"health"}]}')"
  [[ "$unauth_status" == 401 ]] || die "unauthenticated gateway request returned $unauth_status, expected 401"
  curl -fsS "$GDC_GATEWAY_PUBLIC_URL/v1/status" -H "Authorization: Bearer $client_key" \
    | jq -e '
        ([.devshards[]?
          | select(.active == true and .phase == "active" and (.requests_blocked // false) == false)
          | .id]
         + [if .phase == "active" and (.requests_blocked // false) == false then .escrow_id? else empty end])
        | any(. != null and (tostring | test("^[1-9][0-9]*$")))
      ' >/dev/null
  # Gateway status is a local runtime view.  Prove that its selected escrow
  # still exists in committed chain state before reporting the gateway ready.
  active_escrow="$(curl -fsS "$GDC_GATEWAY_PUBLIC_URL/v1/status" -H "Authorization: Bearer $client_key" \
    | jq -er '
        ([.devshards[]?
          | select(.active == true and .phase == "active" and (.requests_blocked // false) == false)
          | .id]
         + [if .phase == "active" and (.requests_blocked // false) == false then .escrow_id? else empty end])
        | map(select(. != null and (tostring | test("^[1-9][0-9]*$"))))
        | first | tostring
      ')"
  chain_rpc="${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}"
  "$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$active_escrow" \
    --node "$chain_rpc" --chain-id "$CHAIN_ID" --output json \
    | jq -e --arg id "$active_escrow" '.found == true and (.escrow.id | tostring) == $id' >/dev/null \
    || die "gateway escrow $active_escrow is absent from committed chain state"
  ssh "$GATEWAY_NODE" "set -Eeuo pipefail; curl -fsS http://127.0.0.1:18080/v1/status -H 'Authorization: Bearer $admin_key' >/dev/null"
  "$ROOT/04-ops/test-inference.sh" "$GDC_GATEWAY_PUBLIC_URL" "$client_key" >/dev/null
  printf 'PASS gateway status and authentication checks\n'
fi

if [[ "$COMPONENT" == monitoring ]]; then
  step 'Reconcile the anonymous public dashboards with the monitoring source'
  reconcile_public_grafana false
  step 'Verify the separate public Grafana runtime'
  # The operator Grafana on the configured public edge remains authenticated. Public monitoring is
  # the independently provisioned anonymous-Viewer runtime on the public edge; sharing
  # an operator dashboard token would couple its database and session boundary
  # to the public origin, which the lifecycle explicitly forbids.
  "$ROOT/scripts/verify-public-grafana.sh"
  printf 'PASS separate public Grafana dashboard %s\n' "$GRAFANA_HOST"
fi

if [[ "$COMPONENT" == site ]]; then
  # Caddy can accept TLS before the just-recreated site upstream is ready.
  # Wait on the actual public contract rather than treating that short 502
  # window as a failed reset or a false public-state observation.
  site_deadline=$((SECONDS + ${GDC_SITE_PUBLIC_READY_WAIT_SECONDS:-120}))
  site_ready=false
  while (( SECONDS < site_deadline )); do
    if curl -fsS --connect-timeout 5 --max-time 15 "https://$SITE_HOST/" | grep -q 'EXTERNAL TEST LAB'; then
      site_ready=true
      break
    fi
    printf 'WAIT  public homepage upstream after site restart\n'
    sleep 2
  done
  [[ "$site_ready" == true ]] || die 'public homepage upstream did not become ready after site restart'
  step 'Capture public homepage contract evidence'
  verify_deadline=$((SECONDS + ${GDC_SITE_PUBLIC_VERIFY_WAIT_SECONDS:-120}))
  verified=false
  while (( SECONDS < verify_deadline )); do
    if "$ROOT/scripts/verify-public-homepage.sh"; then
      verified=true
      break
    fi
    printf 'WAIT  complete public homepage contract after site restart\n'
    sleep 3
  done
  [[ "$verified" == true ]] || die 'public homepage contract did not become stable after site restart'
fi
