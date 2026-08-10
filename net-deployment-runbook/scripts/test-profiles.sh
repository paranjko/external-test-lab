#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
source "$ROOT/scripts/lib.sh"
"$ROOT/scripts/test-topology-inventory.sh"

(
  unset SITE_HOST GRAFANA_HOST GDC_SITE_HOST GDC_GRAFANA_HOST
  load_public_observability_hosts
  [[ "$SITE_HOST" == gonka-dev.net ]]
  [[ "$GRAFANA_HOST" == grafana.gonka-dev.net ]]

  export GDC_SITE_HOST=status.example.test
  export GDC_GRAFANA_HOST=monitoring.example.test
  load_public_observability_hosts
  [[ "$SITE_HOST" == status.example.test ]]
  [[ "$GRAFANA_HOST" == monitoring.example.test ]]
)
grep -Fq 'load_public_observability_hosts' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'GDC_RESET_PUBLIC_OBSERVABILITY_WAIT_SECONDS:-120' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'site_ready=true' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'grafana_ready=true' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'status.json.tmp' "$ROOT/scripts/qualify-ml-remote.sh"
grep -Fq '2>>"$WORK/control.log"' "$ROOT/scripts/qualify-ml-remote.sh"
grep -Fq 'phase-bootstrap-access.sh' "$ROOT/gdc.sh"
grep -Fq 'GDC_CHAIN_RPC_URL' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'GDC_GATEWAY_PUBLIC_URL="https://${API_HOST}"' "$ROOT/scripts/phase-bootstrap-access.sh"
if grep -Fq 'deploy-telegram-bot.sh' "$ROOT/scripts/phase-bootstrap-access.sh"; then
  echo 'bootstrap access must not depend on the temporary Telegram issuer' >&2
  exit 1
fi
grep -Fq 'GDC_RUN_ID' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'runs/$GDC_RUN_ID-homepage/*' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'GDC_GOVERNANCE_AUTO_VOTE=true' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'ensure-genesis-validation-weight.sh' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'GDC_SITE_PUBLIC_READY_WAIT_SECONDS' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'public homepage upstream after site restart' "$ROOT/scripts/phase-ops.sh"
grep -Fq '[[ ! -d "$DEST/prometheus/prometheus.yml" ]] || rm -rf' "$ROOT/04-ops/install-ops.sh"
grep -Fq 'GDC_SITE_PUBLIC_VERIFY_WAIT_SECONDS' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'complete public homepage contract after site restart' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'empty participant set' "$ROOT/scripts/verify-public-homepage.sh"
grep -Fq 'AMOUNT="${AMOUNT:-$MIN_AMOUNT}"' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'AMOUNT <= SPENDABLE_AMOUNT' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'same GDC_HOME state root' "$ROOT/04-ops/create-gateway.sh"
grep -Fq -- '--from gdc-gateway-cold' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'keys export gdc-gateway-cold' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'GDC_GATEWAY_ESCROW_ROTATION_ENABLED=true' "$ROOT/.env.example"
grep -Fq 'GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=true' "$ROOT/.env.example"
grep -Fq 'GDC_GATEWAY_ESCROW_ROTATION_ENABLED:-true' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED:-true' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GDC_GATEWAY_MAX_CONCURRENT_REQUESTS=0' "$ROOT/.env.example"
grep -Fq 'GDC_GATEWAY_MAX_CONCURRENT_PER_10000_WEIGHT=1000000000' "$ROOT/.env.example"
grep -Fq 'GDC_GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT=0' "$ROOT/.env.example"
grep -Fq 'GDC_GATEWAY_ROTATION_TEMP_COUNT=2' "$ROOT/.env.example"
grep -Fq 'GDC_GATEWAY_ROTATION_TARGET_COUNT=2' "$ROOT/.env.example"
grep -Fq 'GDC_GATEWAY_MIN_SPENDABLE_NGONKA=100000000000' "$ROOT/.env.example"
grep -Fq 'Reuse committed gateway escrow $GDC_ESCROW_ID after reserve reconciliation' "$ROOT/scripts/phase-ops.sh"
grep -Fq '\"temp_count\":$gateway_rotation_temp_count' "$ROOT/scripts/phase-ops.sh"
grep -Fq '\"target_count\":$gateway_rotation_target_count' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS:-45' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'DEVSHARD_CAPACITY_AWARE_LIMITS=off' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED=true' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'gateway immediately probes every participant endpoint' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway_ingress_host="$(node_public_host "$GATEWAY_NODE")"' "$ROOT/scripts/phase-ops.sh"
grep -Fq "https://\$gateway_ingress_host/health" "$ROOT/scripts/phase-ops.sh"
grep -Fq '/usr/local/lib/gonka-devnet/gateway-escrow-reconciler.sh' "$ROOT/04-ops/install-ops.sh"
grep -Fq 'ExecStart=/usr/local/lib/gonka-devnet/gateway-escrow-reconciler.sh' "$ROOT/04-ops/gdc-gateway-escrow-reconciler.service"
grep -Fq 'User=@GDC_SERVICE_USER@' "$ROOT/04-ops/gdc-gateway-escrow-reconciler.service"
grep -Fq 'User=@GDC_SERVICE_USER@' "$ROOT/04-ops/gdc-gateway-health-probe.service"
! grep -Fq 'User=root' "$ROOT/04-ops/gdc-gateway-escrow-reconciler.service"
! grep -Fq 'User=root' "$ROOT/04-ops/gdc-gateway-health-probe.service"
[[ "$(grep -Ec '^[[:space:]]*verify_registration$' "$ROOT/scripts/phase-bridge-observer.sh")" == 1 ]]
grep -Fq 'docker compose up -d --force-recreate caddy' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'waiting_for_versiond_session' "$ROOT/04-ops/gateway-escrow-reconciler.sh"
grep -Fq 'productscience/inference/inference/devshard_escrow' "$ROOT/04-ops/gateway-escrow-reconciler.sh"
grep -Fq '.settings.max_concurrent_requests == 0 and .settings.max_concurrent_requests_per_10000_weight <= 0' "$ROOT/scripts/phase-ops.sh"
if grep -Fq 'GDC_GATEWAY_ESCROW_AMOUNT_NGONKA:-10000000000' "$ROOT/04-ops/create-gateway.sh"; then
  echo 'gateway escrow must not default to the full Genesis allocation' >&2
  exit 1
