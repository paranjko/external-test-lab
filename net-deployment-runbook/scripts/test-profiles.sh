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
grep -Fq 'status.json.tmp' "$ROOT/scripts/qualify-ml-remote.sh"
grep -Fq '2>>"$WORK/control.log"' "$ROOT/scripts/qualify-ml-remote.sh"
grep -Fq 'phase-bootstrap-access.sh' "$ROOT/gdc.sh"
grep -Fq 'GDC_CHAIN_RPC_URL' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'GDC_GATEWAY_PUBLIC_URL="https://${API_HOST}"' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'GDC_TELEGRAM_BOT_API_BASE_URL="$GDC_GATEWAY_PUBLIC_URL/v1"' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'GDC_RUN_ID' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'GDC_GOVERNANCE_AUTO_VOTE=true' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'ensure-genesis-validation-weight.sh' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'AMOUNT="${AMOUNT:-$MIN_AMOUNT}"' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'AMOUNT <= SPENDABLE_AMOUNT' "$ROOT/04-ops/create-gateway.sh"
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
grep -Fq 'GDC_GATEWAY_MIN_SPENDABLE_NGONKA:-100000000000' "$ROOT/scripts/phase-ops.sh"
grep -Fq '\"temp_count\":$gateway_rotation_temp_count' "$ROOT/scripts/phase-ops.sh"
grep -Fq '\"target_count\":$gateway_rotation_target_count' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS:-45' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'DEVSHARD_CAPACITY_AWARE_LIMITS=off' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'GDC_GATEWAY_EXTERNAL_RECONCILIATION_ENABLED=true' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'gateway-escrow-reconciler.sh' "$ROOT/04-ops/install-ops.sh"
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
grep -Fq 'validation_weights' "$ROOT/scripts/ensure-genesis-validation-weight.sh"
grep -Fq 'test-inference.sh' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'sum(cometbft_p2p_peers) or vector(0)' "$ROOT/04-ops/grafana/generate-dashboards.sh"
grep -Fq '[[ ! -e "$STATE/joined/$node" ]]' "$ROOT/scripts/phase-explorer.sh"
grep -Fq 'is not joined to the current chain' "$ROOT/scripts/phase-explorer.sh"
grep -Fq '.devshards[]?' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq '.devshards[]?' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'handle_path /gateway/*' "$ROOT/04-ops/Caddyfile"
grep -Fq 'handle /status/participants' "$ROOT/04-ops/Caddyfile"
grep -Fq "json('/status/participants')" "$ROOT/04-ops/site/app.js"
grep -Fq 'validatorMapController?.update(observedNodes)' "$ROOT/04-ops/site/app.js"
grep -Fq '/v1/versions' "$ROOT/04-ops/site/app.js"
grep -Eq 'external-test-lab/tree/[0-9a-f]+/net-deployment-runbook/04-ops/site"[^>]*>ref:[0-9a-f]+' "$ROOT/04-ops/site/index.html"
rendered_site_index="$(mktemp)"
trap 'rm -f "$rendered_site_index"' EXIT
"$ROOT/scripts/render-site-revision.sh" "$ROOT/04-ops/site/index.html" "$rendered_site_index"
site_commit="$(git -C "$ROOT/.." log -n 1 --pretty=format:%H -- net-deployment-runbook/04-ops/site)"
grep -Fq "ref:${site_commit:0:7}" "$rendered_site_index"
grep -Fq "https://github.com/paranjko/external-test-lab/tree/$site_commit/net-deployment-runbook/04-ops/site" "$rendered_site_index"
grep -Fq 'mapValidators !== mappedNodes.length' "$ROOT/scripts/capture-homepage-viewport.mjs"
grep -Fq 'GDC_MONITOR_HOST=$HOST' "$ROOT/04-ops/agent/render-env.sh"
grep -Fq 'gdc_component_info' "$ROOT/04-ops/agent/collect-versions.sh"
grep -Fq 'gdc_component_info' "$ROOT/04-ops/grafana/generate-dashboards.sh"
grep -Fq 'nodeCatalog:$nodeCatalog' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'CHAIN_RPC_RATE_UNIT: s' "$ROOT/02-node/compose.yaml"
grep -Fq 'TELEGRAM_BOT_TOKEN=replace-with-BotFather-token' "$ROOT/.env.example"
[[ ! -e "$ROOT/scripts/telegram-bot/.env.example" ]]
grep -Fq 'telegram-key-probe' "$ROOT/gdc.sh"
grep -Fq 'docker exec -i' "$ROOT/scripts/phase-telegram-key-probe.sh"
grep -Fq 'GDC_ASSURANCE_SLA_MS' "$ROOT/scripts/phase-telegram-key-probe.sh"
grep -Fq 'temporary_assignment_cleaned' "$ROOT/scripts/phase-telegram-key-probe.sh"
if grep -Fq 'DELETE FROM keys WHERE telegram_id' "$ROOT/scripts/phase-telegram-key-probe.sh"; then
  echo 'telegram-key-probe phase must not blindly delete an assignment before collision checks' >&2
  exit 1
