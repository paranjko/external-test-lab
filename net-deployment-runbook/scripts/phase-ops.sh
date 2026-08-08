#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
COMPONENT="${1:-}"
EDGE_NODE="${2:-}"
[[ "$COMPONENT" =~ ^(gateway|monitoring|site|explorer|edge|edge-node)$ ]] || die 'expected: ops gateway, ops monitoring, ops site, ops explorer, ops edge, or ops edge-node gdc-nodeN'
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
REMOTE="/tmp/gdc-ops-$$"
SITE_INDEX_RENDER=''

step 'Render monitoring and public status configuration'
"$ROOT/04-ops/render-ops.sh" --inventory "$INVENTORY" --accounts-dir "$ACCOUNTS" --secrets-dir "$SECRETS" --output-dir "$OPS_RENDER" >/dev/null

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
    ssh -T "$node" "sudo '$edge_remote/edge/install-edge.sh' '$edge_remote/edge.env'; rm -rf '$edge_remote'; cd /srv/dai/edge && docker compose --profile public-edge up -d --force-recreate public-grafana >/srv/dai/edge/start-public-grafana.log 2>&1"
  fi
}

reconcile_monitoring_agents() {
  local node ml_host agent_env agent_remote gpu_flag
  local -a nodes

  mapfile -t nodes < <(configured_nodes)
  ((${#nodes[@]} > 0)) || die 'no joined nodes are available for monitoring-agent reconciliation'
  mkdir -p "$GENERATED/agents"

  for node in "${nodes[@]}"; do
    ssh_ready "$node" || die "$node is joined but unreachable; monitoring inventory cannot be reconciled"
    agent_env="$GENERATED/agents/$node.env"
    agent_remote="${REMOTE}-agent-$node"
    gpu_flag=''
    [[ -z "$(node_ml_host "$node" || true)" ]] && gpu_flag='--gpu'
    "$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$node" --output "$agent_env" >/dev/null
    ssh "$node" "rm -rf '$agent_remote' && mkdir -p '$agent_remote'"
    rsync -a "$ROOT/04-ops/agent/" "$node:$agent_remote/agent/"
    scp -q "$agent_env" "$node:$agent_remote/agent.env"
    ssh -T "$node" "sudo '$agent_remote/agent/install-agent.sh' '$agent_remote/agent.env' $gpu_flag; rm -rf '$agent_remote'"
    start_stack "$node" /srv/dai/monitoring-agent
    printf 'READY monitoring inventory collector on %s\n' "$node"
  done

  for node in "${nodes[@]}"; do
    ml_host="$(node_ml_host "$node" || true)"
    [[ -n "$ml_host" && -e "$STATE/ml-attached/$node" ]] || continue
    ssh_ready "$ml_host" || die "$ml_host is attached to $node but unreachable; monitoring inventory cannot be reconciled"
    agent_env="$GENERATED/agents/$ml_host.env"
    agent_remote="${REMOTE}-agent-$ml_host"
    "$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$ml_host" --output "$agent_env" >/dev/null
    ssh "$ml_host" "rm -rf '$agent_remote' && mkdir -p '$agent_remote'"
    rsync -a "$ROOT/04-ops/agent/" "$ml_host:$agent_remote/agent/"
    scp -q "$agent_env" "$ml_host:$agent_remote/agent.env"
    ssh -T "$ml_host" "sudo '$agent_remote/agent/install-agent.sh' '$agent_remote/agent.env' --gpu; rm -rf '$agent_remote'"
    start_stack "$ml_host" /srv/dai/monitoring-agent
    printf 'READY monitoring inventory collector on %s\n' "$ml_host"
  done
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
  gateway)
    step "Provide the pinned $GDC_GATEWAY_VERSION gateway image on $GATEWAY_NODE"
    "$ROOT/scripts/build-gateway-image.sh" >"$STATE/gateway-image-$GDC_GATEWAY_VERSION.txt"
    step 'Ensure the gateway has a durable test-token reserve for escrow rotation'
    gateway_min_spendable="${GDC_GATEWAY_MIN_SPENDABLE_NGONKA:-100000000000}"
    [[ "$gateway_min_spendable" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_MIN_SPENDABLE_NGONKA must be positive'
    "$ROOT/04-ops/ensure-gateway-reserve.sh" \
      "$INVENTORY" "$ACCOUNTS/gdc-gateway-cold.json" "$gateway_min_spendable"
    step 'Create DevShard escrow and gateway credentials'
    # Re-running `ops gateway` switches or verifies a protocol runtime; it is
    # not authority to mint another escrow.  Reuse the previously committed
    # escrow unless an operator explicitly supplies GDC_ESCROW_ID or the
    # existing one has become invalid (which create-gateway validates).
    if [[ -z "${GDC_ESCROW_ID:-}" && -s "$GATEWAY_ENV" ]]; then
      previous_escrow="$(awk -F= '$1 == "DEVSHARD_ESCROW_ID" { print $2; exit }' "$GATEWAY_ENV")"
      [[ "$previous_escrow" =~ ^[1-9][0-9]*$ ]] && export GDC_ESCROW_ID="$previous_escrow"
    fi
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
    START_COMMAND='docker compose --env-file .env --env-file gateway.env up -d devshard-gateway'
    ENDPOINT="$GDC_GATEWAY_PUBLIC_URL"
    ;;
  monitoring)
    step 'Reconcile runtime software inventory collectors on joined hosts'
    reconcile_monitoring_agents
    # Prometheus and Grafana mount generated provisioning/configuration files.
    # `up -d` alone does not reload an already-running container, leaving a
    # newly rendered dashboard/scrape config silently stale.
    START_COMMAND='docker compose up -d --force-recreate prometheus alertmanager blackbox grafana'
    ENDPOINT="http://$(node_public_host "$GATEWAY_NODE"):3000"
    ;;
  site)
    SITE_INDEX_RENDER="$OPS_RENDER/site/index.html"
    "$ROOT/scripts/render-site-revision.sh" "$ROOT/04-ops/site/index.html" "$SITE_INDEX_RENDER"
    START_COMMAND=true
    # Static files and Caddyfile are bind-mounted. Reload the existing process
    # so cache policy changes apply without recreating Caddy and causing a
    # transient 503 for browser tabs polling the live status endpoints.
    CADDY_START_COMMAND='docker compose up -d caddy && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile'
    ENDPOINT="http://$(node_public_host "$GATEWAY_NODE"):8081"
    ;;
esac

step "Install $COMPONENT operations component on $GATEWAY_NODE"
ssh "$GATEWAY_NODE" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/04-ops/" "$GATEWAY_NODE:$REMOTE/04-ops/"
[[ -z "$SITE_INDEX_RENDER" ]] || rsync -a "$SITE_INDEX_RENDER" "$GATEWAY_NODE:$REMOTE/04-ops/site/index.html"
rsync -a "$OPS_RENDER/" "$GATEWAY_NODE:$REMOTE/rendered/"
printf 'WAIT  start %s operations component\n' "$COMPONENT"
if ssh -T "$GATEWAY_NODE" "sudo '$REMOTE/04-ops/install-ops.sh' --component '$COMPONENT' --render-dir '$REMOTE/rendered' $GATEWAY_OPTION; rm -rf '$REMOTE'; { cd /srv/dai/edge && docker compose down; cd /srv/dai/ops && $START_COMMAND && $CADDY_START_COMMAND; } >/srv/dai/ops/start-$COMPONENT.log 2>&1"; then
  printf 'READY %s endpoint %s\n' "$COMPONENT" "$ENDPOINT"
else
  ssh "$GATEWAY_NODE" "tail -100 /srv/dai/ops/start-$COMPONENT.log" >&2 || true
  exit 1
fi

if [[ "$COMPONENT" == gateway ]]; then
  step 'Resolve the active committed escrow after reconciliation'
  # The external reconciler can replace an escrow between rendering gateway.env
  # and this post-start registration step.  Do not try to re-register a pruned
  # ID: take the active runtime the gateway has already bound, persist that ID
  # in both rendered and deployed configuration, then continue idempotently.
  gateway_active_escrow="$(ssh -T "$GATEWAY_NODE" 'set -Eeuo pipefail
    set -a; . /srv/dai/ops/gateway.env; set +a
    curl -fsS http://127.0.0.1:18080/v1/admin/devshards \
      -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
      | jq -er "[.devshards[] | select(.active == true and (.runtime.phase // \"\") == \"active\" and (.runtime.requests_blocked // false) == false) | .id | tostring] | first // empty"')"
  [[ "$gateway_active_escrow" =~ ^[1-9][0-9]*$ ]] || die 'gateway has no active committed runtime after startup'
  sed -i -E "s/^DEVSHARD_ESCROW_ID=.*/DEVSHARD_ESCROW_ID=$gateway_active_escrow/" "$GATEWAY_ENV"
  ssh -T "$GATEWAY_NODE" "sudo sed -i -E 's/^DEVSHARD_ESCROW_ID=.*/DEVSHARD_ESCROW_ID=$gateway_active_escrow/' /srv/dai/ops/gateway.env"
  step 'Register the newly created escrow in persistent gateway topology'
  # gateway.db deliberately owns runtime topology across restarts.  Replacing
  # gateway.env alone would leave a retired escrow resident and silently make
  # the new on-chain escrow unroutable.  Register the current escrow through
  # the loopback-only admin API, retaining inactive historical entries for
  # settlement/debug evidence.  The request body and response never leave the
  # remote host because they contain the gateway private key.
  ssh "$GATEWAY_NODE" 'set -Eeuo pipefail
    set -a; . /srv/dai/ops/gateway.env; set +a
    payload="$(jq -cn --arg id "$DEVSHARD_ESCROW_ID" --arg key "$DEVSHARD_PRIVATE_KEY" --arg model "$DEVSHARD_MODEL" --arg route "$DEVSHARD_ROUTE_PREFIX" "{id:\$id,private_key:\$key,model:\$model,route_prefix:\$route}")"
    body="$(mktemp)"; trap "rm -f \"$body\"" EXIT
    status="$(curl -sS -o "$body" -w "%{http_code}" -X POST http://127.0.0.1:18080/v1/admin/devshards \
      -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
      -H "Content-Type: application/json" --data "$payload")"
    if [[ "$status" == 200 || "$status" == 201 ]]; then
      jq -e --arg id "$DEVSHARD_ESCROW_ID" "(.id | tostring) == \$id and .active == true" "$body" >/dev/null
    elif [[ "$status" == 409 ]]; then
      curl -fsS http://127.0.0.1:18080/v1/admin/devshards -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
        | jq -e --arg id "$DEVSHARD_ESCROW_ID" ".devshards[] | select((.id | tostring) == \$id)" >/dev/null
    else
      cat "$body" >&2; exit 1
  fi'
  step 'Ensure configured escrow is active in gateway routing table'
  ssh "$GATEWAY_NODE" 'set -Eeuo pipefail
    set -a; . /srv/dai/ops/gateway.env; set +a
    devshards_json="$(curl -fsS http://127.0.0.1:18080/v1/admin/devshards -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY")"
    escrow_state="$(jq -c --arg id "$DEVSHARD_ESCROW_ID" ".devshards[] | select((.id | tostring) == \$id)" <<<"$devshards_json")"
    [[ -n "$escrow_state" ]] || { echo "registered escrow $DEVSHARD_ESCROW_ID is missing from gateway topology" >&2; exit 1; }
    [[ "$(jq -er ".active // false" <<<"$escrow_state")" == true ]] || \
      curl -fsS -X POST "http://127.0.0.1:18080/v1/admin/devshards/$DEVSHARD_ESCROW_ID/activate" \
        -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" | jq -e --arg id "$DEVSHARD_ESCROW_ID" "(.id | tostring) == \$id and .active == true" >/dev/null'
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
  # The operator Grafana on node0 remains authenticated. Public monitoring is
  # the independently provisioned anonymous-Viewer runtime on the public edge; sharing
  # an operator dashboard token would couple its database and session boundary
  # to the public origin, which the lifecycle explicitly forbids.
  "$ROOT/scripts/verify-public-grafana.sh"
  printf 'PASS separate public Grafana dashboard %s\n' "$GRAFANA_HOST"
fi

if [[ "$COMPONENT" == site ]]; then
  step 'Capture public homepage contract evidence'
  "$ROOT/scripts/verify-public-homepage.sh"
fi