fi
grep -Fq 'poc_validation_delay = $poc_validation_delay' "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'GDC_POC_EXCHANGE_DURATION:-8' "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq '.epoch_params.poc_slot_allocation = {value:"5", exponent:-1}' "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'systemctl restart gonka-firewall.service' "$ROOT/00-host-prep/prepare-host.sh"
grep -Fq 'ML callback ingress source is stale' "$ROOT/00-host-prep/verify-host.sh"
grep -Fq 'ensure-gateway-reserve.sh' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'load_project' "$ROOT/scripts/fetch-upstream.sh"
grep -Fq 'source "$ROOT/scripts/lib.sh"' "$ROOT/scripts/fetch-upstream.sh"
grep -Fq 'for node in "${GDC_NODES[@]}"' "$ROOT/scripts/render-bootstrap-envs.sh"
if grep -Eq 'gdc-node[0-9]|gdc-node\$' "$ROOT/scripts/render-bootstrap-envs.sh"; then
  echo 'bootstrap environment rendering must derive aliases from inventory' >&2
  exit 1
fi
grep -Fq 'validation_weights' "$ROOT/scripts/ensure-genesis-validation-weight.sh"
grep -Fq 'test-inference.sh' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'sum(cometbft_p2p_peers) or vector(0)' "$ROOT/04-ops/grafana/generate-dashboards.sh"
grep -Fq '[[ ! -e "$STATE/joined/$node" ]]' "$ROOT/scripts/phase-explorer.sh"
grep -Fq 'label=com.docker.compose.project=$project' "$ROOT/scripts/phase-node.sh"
grep -Fq 'gdc-poc-winddown-watch@$NODE.service' "$ROOT/scripts/phase-node.sh"
grep -Fq '"/srv/dai/deploy/$NODE"' "$ROOT/scripts/phase-node.sh"
grep -Fq '"/srv/dai/$NODE"' "$ROOT/scripts/phase-node.sh"
grep -Fq 'READY detected linked GPU host' "$ROOT/scripts/phase-node.sh"
grep -Fq 'PRESERVE OPS public edge' "$ROOT/scripts/phase-node.sh"
grep -Fq 'gdc-ml-link.json' "$ROOT/scripts/phase-node.sh"
grep -Fq 'is not joined to the current chain' "$ROOT/scripts/phase-explorer.sh"
grep -Fq '.devshards[]?' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq '.devshards[]?' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'handle_path /gateway/*' "$ROOT/04-ops/Caddyfile"
grep -Fq 'handle /status/participants' "$ROOT/04-ops/Caddyfile"
grep -Fq 'ops-participant-status' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'rewrite * /ops-participant-status{uri}' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'handle /status/gpus' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'query=gdc_nvidia_memory_total_bytes' "$ROOT/04-ops/render-ops.sh"
grep -Fq "validator: '%s'" "$ROOT/04-ops/render-ops.sh"
grep -Fq 'header_up Host %s' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'json("/status/participants")' "$ROOT/04-ops/site/src/app.js"
grep -Fq 'validatorMapController?.update(observedNodes)' "$ROOT/04-ops/site/src/app.js"
grep -Fq 'AbortController' "$ROOT/04-ops/site/src/app.js"
grep -Fq 'observedNodes.filter((node) => node.participantStatus === "ACTIVE")' "$ROOT/04-ops/site/src/app.js"
grep -Fq '__PUBLIC_GRAFANA_PROMETHEUS_URL__' "$ROOT/04-ops/edge-node/public-grafana/provisioning/datasources/prometheus.yml"
grep -Fq 'PUBLIC_GRAFANA_PROMETHEUS_URL' "$ROOT/04-ops/edge-node/render-env.sh"
grep -Fq 'PUBLIC_GRAFANA_PROMETHEUS_URL' "$ROOT/04-ops/edge-node/install-edge.sh"
grep -Fq 'READY preserved existing OPS public edge' "$ROOT/04-ops/edge-node/install-edge.sh"
if grep -Eq 'node[0-9]\.gonka-dev\.net' "$ROOT/04-ops/edge-node/public-grafana/provisioning/datasources/prometheus.yml"; then
  echo 'public Grafana datasource must be rendered from the configured gateway role' >&2
  exit 1