fi
if grep -Fq 'ssh_ready gdc-node4' "$ROOT/scripts/phase-bootstrap-access.sh"; then
  echo 'bootstrap-access must not require gdc-node4' >&2
  exit 1
fi

for release in testnet-0.2.14 testnet-0.2.15; do
  GDC_RELEASE_PROFILE="$release" GDC_MODEL_PROFILE=qwen3-0.6b load_profiles
  [[ "$GDC_DEPLOYMENT_PROFILE" == community-lab ]]
  [[ "$GDC_OPERATOR_SERVICES_PROFILE" == gdc-lab ]]
  [[ "$GONKA_COMMIT" =~ ^[0-9a-f]{40}$ ]]
  [[ "$GONKA_REPOSITORY" == https://github.com/gonka-ai/gonka.git ]]
  [[ "$GONKA_SOURCE_REF" == "release/v$GONKA_RELEASE" ]]
  [[ "$GENESIS_EPOCH_LENGTH" == 50 && "$GENESIS_EPOCH_SHIFT" == 0 ]]
  images=("$TMKMS_IMAGE" "$INFERENCED_IMAGE" "$DAPI_IMAGE" "$VERSIOND_IMAGE" "$PROXY_IMAGE" "$POSTGRES_IMAGE" "$MLNODE_GENERIC_IMAGE" "$MLNODE_BLACKWELL_IMAGE" "$MLNODE_PROXY_IMAGE")
  [[ "$EDGE_API_ENABLED" == false || "$EDGE_API_ENABLED" == true ]] || { echo "invalid EDGE_API_ENABLED in $release" >&2; exit 1; }
  [[ "$EDGE_API_ENABLED" != true ]] || images+=("$EDGE_API_IMAGE")
  for image in "${images[@]}"; do
    [[ "$image" != *:latest && "$image" != *:latest@* ]] || { echo "mutable image in $release: $image" >&2; exit 1; }
  done
  [[ "$DEVSHARD_V3_SHA256" =~ ^[0-9a-f]{64}$ && "$DEVSHARD_V4_SHA256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$BRIDGE_IMAGE" == *@sha256:* ]]
  [[ "$GDC_INFERENCED_TOOL_IMAGE" == "$INFERENCED_IMAGE" ]]
  expected_network_hash="$(sha256sum \
    "$ROOT/profiles/releases/$GDC_RELEASE_PROFILE.lock" \
    "$ROOT/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" \
    "$ROOT/profiles/models/$GDC_MODEL_PROFILE.lock" | sha256sum | awk '{print $1}')"
  expected_operator_hash="$(sha256sum \
    "$ROOT/profiles/operator-services/$GDC_OPERATOR_SERVICES_PROFILE.lock" \
    | sha256sum | awk '{print $1}')"
  [[ "$(profile_hash)" == "$expected_network_hash" ]]
  [[ "$(operator_profile_hash)" == "$expected_operator_hash" ]]
  if [[ "$release" == testnet-0.2.15 ]]; then
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
  if [[ "$release" == testnet-0.2.15 ]]; then
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

GDC_RELEASE_PROFILE=testnet-0.2.14 GDC_MODEL_PROFILE=qwen3-0.6b load_profiles
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
GDC_RELEASE_PROFILE=testnet-0.2.14 GDC_MODEL_PROFILE=qwen3-0.6b GDC_GENESIS_GUARDIAN_ENABLED=true \
  "$ROOT/01-identities-genesis/render-genesis-overrides.sh" \
  --gateway-account gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq \
  --genesis-guardian gonka1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr \
  --output "$genesis_out" >/dev/null
jq -e --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" --arg guardian gonka1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr '
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
  and .app_state.inference.params.poc_params.validation_slots == 1
  and .app_state.inference.params.genesis_guardian_params.guardian_addresses == [$guardian]
  and .app_state.inference.params.genesis_guardian_params.network_maturity_threshold == "2000000"
  and .app_state.inference.genesis_only_params.genesis_guardian_enabled == true
  and .app_state.inference.genesis_only_params.genesis_guardian_addresses == [$guardian]
  and .app_state.gov.params.voting_period == "30s"
' "$genesis_out" >/dev/null
rm -f "$genesis_out"
unset genesis_out
grep -Fq 'GDC_NODE_HANDOFF_DIR' "$ROOT/scripts/phase-join.sh"
grep -Fq 'GDC_STOP_POC_AT_WINDDOWN' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'GDC_GENESIS_GUARDIAN_ENABLED' "$ROOT/01-identities-genesis/render-genesis-overrides.sh"
grep -Fq 'one joined non-guardian model participant' "$ROOT/scripts/phase-bootstrap-access.sh"
grep -Fq 'Create scoped operator secrets for $NODE' "$ROOT/scripts/phase-join.sh"
grep -Fq 'PoCGenerateWindDown' "$ROOT/02-node/poc-winddown-watch.sh"
grep -Fq 'gdc-poc-winddown-watch@' "$ROOT/02-node/install-node.sh"
grep -Fq 'gdc-poc-winddown-watch@' "$ROOT/02-node/ml-only/install-ml.sh"
grep -Fq 'require_current_baseline_pass' "$ROOT/scripts/phase-propose-upgrade.sh"
grep -Fq 'require_current_baseline_pass' "$ROOT/scripts/phase-upgrade.sh"
grep -Fq 'require_current_baseline_pass' "$ROOT/scripts/phase-upgrade-worker.sh"
grep -Fq '# DevNet verification: PASS' "$ROOT/scripts/lib.sh"
grep -Fq 'GDC_NODE_ALIASES' "$ROOT/scripts/lib.sh"
if (source "$ROOT/scripts/lib.sh"; load_project; node_name node2) >/dev/null 2>&1; then
  echo 'aliases absent from the operator inventory must be rejected' >&2
  exit 1
fi
[[ "$(source "$ROOT/scripts/lib.sh"; load_project >/dev/null; node_name gdc-node2)" == gdc-node2 ]]
grep -Fq 'ACTIVE chain participants differ from joined state' "$ROOT/scripts/phase-verify.sh"
grep -Fq 'trap on_exit EXIT' "$ROOT/scripts/phase-verify.sh"
for evidence_phase in phase-settle.sh phase-ha-v4.sh phase-bridge-sepolia.sh phase-governance-devshard.sh phase-propose-upgrade.sh phase-vote-proposal.sh phase-audit-lifecycle.sh; do
  grep -Fq 'install_evidence_exit_trap' "$ROOT/scripts/$evidence_phase"
done
grep -Fq 'skip duplicate registration' "$ROOT/scripts/phase-join.sh"
grep -Fq 'skip duplicate funding and ML permission transactions' "$ROOT/scripts/phase-join.sh"
grep -Fq 'upgrade proposal: MISSING' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq "'gateway continuity|*-gateway-continuity/*|# Gateway continuity: PASS'" "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'genesis_sha256=$live_genesis_sha256' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'genesis_sha256=$genesis_sha256' "$ROOT/scripts/phase-verify.sh"
grep -Fq "printf 'genesis_sha256=%s\\n' \"\$genesis_sha256\"" "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'GDC_GATEWAY_CONTINUITY_KEY_SOURCE:-telegram-pool' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'GDC_GATEWAY_PARTICIPANT_REQUEST_BURST=1000000000' "$ROOT/.env.example"
grep -Fq 'GATEWAY_PARTICIPANT_REQUEST_BURST=${GDC_GATEWAY_PARTICIPANT_REQUEST_BURST:-1000000000}' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'participant_throttle' "$ROOT/scripts/phase-ops.sh"
for genesis_bound_phase in phase-settle.sh phase-ha-v4.sh phase-bridge-sepolia.sh; do
  grep -Fq "printf 'genesis_sha256=%s\\n' \"\$genesis_sha256\"" "$ROOT/scripts/$genesis_bound_phase"
done
grep -Fq 'genesis_sha256=$live_genesis_sha256' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'genesis_overrides_sha256' "$ROOT/01-identities-genesis/build-genesis.sh"
grep -Fq 'PROFILE phase=genesis' "$ROOT/scripts/phase-genesis.sh"
grep -Fq '"routable"[[:space:]]*:[[:space:]]*true' "$ROOT/04-ops/compose.yaml"
grep -Fq 'operator.keyring' "$ROOT/scripts/phase-handoff-approve.sh"
if grep -Fq 'operator.keyring' "$ROOT/scripts/phase-handoff-create.sh"; then
  echo 'handoff bundle creator must not transfer the coordinator operator key' >&2
  exit 1
fi
if grep -Eq 'secrets/|accounts/' "$ROOT/scripts/phase-handoff-create.sh"; then
  echo 'handoff bundle must not transfer operator-owned keys or accounts' >&2
  exit 1
fi
if grep -Fq 'grant-ml-ops.sh' "$ROOT/scripts/phase-handoff-approve.sh"; then
  echo 'coordinator approval must not sign ML permissions with an operator key' >&2
  exit 1
fi
grep -Fq 'sha256sum -c manifest.sha256' "$ROOT/scripts/phase-join.sh"
grep -Fq 'gonka-devnet-community-node-handoff-v2' "$ROOT/scripts/phase-handoff-approve.sh"
grep -Fq 'is already registered; restore that operator' "$ROOT/scripts/phase-handoff-create.sh"
grep -Fq 'GDC_SKIP_HOSTS=' "$ROOT/scripts/phase-handoff-create.sh"
grep -Fq 'registered participant does not match the activation request address and consensus key' "$ROOT/scripts/phase-handoff-approve.sh"
grep -Fq 'Grant ML operational permissions with the operator-owned' "$ROOT/scripts/phase-join.sh"
grep -Fq 'devshard_version=' "$ROOT/scripts/phase-settle.sh"
grep -Fq "grep -qx 'devshard_version=v4'" "$ROOT/scripts/phase-ha-v4.sh"
grep -Fq 'base-inputs-before.sha256' "$ROOT/scripts/phase-ha-v4.sh"
grep -Fq 'settlement_bundle=' "$ROOT/scripts/phase-ha-v4.sh"
grep -Fq 'Latest HA evidence does not belong to the current' "$ROOT/scripts/phase-bridge-sepolia.sh"
grep -Fq 'beacon_state_url_sha256=' "$ROOT/scripts/phase-bridge-sepolia.sh"
grep -Fq 'GDC_SEPOLIA_PRIVATE_KEY_FILE' "$ROOT/scripts/phase-bridge-deploy-sepolia.sh"
grep -Fq 'GDC_BRIDGE_GOVERNANCE_SUBMIT' "$ROOT/scripts/phase-bridge-register-sepolia.sh"
grep -Fq 'MsgRegisterBridgeAddresses' "$ROOT/scripts/phase-bridge-register-sepolia.sh"
grep -Fq 'configured beacon-state endpoint did not return JSON' "$ROOT/scripts/phase-bridge-sepolia.sh"
grep -Fq "'Sepolia bridge|*-bridge-sepolia/*|# Sepolia bridge: PASS'" "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq "require_pass_bundle '*-bridge-register-sepolia/*' '# Sepolia bridge governance registration: PASS'" "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'bridge runtime bundle lacks beacon preflight evidence' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq "release_profile=testnet-0.2.15" "$ROOT/scripts/phase-audit-lifecycle.sh"
if grep -Fq 'install-node.sh' "$ROOT/scripts/phase-ha-v4.sh"; then
  echo 'HA must install only its overlay and must not reinstall the Network Node' >&2
  exit 1
fi

node_secret_dir="$(mktemp -d)"
trap 'rm -rf "${node_secret_dir:-}"' EXIT
"$ROOT/scripts/make-node-operator-secrets.sh" gdc-node2 "$node_secret_dir" >/dev/null
mapfile -t node_secret_files < <(find "$node_secret_dir" -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${node_secret_files[*]}" == 'gdc-node2.keyring gdc-node2.postgres operator.keyring' ]]
node_secret_hash_before="$(find "$node_secret_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum)"
"$ROOT/scripts/make-node-operator-secrets.sh" gdc-node2 "$node_secret_dir" >/dev/null
node_secret_hash_after="$(find "$node_secret_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum)"
[[ "$node_secret_hash_before" == "$node_secret_hash_after" ]]
rm -rf "$node_secret_dir"
unset node_secret_dir

trap_test_dir="$(mktemp -d)"
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
rm -rf "$trap_test_dir"
unset trap_test_dir
printf 'PASS release/model profile invariants\n'
