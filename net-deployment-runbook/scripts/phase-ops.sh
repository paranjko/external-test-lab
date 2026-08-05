#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
COMPONENT="${1:-}"
[[ "$COMPONENT" =~ ^(gateway|monitoring|site|meter|explorer|edge)$ ]] || die 'expected: ops gateway, ops monitoring, ops site, ops meter, ops explorer, or ops edge'
if [[ "$COMPONENT" == meter ]]; then
  exec "$ROOT/scripts/phase-meter.sh"
fi
if [[ "$COMPONENT" == explorer ]]; then
  exec "$ROOT/scripts/phase-explorer.sh"
fi
if [[ "$COMPONENT" == gateway ]]; then
  GDC_GATEWAY_VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
  [[ "$GDC_GATEWAY_VERSION" =~ ^v[34]$ ]] || die 'GDC_GATEWAY_VERSION must be v3 or v4'
  export GDC_GATEWAY_VERSION
fi
OPS_RENDER="$GENERATED/ops"
GATEWAY_ENV="$OPS_RENDER/gateway.env"
REMOTE="/tmp/gdc-ops-$$"

step 'Render monitoring and public status configuration'
"$ROOT/04-ops/render-ops.sh" --inventory "$INVENTORY" --accounts-dir "$ACCOUNTS" --secrets-dir "$SECRETS" --output-dir "$OPS_RENDER" >/dev/null

GATEWAY_OPTION=''
CADDY_START_COMMAND='docker compose up -d --force-recreate caddy'
if [[ "$COMPONENT" == edge ]]; then
  step 'Install the public node4 edge configuration without changing chain state'
  node=gdc-node4
  edge_env="$GENERATED/edge/$node.env"
  mkdir -p "$(dirname "$edge_env")"
  "$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$node" --output "$edge_env" >/dev/null
  ssh "$node" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a "$ROOT/04-ops/edge-node/" "$node:$REMOTE/edge/"
  scp -q "$edge_env" "$node:$REMOTE/edge.env"
  ssh -T "$node" "sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; rm -rf '$REMOTE'; cd /srv/dai/edge && docker compose --profile public-edge up -d --force-recreate public-grafana caddy >/srv/dai/edge/start-edge.log 2>&1"
  step 'Verify the status site is served through node4 TLS'
  curl -fsS "https://$SITE_HOST/" | grep -q 'EXTERNAL TEST LAB' || die 'public node4 edge does not serve the current homepage contract'
  "$ROOT/scripts/verify-public-grafana.sh"
  printf 'PASS public node4 edge serves %s\n' "$SITE_HOST"
  exit 0
fi
case "$COMPONENT" in
  gateway)
    step "Provide the pinned $GDC_GATEWAY_VERSION gateway image on gdc-node0"
    "$ROOT/scripts/build-gateway-image.sh" >"$STATE/gateway-image-$GDC_GATEWAY_VERSION.txt"
    step 'Create DevShard escrow and gateway credentials'
    "$ROOT/04-ops/create-gateway.sh" "$INVENTORY" "$SECRETS" "$GATEWAY_ENV"
    gateway_default_max_tokens="$(awk -F= '$1 == "GATEWAY_DEFAULT_MAX_TOKENS" { print $2 }' "$GATEWAY_ENV")"
    [[ "$gateway_default_max_tokens" =~ ^[1-9][0-9]*$ ]] || die 'gateway default max tokens is missing or invalid'
    gateway_rotation_escrow_amount="$(awk -F= '$1 == "DEVSHARD_ROTATION_ESCROW_AMOUNT" { print $2 }' "$GATEWAY_ENV")"
    [[ "$gateway_rotation_escrow_amount" =~ ^[1-9][0-9]*$ ]] || die 'gateway rotation escrow amount is missing or invalid'
    GATEWAY_OPTION="--gateway-env '$REMOTE/rendered/gateway.env'"
    # `gateway.env` is both container input and Compose interpolation input:
    # it selects the protocol-isolated state volume before the service is
    # created. `env_file:` alone is too late for `${...}` in compose.yaml.
    START_COMMAND='docker compose --env-file .env --env-file gateway.env up -d devshard-gateway'
    ENDPOINT="http://$NODE0_PUBLIC_HOST:18080"
    ;;
  monitoring)
    # Prometheus and Grafana mount generated provisioning/configuration files.
    # `up -d` alone does not reload an already-running container, leaving a
    # newly rendered dashboard/scrape config silently stale.
    START_COMMAND='docker compose up -d --force-recreate prometheus alertmanager blackbox grafana'
    ENDPOINT="http://$NODE0_PUBLIC_HOST:3000"
    ;;
  site)
    START_COMMAND=true
    # The status-site files are mounted/read by the existing proxy. Recreating
    # Caddy for a static-site refresh creates transient 503s for open browser
    # tabs that poll the node and validator endpoints every 15 seconds.
    CADDY_START_COMMAND='docker compose up -d caddy'
    ENDPOINT="http://$NODE0_PUBLIC_HOST:8081"
    ;;