fi
grep -Fq '/v1/versions' "$ROOT/04-ops/site/src/app.js"
grep -Eq 'external-test-lab/tree/[0-9a-f]+/net-deployment-runbook/04-ops/site"[^>]*>ref:[0-9a-f]+' "$ROOT/04-ops/site/index.html"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
rendered_site_index="$test_tmp/site-index.html"
"$ROOT/scripts/render-site-revision.sh" "$ROOT/04-ops/site/index.html" "$rendered_site_index"
site_commit="$(git -C "$ROOT/.." log -n 1 --pretty=format:%H -- net-deployment-runbook/04-ops/site)"
grep -Fq "ref:${site_commit:0:7}" "$rendered_site_index"
grep -Fq "https://github.com/paranjko/external-test-lab/tree/$site_commit/net-deployment-runbook/04-ops/site" "$rendered_site_index"
grep -Fq '!expectResetState && state.mapValidators !== mappedNodes.length' "$ROOT/scripts/capture-homepage-viewport.mjs"
grep -Fq '(!expectResetState && state.mapMarkers < 1) || state.mapPoints !== state.mapMarkers' "$ROOT/scripts/capture-homepage-viewport.mjs"
grep -Fq 'state.mapMarkers !== 0 || state.mapPoints !== 0' "$ROOT/scripts/capture-homepage-viewport.mjs"
grep -Fq 'GDC_MONITOR_HOST=$HOST' "$ROOT/04-ops/agent/render-env.sh"
grep -Fq 'gdc_component_info' "$ROOT/04-ops/agent/collect-versions.sh"
grep -Fq 'gdc_component_info' "$ROOT/04-ops/grafana/generate-dashboards.sh"
grep -Fq 'nodeCatalog:$nodeCatalog' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'gpuProfile:(if $gpuProfile == "auto" then null else $gpuProfile end)' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'CHAIN_RPC_RATE_UNIT: s' "$ROOT/02-node/compose.yaml"
grep -Fq 'TELEGRAM_BOT_TOKEN=replace-with-BotFather-token' "$ROOT/.env.example"
[[ ! -e "$ROOT/scripts/telegram-bot/.env.example" ]]
grep -Fq 'ops consumer telegram apply' "$ROOT/gdc.sh"
grep -Fq 'phase-telegram-consumer.sh' "$ROOT/gdc.sh"
grep -Fq 'gateway.telegram-client-key' "$ROOT/scripts/make-secrets.sh"
grep -Fq 'telegram.conversation-api-token' "$ROOT/scripts/make-secrets.sh"
! grep -Eq 'telegram-key-probe|gateway-key-pool|create-telegram-key-pool' \
  "$ROOT/gdc.sh" \
  "$ROOT/scripts/deploy-telegram-bot.sh" \
  "$ROOT/scripts/phase-gateway-continuity.sh" \
  "$ROOT/scripts/phase-reset.sh" \
  "$ROOT/scripts/telegram-bot" \
  "$ROOT/04-ops/gateway-health-probe.sh"
