#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
COMPONENT="${1:-}"
[[ "$COMPONENT" =~ ^(gateway|monitoring|site|explorer|edge)$ ]] || die 'expected: ops gateway, ops monitoring, ops site, ops explorer, or ops edge'
if [[ "$COMPONENT" == explorer ]]; then
  exec "$ROOT/scripts/phase-explorer.sh"
fi
if [[ "$COMPONENT" == gateway ]]; then
  GDC_GATEWAY_VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
  [[ "$GDC_GATEWAY_VERSION" =~ ^v[34]$ ]] || die 'GDC_GATEWAY_VERSION must be v3 or v4'
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
  local start_caddy="${1:-false}" node=gdc-node4 edge_env edge_remote
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
  local index node agent_env agent_remote gpu_flag
  local -a indexes

  mapfile -t indexes < <(configured_node_indexes)
  ((${#indexes[@]} > 0)) || die 'no joined nodes are available for monitoring-agent reconciliation'
  mkdir -p "$GENERATED/agents"

  for index in "${indexes[@]}"; do
    node="gdc-node$index"
    ssh_ready "$node" || die "$node is joined but unreachable; monitoring inventory cannot be reconciled"
    agent_env="$GENERATED/agents/$node.env"
    agent_remote="${REMOTE}-agent-$node"
    gpu_flag=''
    [[ "$index" != 4 ]] && gpu_flag='--gpu'
    "$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$node" --output "$agent_env" >/dev/null
    ssh "$node" "rm -rf '$agent_remote' && mkdir -p '$agent_remote'"
    rsync -a "$ROOT/04-ops/agent/" "$node:$agent_remote/agent/"
    scp -q "$agent_env" "$node:$agent_remote/agent.env"
    ssh -T "$node" "sudo '$agent_remote/agent/install-agent.sh' '$agent_remote/agent.env' $gpu_flag; rm -rf '$agent_remote'"
    start_stack "$node" /srv/dai/monitoring-agent
    printf 'READY monitoring inventory collector on %s\n' "$node"
  done

  if [[ " ${indexes[*]} " == *' 4 '* ]]; then
    node=gdc-node4-ml
    ssh_ready "$node" || die "$node is required by joined gdc-node4 but unreachable; monitoring inventory cannot be reconciled"
    agent_env="$GENERATED/agents/$node.env"
    agent_remote="${REMOTE}-agent-$node"
    "$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$node" --output "$agent_env" >/dev/null
    ssh "$node" "rm -rf '$agent_remote' && mkdir -p '$agent_remote'"
    rsync -a "$ROOT/04-ops/agent/" "$node:$agent_remote/agent/"
    scp -q "$agent_env" "$node:$agent_remote/agent.env"
    ssh -T "$node" "sudo '$agent_remote/agent/install-agent.sh' '$agent_remote/agent.env' --gpu; rm -rf '$agent_remote'"
    start_stack "$node" /srv/dai/monitoring-agent
    printf 'READY monitoring inventory collector on %s\n' "$node"
  fi
}

GATEWAY_OPTION=''
CADDY_START_COMMAND='docker compose up -d --force-recreate caddy'
if [[ "$COMPONENT" == edge ]]; then
  step 'Install the public node4 edge configuration without changing chain state'
  reconcile_public_grafana true
  step 'Verify the status site is served through node4 TLS'
  site_ready=false
  for _ in $(seq 1 30); do
    if curl -fsS "https://$SITE_HOST/" | grep -q 'EXTERNAL TEST LAB'; then
      site_ready=true
      break
    fi
    printf 'WAIT  public status site after edge restart\n'
    sleep 1
  done
  [[ "$site_ready" == true ]] || die 'public node4 edge does not serve the current homepage contract'
  "$ROOT/scripts/verify-public-grafana.sh"
  printf 'PASS public node4 edge serves %s\n' "$SITE_HOST"
  exit 0
fi
case "$COMPONENT" in
  gateway)
    step "Provide the pinned $GDC_GATEWAY_VERSION gateway image on gdc-node0"
    "$ROOT/scripts/build-gateway-image.sh" >"$STATE/gateway-image-$GDC_GATEWAY_VERSION.txt"
    step 'Ensure the gateway has a durable test-token reserve for escrow rotation'
    gateway_min_spendable="${GDC_GATEWAY_MIN_SPENDABLE_NGONKA:-100000000000}"
    [[ "$gateway_min_spendable" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_MIN_SPENDABLE_NGONKA must be positive'
    "$ROOT/04-ops/ensure-gateway-reserve.sh" \
      "$INVENTORY" "$ACCOUNTS/gdc-gateway-cold.json" "$gateway_min_spendable"
    step 'Create DevShard escrow and gateway credentials'
    "$ROOT/04-ops/create-gateway.sh" "$INVENTORY" "$SECRETS" "$GATEWAY_ENV"
    gateway_default_max_tokens="$(awk -F= '$1 == "GATEWAY_DEFAULT_MAX_TOKENS" { print $2 }' "$GATEWAY_ENV")"
    [[ "$gateway_default_max_tokens" =~ ^[1-9][0-9]*$ ]] || die 'gateway default max tokens is missing or invalid'
    gateway_rotation_escrow_amount="$(awk -F= '$1 == "DEVSHARD_ROTATION_ESCROW_AMOUNT" { print $2 }' "$GATEWAY_ENV")"
    [[ "$gateway_rotation_escrow_amount" =~ ^[1-9][0-9]*$ ]] || die 'gateway rotation escrow amount is missing or invalid'
    gateway_max_concurrent_requests="$(awk -F= '$1 == "GATEWAY_MAX_CONCURRENT_REQUESTS" { print $2 }' "$GATEWAY_ENV")"
    gateway_max_concurrent_per_weight="${GDC_GATEWAY_MAX_CONCURRENT_PER_10000_WEIGHT:-1000000000}"
    gateway_max_input_tokens="$(awk -F= '$1 == "GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT" { print $2 }' "$GATEWAY_ENV")"
    gateway_pre_poc_blocks="${GDC_GATEWAY_PRE_POC_BLOCKS:-5}"
    gateway_rotation_temp_count="${GDC_GATEWAY_ROTATION_TEMP_COUNT:-2}"
    gateway_rotation_target_count="${GDC_GATEWAY_ROTATION_TARGET_COUNT:-2}"
    gateway_rotation_enabled="${GDC_GATEWAY_ESCROW_ROTATION_ENABLED:-true}"
    gateway_rotation_settlement_enabled="${GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED:-true}"
    [[ "$gateway_max_concurrent_requests" =~ ^[0-9]+$ ]] || die 'gateway max concurrent requests is missing or invalid'
    [[ "$gateway_max_concurrent_per_weight" =~ ^[0-9]+$ ]] || die 'GDC_GATEWAY_MAX_CONCURRENT_PER_10000_WEIGHT must be non-negative'
    [[ "$gateway_max_input_tokens" =~ ^[0-9]+$ ]] || die 'gateway max input tokens in flight is missing or invalid'
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
    ENDPOINT="http://$NODE0_PUBLIC_HOST:3000"
    ;;
  site)
    SITE_INDEX_RENDER="$OPS_RENDER/site/index.html"
    "$ROOT/scripts/render-site-revision.sh" "$ROOT/04-ops/site/index.html" "$SITE_INDEX_RENDER"
    START_COMMAND=true
    # Static files and Caddyfile are bind-mounted. Reload the existing process
    # so cache policy changes apply without recreating Caddy and causing a
    # transient 503 for browser tabs polling the live status endpoints.
    CADDY_START_COMMAND='docker compose up -d caddy && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile'
    ENDPOINT="http://$NODE0_PUBLIC_HOST:8081"
    ;;
esac

step "Install $COMPONENT operations component on gdc-node0"
ssh gdc-node0 "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/04-ops/" "gdc-node0:$REMOTE/04-ops/"
[[ -z "$SITE_INDEX_RENDER" ]] || rsync -a "$SITE_INDEX_RENDER" "gdc-node0:$REMOTE/04-ops/site/index.html"
rsync -a "$OPS_RENDER/" "gdc-node0:$REMOTE/rendered/"
printf 'WAIT  start %s operations component\n' "$COMPONENT"
if ssh -T gdc-node0 "sudo '$REMOTE/04-ops/install-ops.sh' --component '$COMPONENT' --render-dir '$REMOTE/rendered' $GATEWAY_OPTION; rm -rf '$REMOTE'; { cd /srv/dai/edge && docker compose down; cd /srv/dai/ops && $START_COMMAND && $CADDY_START_COMMAND; } >/srv/dai/ops/start-$COMPONENT.log 2>&1"; then
  printf 'READY %s endpoint %s\n' "$COMPONENT" "$ENDPOINT"
else
  ssh gdc-node0 "tail -100 /srv/dai/ops/start-$COMPONENT.log" >&2 || true
  exit 1
fi

if [[ "$COMPONENT" == gateway ]]; then
  step 'Register the newly created escrow in persistent gateway topology'
  # gateway.db deliberately owns runtime topology across restarts.  Replacing
  # gateway.env alone would leave a retired escrow resident and silently make
  # the new on-chain escrow unroutable.  Register the current escrow through
  # the loopback-only admin API, retaining inactive historical entries for
  # settlement/debug evidence.  The request body and response never leave the
  # remote host because they contain the gateway private key.
  ssh gdc-node0 'set -Eeuo pipefail
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
  ssh gdc-node0 'set -Eeuo pipefail
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
  ssh gdc-node0 "set -Eeuo pipefail; set -a; . /srv/dai/ops/gateway.env; set +a; curl -fsS -X POST http://127.0.0.1:18080/v1/admin/settings -H \"Authorization: Bearer \$DEVSHARD_ADMIN_API_KEY\" -H 'Content-Type: application/json' -d '{\"default_request_max_tokens\":$gateway_default_max_tokens,\"max_concurrent_requests\":$gateway_max_concurrent_requests,\"max_concurrent_requests_per_10000_weight\":$gateway_max_concurrent_per_weight,\"poc_max_concurrent_requests_per_10000_weight\":$gateway_max_concurrent_per_weight,\"max_input_tokens_in_flight\":$gateway_max_input_tokens,\"model_limits\":[{\"model_id\":\"$MODEL_ID\",\"max_concurrent_requests\":$gateway_max_concurrent_requests,\"max_input_tokens_in_flight\":$gateway_max_input_tokens,\"access_mode\":\"api_key\"}],\"escrow_rotation\":{\"enabled\":$gateway_rotation_enabled,\"settlement_enabled\":$gateway_rotation_settlement_enabled,\"pre_poc_blocks\":$gateway_pre_poc_blocks,\"models\":[{\"model_id\":\"$MODEL_ID\",\"temp_count\":$gateway_rotation_temp_count,\"target_count\":$gateway_rotation_target_count,\"amount\":$gateway_rotation_escrow_amount,\"private_key_env\":\"DEVSHARD_PRIVATE_KEY\"}]}}' | jq -e '.default_request_max_tokens == $gateway_default_max_tokens and .max_concurrent_requests == $gateway_max_concurrent_requests and .max_concurrent_requests_per_10000_weight == $gateway_max_concurrent_per_weight and .poc_max_concurrent_requests_per_10000_weight == $gateway_max_concurrent_per_weight and .max_input_tokens_in_flight == $gateway_max_input_tokens and (.model_limits[] | select(.model_id == \"$MODEL_ID\" and .max_concurrent_requests == $gateway_max_concurrent_requests and .max_input_tokens_in_flight == $gateway_max_input_tokens and .access_mode == \"api_key\")) and .escrow_rotation.enabled == $gateway_rotation_enabled and .escrow_rotation.settlement_enabled == $gateway_rotation_settlement_enabled and .escrow_rotation.pre_poc_blocks == $gateway_pre_poc_blocks and .escrow_rotation.models[0].temp_count == $gateway_rotation_temp_count and .escrow_rotation.models[0].target_count == $gateway_rotation_target_count and .escrow_rotation.models[0].amount == $gateway_rotation_escrow_amount' >/dev/null"
  step 'Verify gateway runtime, client authentication, and public route'
  gateway_ready=false
  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if ssh gdc-node0 'set -Eeuo pipefail
      set -a; . /srv/dai/ops/gateway.env; set +a
      curl -fsS http://127.0.0.1:18080/v1/status \
        | jq -e "(.devshards // [.]) | any((.active // true) == true and .phase == \"active\" and .requests_blocked == false and .chain_phase == \"Inference\")" >/dev/null
      curl -fsS http://127.0.0.1:18080/v1/admin/devshards -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
        | jq -e --arg model "$DEVSHARD_MODEL" ".limiter.models[\$model] as \$limits | ((.settings.max_concurrent_requests == 0 and .settings.max_concurrent_requests_per_10000_weight <= 0) or \$limits.effective_max_concurrent_requests > 0)" >/dev/null
      height="$(curl -fsS http://127.0.0.1:26657/status | jq -er ".result.sync_info.latest_block_height | tonumber")"
      read -r epoch_length poc_duration validation_delay validation_duration validators_delay < <(
        curl -fsS http://127.0.0.1:1317/productscience/inference/inference/params \
          | jq -r ".params.epoch_params | [.epoch_length,.poc_stage_duration,.poc_validation_delay,.poc_validation_duration,.set_new_validators_delay] | map(tonumber) | @tsv"
      )
      position=$((height % epoch_length))
      safe_start=$((poc_duration + validation_delay + validation_duration + validators_delay + 1))
      safe_end=$((epoch_length - 10))
      (( position >= safe_start && position <= safe_end ))'; then
      gateway_ready=true
      break
    fi
    printf 'WAIT  gateway runtime active\n'
    sleep 3
  done
  [[ "$gateway_ready" == true ]] || die 'gateway did not become ACTIVE before timeout'
  ssh gdc-node0 'test "$(stat -c %a /srv/dai/ops/gateway.env)" = 600'
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
  chain_rpc="${GDC_CHAIN_RPC_URL:-https://${NODE4_PUBLIC_HOST}/chain-rpc/}"
  "$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$active_escrow" \
    --node "$chain_rpc" --chain-id "$CHAIN_ID" --output json \
    | jq -e --arg id "$active_escrow" '.found == true and (.escrow.id | tostring) == $id' >/dev/null \
    || die "gateway escrow $active_escrow is absent from committed chain state"
  ssh gdc-node0 "set -Eeuo pipefail; curl -fsS http://127.0.0.1:18080/v1/status -H 'Authorization: Bearer $admin_key' >/dev/null"
  "$ROOT/04-ops/test-inference.sh" "$GDC_GATEWAY_PUBLIC_URL" "$client_key" >/dev/null
  printf 'PASS gateway status and authentication checks\n'
fi

if [[ "$COMPONENT" == monitoring ]]; then
  step 'Reconcile the anonymous node4 dashboards with the monitoring source'
  reconcile_public_grafana false
  step 'Verify the separate node4 public Grafana runtime'
  # The operator Grafana on node0 remains authenticated. Public monitoring is
  # the independently provisioned anonymous-Viewer runtime on node4; sharing
  # an operator dashboard token would couple its database and session boundary
  # to the public origin, which the lifecycle explicitly forbids.
  "$ROOT/scripts/verify-public-grafana.sh"
  printf 'PASS separate public Grafana dashboard %s\n' "$GRAFANA_HOST"
fi

if [[ "$COMPONENT" == site ]]; then
  step 'Capture public homepage contract evidence'
  "$ROOT/scripts/verify-public-homepage.sh"
fi