esac

step "Install $COMPONENT operations component on gdc-node0"
ssh gdc-node0 "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/04-ops/" "gdc-node0:$REMOTE/04-ops/"
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
    curl -fsS -X POST http://127.0.0.1:18080/v1/admin/devshards \
      -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
      -H "Content-Type: application/json" --data "$payload" \
      | jq -e --arg id "$DEVSHARD_ESCROW_ID" ".id == \$id and .active == true" >/dev/null'
  step 'Configure authenticated access for the governed model'
  # A new per-protocol gateway state volume intentionally starts without
  # persisted model access settings.  The runtime defaults to admin_only,
  # which would make an apparently ACTIVE public gateway reject every client
  # key.  Keep the route authenticated rather than making inference public.
  # These settings persist in gateway.db.  Apply the environment-derived
  # default explicitly so an existing state volume cannot retain an unsafe
  # value from a previous deployment.
  ssh gdc-node0 "set -Eeuo pipefail; set -a; . /srv/dai/ops/gateway.env; set +a; curl -fsS -X POST http://127.0.0.1:18080/v1/admin/settings -H \"Authorization: Bearer \$DEVSHARD_ADMIN_API_KEY\" -H 'Content-Type: application/json' -d '{\"default_request_max_tokens\":$gateway_default_max_tokens,\"model_limits\":[{\"model_id\":\"$MODEL_ID\",\"access_mode\":\"api_key\"}],\"escrow_rotation\":{\"enabled\":true,\"settlement_enabled\":false,\"pre_poc_blocks\":300,\"models\":[{\"model_id\":\"$MODEL_ID\",\"temp_count\":1,\"target_count\":1,\"amount\":$gateway_rotation_escrow_amount,\"private_key_env\":\"DEVSHARD_PRIVATE_KEY\"}]}}' | jq -e '.default_request_max_tokens == $gateway_default_max_tokens and (.model_limits[] | select(.model_id == \"$MODEL_ID\" and .access_mode == \"api_key\")) and .escrow_rotation.enabled == true and .escrow_rotation.models[0].amount == $gateway_rotation_escrow_amount' >/dev/null"
  step 'Verify gateway runtime, client authentication, and public route'
  gateway_ready=false
  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if ssh gdc-node0 'set -Eeuo pipefail; set -a; . /srv/dai/ops/gateway.env; set +a; curl -fsS http://127.0.0.1:18080/v1/status | jq -e ".phase == \"active\" and .requests_blocked == false and (.escrow_id | tostring | test(\"^[1-9][0-9]*$\"))" >/dev/null'; then
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
  unauth_status="$(curl -sk -o /dev/null -w '%{http_code}' "https://$API_HOST/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"health"}]}')"
  [[ "$unauth_status" == 401 ]] || die "unauthenticated gateway request returned $unauth_status, expected 401"
  curl -fsS "https://$API_HOST/v1/status" -H "Authorization: Bearer $client_key" | jq -e '.phase == "active" and .requests_blocked == false and (.escrow_id | tostring | test("^[1-9][0-9]*$"))' >/dev/null
  # Gateway status is a local runtime view.  Prove that its selected escrow
  # still exists in committed chain state before reporting the gateway ready.
  active_escrow="$(curl -fsS "https://$API_HOST/v1/status" -H "Authorization: Bearer $client_key" | jq -er '.escrow_id | tostring | select(test("^[1-9][0-9]*$"))')"
  "$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$active_escrow" \
    --node "https://${NODE4_PUBLIC_HOST}/chain-rpc/" --chain-id "$CHAIN_ID" --output json \
    | jq -e --arg id "$active_escrow" '.found == true and (.escrow.id | tostring) == $id' >/dev/null \
    || die "gateway escrow $active_escrow is absent from committed chain state"
  ssh gdc-node0 "set -Eeuo pipefail; curl -fsS http://127.0.0.1:18080/v1/status -H 'Authorization: Bearer $admin_key' >/dev/null"
  "$ROOT/04-ops/test-inference.sh" "https://$API_HOST" "$client_key" >/dev/null
  printf 'PASS gateway status and authentication checks\n'
fi

if [[ "$COMPONENT" == monitoring ]]; then
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