if grep -Fq 'ssh_ready gdc-node4' "$ROOT/scripts/phase-bootstrap-access.sh"; then
  echo 'bootstrap-access must not require gdc-node4' >&2
  exit 1
fi

for release in v2026.07.23 v2026.08.06; do
  GDC_RELEASE_PROFILE="$release" GDC_MODEL_PROFILE=qwen3-0.6b load_profiles
  [[ "$GDC_DEPLOYMENT_PROFILE" == community-lab ]]
  [[ "$GDC_OPERATOR_SERVICES_PROFILE" == gdc-lab ]]
  [[ "$GONKA_COMMIT" =~ ^[0-9a-f]{40}$ ]]
  [[ "$GONKA_REPOSITORY" == https://github.com/gonka-ai/gonka.git ]]
  [[ "$GONKA_SOURCE_REF" == "release/v$GONKA_RELEASE" ]]
  [[ "$GENESIS_EPOCH_LENGTH" == 50 && "$GENESIS_EPOCH_SHIFT" == 0 ]]
  [[ "$MLNODE_BLACKWELL_IMAGE" == "$MLNODE_GENERIC_IMAGE" ]] || {
    echo 'Blackwell image must use the verified generic upstream runtime' >&2
    exit 1
  }
  images=("$TMKMS_IMAGE" "$INFERENCED_IMAGE" "$DAPI_IMAGE" "$VERSIOND_IMAGE" "$PROXY_IMAGE" "$POSTGRES_IMAGE" "$MLNODE_GENERIC_IMAGE" "$MLNODE_BLACKWELL_IMAGE" "$MLNODE_PROXY_IMAGE")
  [[ "$EDGE_API_ENABLED" == false || "$EDGE_API_ENABLED" == true ]] || { echo "invalid EDGE_API_ENABLED in $release" >&2; exit 1; }
  [[ "$EDGE_API_ENABLED" != true ]] || images+=("$EDGE_API_IMAGE")
  for image in "${images[@]}"; do
    [[ "$image" != *:latest && "$image" != *:latest@* ]] || { echo "mutable image in $release: $image" >&2; exit 1; }
  done
  [[ "$DEVSHARD_V3_SHA256" =~ ^[0-9a-f]{64}$ && "$DEVSHARD_V4_SHA256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$BRIDGE_IMAGE" == *@sha256:* ]]
  expected_network_hash="$(sha256sum \
    "$ROOT/profiles/releases/$GDC_RELEASE_PROFILE.lock" \
    "$ROOT/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" \
    "$ROOT/profiles/models/$GDC_MODEL_PROFILE.lock" | sha256sum | awk '{print $1}')"
  expected_operator_hash="$(sha256sum \
    "$ROOT/profiles/operator-services/$GDC_OPERATOR_SERVICES_PROFILE.lock" \
    | sha256sum | awk '{print $1}')"
  [[ "$(profile_hash)" == "$expected_network_hash" ]]
  [[ "$(operator_profile_hash)" == "$expected_operator_hash" ]]
  if [[ "$release" == v2026.08.06 ]]; then
    [[ "$GONKA_HOST_STACK_COMMIT" == ce33c851282b8f4c0f63d78d46ddd4d8bb248207 ]]
    [[ "$GONKA_HOST_STACK_DOC_SHA256" == 5a69a2d82f77b4ecd1e207af1119063f32693afdc01bca58433f71ffe4061f82 ]]
    [[ "$GONKA_HOST_STACK_COMPOSE_SHA256" == d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94 ]]
    [[ "$DAPI_SOURCE_REF" == release/v0.2.15-post3 ]]
    [[ "$DAPI_COMMIT" == 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 ]]
    [[ "$DAPI_IMAGE" == ghcr.io/product-science/api:0.2.15-post3@sha256:3f81b7a9dfac66690e4a934a916662b248f20838dd8f7b47f1863fd3c5c5cd9c ]]
    [[ "$BRIDGE_IMAGE" == ghcr.io/product-science/bridge:0.2.15@sha256:ac01165eb8eb60dbafe5d1e060a11b474efb44146b12f308bef6153b55a2c22d ]]
    [[ "$INFERENCED_UPGRADE_URL" == https://github.com/gonka-ai/gonka/releases/download/release%2Fv0.2.15/inferenced-amd64.zip ]]
    [[ "$DAPI_UPGRADE_URL" == https://github.com/gonka-ai/gonka/releases/download/release%2Fv0.2.15-post3/decentralized-api-amd64.zip ]]
    [[ "$INFERENCED_UPGRADE_SHA256" == 91af67df9ef5c576a1695e5e85c8ee344f9f1a69d941bfc28fb339d9fd33617e ]]
    [[ "$DAPI_UPGRADE_SHA256" == 8cfa7345f5b7f968d5a1b765837b8319084c02d3dd2691b698c368774e20b55e ]]
  fi
  summary="$(profile_summary)"
  grep -qx "inferenced_image=$INFERENCED_IMAGE" <<<"$summary"
  grep -qx "dapi_image=$DAPI_IMAGE" <<<"$summary"
  grep -qx "mlnode_generic_image=$MLNODE_GENERIC_IMAGE" <<<"$summary"
  grep -qx "bridge_image=$BRIDGE_IMAGE" <<<"$summary"
  if [[ "$release" == v2026.08.06 ]]; then
    grep -qx "gonka_host_stack_commit=$GONKA_HOST_STACK_COMMIT" <<<"$summary"
    grep -qx "dapi_source_ref=$DAPI_SOURCE_REF" <<<"$summary"
    grep -qx "dapi_commit=$DAPI_COMMIT" <<<"$summary"
  fi
  grep -qx "operator_explorer_image=$EXPLORER_IMAGE" <<<"$summary"
  grep -qx "operator_caddy_image=$CADDY_IMAGE" <<<"$summary"
  grep -qx "operator_grafana_image=$GRAFANA_IMAGE" <<<"$summary"
  grep -qx "network_profile_hash=$expected_network_hash" <<<"$summary"
  grep -qx "operator_services_profile_hash=$expected_operator_hash" <<<"$summary"
done

for variable in EXPLORER_IMAGE DASHBOARD_PORT CADDY_IMAGE PROMETHEUS_IMAGE GRAFANA_IMAGE ALERTMANAGER_IMAGE BLACKBOX_IMAGE NODE_EXPORTER_IMAGE CADVISOR_IMAGE; do
  ! grep -q "^$variable=" "$ROOT"/profiles/releases/*.lock
done
! grep -q '^GDC_INFERENCED_TOOL_IMAGE=' "$ROOT"/profiles/releases/*.lock
grep -Fq 'GDC_DEPLOYMENT_PROFILE:-community-lab' "$ROOT/scripts/lib.sh"
grep -Fq 'GDC_OPERATOR_SERVICES_PROFILE:-gdc-lab' "$ROOT/scripts/lib.sh"

GDC_RELEASE_PROFILE=v2026.07.23 GDC_MODEL_PROFILE=qwen3-0.6b load_profiles
for profile in a5000-24g t4-16g 4090-24g 3090-24g blackwell-16g; do
  out="$(mktemp)"
  trap 'rm -f "${out:-}"' EXIT
  "$ROOT/02-node/render-node-config.sh" --node-name validator-b --node-index 1 --profile "$profile" --output "$out" >/dev/null
  jq -e --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" '
    .[0].max_concurrent == 64
    and (.[0].models[$model].args | index("--dtype") != null)
    and (.[0].models[$model].args | index($revision) != null)
    and (.[0].models[$model].args | index("2048") != null)
  ' "$out" >/dev/null
  rm -f "$out"
  unset out
done
genesis_out="$(mktemp)"
trap 'rm -f "${genesis_out:-}"' EXIT
GDC_RELEASE_PROFILE=v2026.07.23 GDC_MODEL_PROFILE=qwen3-0.6b GDC_GENESIS_GUARDIAN_ENABLED=true \
  "$ROOT/01-identities-genesis/render-genesis-overrides.sh" \
  --gateway-account gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq \
  --genesis-guardian gonkavaloper1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr \
  --output "$genesis_out" >/dev/null
jq -e --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" --arg guardian gonkavaloper1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr '
  .app_state.inference.model_list[0] as $model_config
  | $model_config.id == $model
  and $model_config.hf_commit == $revision
  and $model_config.v_ram == "16"
  and $model_config.throughput_per_nonce == "10000"
  and .app_state.inference.params.devshard_escrow_params.approved_versions == []
  and .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses == []
  and .app_state.inference.params.poc_params.models[0].model_id == $model
  and .app_state.inference.params.epoch_params.epoch_length == "50"
  and .app_state.inference.params.epoch_params.epoch_shift == "0"
  and .app_state.inference.params.epoch_params.poc_stage_duration == "4"
  and .app_state.inference.params.epoch_params.poc_exchange_duration == "8"
  and .app_state.inference.params.epoch_params.poc_validation_delay == "10"
  and .app_state.inference.params.epoch_params.poc_validation_duration == "4"
  and .app_state.inference.params.epoch_params.poc_slot_allocation == {"value":"5","exponent":-1}
  and .app_state.inference.params.poc_params.validation_slots == 2
  and .app_state.inference.params.genesis_guardian_params.guardian_addresses == [$guardian]
  and .app_state.inference.params.genesis_guardian_params.network_maturity_threshold == "2000000"
  and .app_state.inference.genesis_only_params.genesis_guardian_enabled == true
  and .app_state.inference.genesis_only_params.genesis_guardian_addresses == [$guardian]
  and .app_state.gov.params.voting_period == "30s"
' "$genesis_out" >/dev/null
rm -f "$genesis_out"
unset genesis_out
if grep -Fq 'GDC_NODE_HANDOFF_DIR' "$ROOT/scripts/phase-join.sh"; then
  echo 'join must not require a personal handoff directory' >&2
  exit 1
fi
grep -Fq 'GDC_STOP_POC_AT_WINDDOWN' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'GDC_GENESIS_GUARDIAN_ENABLED' "$ROOT/01-identities-genesis/render-genesis-overrides.sh"
grep -Fq 'single-node bootstrap requires GDC_GENESIS_GUARDIAN_ENABLED=true' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'Create scoped operator secrets for $NODE' "$ROOT/scripts/phase-join.sh"
grep -Fq 'wait-hardware-node.sh' "$ROOT/scripts/phase-ml-attach.sh"
grep -Fq 'Record the explicit Network Node to external GPU association' "$ROOT/scripts/phase-ml-attach.sh"
grep -Fq 'hardware_nodes/${ADDRESS}' "$ROOT/scripts/wait-hardware-node.sh"
grep -Fq '.status == "INFERENCE"' "$ROOT/scripts/wait-hardware-node.sh"
grep -Fq 'GDC_JOIN_REGISTRATION_TIMEOUT_SECONDS' "$ROOT/scripts/phase-join.sh"
grep -Fq 'registration endpoint returned transient 5xx' "$ROOT/scripts/phase-join.sh"
if grep -Fq './register-participant.sh .env >register-participant.log 2>&1" || true' "$ROOT/scripts/phase-join.sh"; then
  echo 'join must not suppress failed participant registration before waiting for it' >&2
  exit 1
fi
grep -Fq 'PoCGenerateWindDown' "$ROOT/02-node/poc-winddown-watch.sh"
grep -Fq 'GDC_POC_WINDDOWN_API_URL' "$ROOT/02-node/poc-winddown-watch.sh"
grep -Fq 'http://127.0.0.1:9000' "$ROOT/02-node/poc-winddown-watch.sh"
if grep -Fq '"${PUBLIC_URL}/api/v1/epochs/latest"' "$ROOT/02-node/poc-winddown-watch.sh"; then
  echo 'PoC wind-down watcher must not poll the rate-limited public API' >&2
  exit 1
fi
grep -Fq 'GONKA_API_EXEMPT_ROUTES: chat inference poc/proofs subnet devshard participants' "$ROOT/02-node/compose.yaml"
grep -Fq 'gdc-poc-winddown-watch@' "$ROOT/02-node/install-node.sh"
grep -Fq 'gdc-poc-winddown-watch@' "$ROOT/02-node/ml-only/install-ml.sh"
grep -Fq 'require_current_baseline_pass' "$ROOT/scripts/phase-propose-upgrade.sh"
grep -Fq 'require_current_baseline_pass' "$ROOT/scripts/phase-upgrade.sh"
grep -Fq 'require_current_baseline_pass' "$ROOT/scripts/phase-upgrade-worker.sh"
grep -Fq '# DevNet verification: PASS' "$ROOT/scripts/lib.sh"
grep -Fq 'GDC_NODE_ALIASES' "$ROOT/scripts/lib.sh"
if (
  # These globals are consumed by node_name from sourced lib.sh.
  # shellcheck disable=SC2034
  GDC_NODES=(gdc-node0 gdc-node2)
  # shellcheck disable=SC2034
  GENESIS_NODE=gdc-node0
  node_name node2
) >/dev/null 2>&1; then
  echo 'aliases absent from the operator inventory must be rejected' >&2
  exit 1
fi
[[ "$({
  # These globals are consumed by node_name from sourced lib.sh.
  # shellcheck disable=SC2034
  GDC_NODES=(gdc-node0 gdc-node2)
  # shellcheck disable=SC2034
  GENESIS_NODE=gdc-node0
  node_name gdc-node2
})" == gdc-node2 ]]
grep -Fq 'ACTIVE chain participants differ from joined state' "$ROOT/scripts/phase-verify.sh"
grep -Fq 'trap on_exit EXIT' "$ROOT/scripts/phase-verify.sh"
for evidence_phase in phase-settle.sh phase-ha-v4.sh phase-bridge-observer.sh phase-governance-devshard.sh phase-propose-upgrade.sh phase-vote-proposal.sh phase-audit-lifecycle.sh; do
  grep -Fq 'install_evidence_exit_trap' "$ROOT/scripts/$evidence_phase"
done
grep -Fq 'skip duplicate registration' "$ROOT/scripts/phase-join.sh"
grep -Fq 'skip duplicate funding and ML permission transactions' "$ROOT/scripts/phase-join.sh"
grep -Fq 'upgrade proposal: MISSING' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq "'gateway continuity|*-gateway-continuity/*|# Gateway continuity: PASS'" "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'genesis_sha256=$live_genesis_sha256' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'genesis_sha256=$genesis_sha256' "$ROOT/scripts/phase-verify.sh"
grep -Fq "printf 'genesis_sha256=%s\\n' \"\$genesis_sha256\"" "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'key_source=assurance' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'GDC_GATEWAY_PARTICIPANT_REQUEST_BURST=1000000000' "$ROOT/.env.example"
grep -Fq 'GATEWAY_PARTICIPANT_REQUEST_BURST=${GDC_GATEWAY_PARTICIPANT_REQUEST_BURST:-1000000000}' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'participant_throttle' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'Reconcile the gateway creator reserve before escrow reuse or replacement' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'discard retired gateway escrow' "$ROOT/scripts/phase-ops.sh"
for genesis_bound_phase in phase-settle.sh phase-ha-v4.sh; do
  grep -Fq "printf 'genesis_sha256=%s\\n' \"\$genesis_sha256\"" "$ROOT/scripts/$genesis_bound_phase"
done
grep -Fq 'genesis_sha256=$live_genesis_sha256' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'genesis_overrides_sha256' "$ROOT/01-identities-genesis/build-genesis.sh"
grep -Fq 'PROFILE phase=genesis' "$ROOT/scripts/phase-genesis.sh"
grep -Fq '"routable"[[:space:]]*:[[:space:]]*true' "$ROOT/04-ops/compose.yaml"
if grep -Eq 'handoff\)|phase-handoff|GDC_NODE_HANDOFF_DIR' "$ROOT/gdc.sh" "$ROOT/scripts/phase-join.sh"; then
  echo 'Host join must not depend on a central handoff or approval flow' >&2
  exit 1
fi
grep -Fq 'fetch-join-bootstrap.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'claim-devnet-faucet.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'sha256sum -c manifest.sha256' "$ROOT/scripts/fetch-join-bootstrap.sh"
grep -Fq 'GDC_FAUCET_CLAIM_NGONKA' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GDC_FAUCET_INITIAL_NGONKA' "$ROOT/01-identities-genesis/build-genesis.sh"
grep -Fq 'handle_path /faucet/*' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'handle_path /join-bootstrap/*' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'Grant ML operational permissions for $NODE' "$ROOT/scripts/phase-join.sh"
grep -Fq 'devshard_version=' "$ROOT/scripts/phase-settle.sh"
grep -Fq "grep -qx 'devshard_version=v4'" "$ROOT/scripts/phase-ha-v4.sh"
grep -Fq 'base-inputs-before.sha256' "$ROOT/scripts/phase-ha-v4.sh"
grep -Fq 'settlement_bundle=' "$ROOT/scripts/phase-ha-v4.sh"
grep -Fq 'genesis_sha256=%s' "$ROOT/scripts/phase-bridge-observer.sh"
if grep -Eq 'ha-v4|HA evidence|devshard_version=v4' "$ROOT/scripts/phase-bridge-observer.sh"; then
  echo 'Bridge observer must not depend on DevShard HA' >&2
  exit 1
fi
grep -Fq 'GDC_SEPOLIA_PRIVATE_KEY_FILE' "$ROOT/scripts/phase-bridge-deploy-sepolia.sh"
grep -Fq 'GDC_BRIDGE_GOVERNANCE_SUBMIT' "$ROOT/scripts/phase-bridge-register-sepolia.sh"
grep -Fq 'MsgRegisterBridgeAddresses' "$ROOT/scripts/phase-bridge-register-sepolia.sh"
grep -Fq 'configured checkpoint endpoint did not return JSON' "$ROOT/scripts/phase-bridge-observer.sh"
grep -Fq "'Sepolia bridge observer|*-bridge-observer-verify-*/*|# Sepolia bridge observer: PASS'" "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq "require_pass_bundle '*-bridge-register-sepolia/*' '# Sepolia bridge governance registration: PASS'" "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'bridge observer bundle lacks a finalized Sepolia block cursor' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq "release_profile=v2026.08.06" "$ROOT/scripts/phase-audit-lifecycle.sh"
if grep -Fq 'install-node.sh' "$ROOT/scripts/phase-ha-v4.sh"; then
  echo 'HA must install only its overlay and must not reinstall the Network Node' >&2
  exit 1
fi

role_input="$test_tmp/role-input"
cat >"$role_input" <<'EOF'
GDC_NODE_ALIASES="gdc-node0 gdc-node2"
GDC_NODE_PUBLIC_HOSTS="gdc-node0=127.0.0.1 gdc-node2=127.0.0.1"
GDC_NODE_GPU_PROFILES="gdc-node0=auto gdc-node2=auto"
GDC_NODE_P2P_PORTS="gdc-node0=5000 gdc-node2=5000"
GDC_GENESIS_NODE=gdc-node0
GDC_PUBLIC_EDGE_NODE=gdc-node0
GDC_GATEWAY_NODE=gdc-node0
GDC_TELEGRAM_BOT_HOST=gdc-node0
GDC_GENESIS_GUARDIAN_ENABLED=true
EOF
node_secret_dir="$test_tmp/node-secrets"
unset GDC_GENESIS_NODE GDC_PUBLIC_EDGE_NODE GDC_GATEWAY_NODE GDC_TELEGRAM_BOT_HOST GDC_GENESIS_GUARDIAN_ENABLED
GDC_ENV="$role_input" "$ROOT/scripts/make-node-operator-secrets.sh" gdc-node2 "$node_secret_dir" >/dev/null
mapfile -t node_secret_files < <(find "$node_secret_dir" -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${node_secret_files[*]}" == 'gdc-node2.keyring gdc-node2.postgres operator.keyring' ]]
node_secret_hash_before="$(find "$node_secret_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum)"
GDC_ENV="$role_input" "$ROOT/scripts/make-node-operator-secrets.sh" gdc-node2 "$node_secret_dir" >/dev/null
node_secret_hash_after="$(find "$node_secret_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum)"
[[ "$node_secret_hash_before" == "$node_secret_hash_after" ]]
unset node_secret_dir

join_secret_line="$(grep -n 'make-node-operator-secrets.sh' "$ROOT/scripts/phase-join.sh" | cut -d: -f1)"
join_account_line="$(grep -n 'create-cold-accounts.sh' "$ROOT/scripts/phase-join.sh" | cut -d: -f1)"
[[ "$join_secret_line" -lt "$join_account_line" ]] || {
  echo 'Host join must create its local keyring before creating its cold account' >&2
  exit 1
}

trap_test_dir="$test_tmp/evidence-trap"
mkdir -p "$trap_test_dir"
set +e
(
  source "$ROOT/scripts/lib.sh"
  export RUN="$trap_test_dir"
  install_evidence_exit_trap 'Contract test'
  exit 7
)
trap_test_rc=$?
set -e
[[ "$trap_test_rc" == 7 ]]
grep -qx '# Contract test: INCONCLUSIVE' "$trap_test_dir/verdict.md"
grep -q 'exit code 7' "$trap_test_dir/verdict.md"
unset trap_test_dir
printf 'PASS release/model profile invariants\n'
