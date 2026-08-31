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
  [[ "$GDC_GATEWAY_VERSION" =~ ^v[345]$ ]] || die 'GDC_GATEWAY_VERSION must be v3, v4 or v5'
  gateway_supported_protocols="${DEVSHARD_SUPPORTED_PROTOCOLS:-$DEVSHARD_PROTOCOL_VERSION}"
  case " $gateway_supported_protocols " in
    *" $GDC_GATEWAY_VERSION "*) ;;
    *) die "DevShard $GDC_GATEWAY_VERSION is not supported by the pinned gateway artifact; supported: $gateway_supported_protocols" ;;
  esac
  case "$GDC_GATEWAY_VERSION" in
    v3) gateway_archive_url="$DEVSHARD_V3_URL"; gateway_archive_sha="$DEVSHARD_V3_SHA256" ;;
    v4) gateway_archive_url="$DEVSHARD_V4_URL"; gateway_archive_sha="$DEVSHARD_V4_SHA256" ;;
    v5) gateway_archive_url="$DEVSHARD_V5_URL"; gateway_archive_sha="$DEVSHARD_V5_SHA256" ;;
  esac
  gateway_approved_params="$STATE/gateway-approved-$GDC_GATEWAY_VERSION.json"
  "$ROOT/scripts/inferenced.sh" query inference params \
    --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" --chain-id "$CHAIN_ID" --output json \
    >"$gateway_approved_params"
  "$ROOT/scripts/verify-approved-devshard-version.sh" \
    "$gateway_approved_params" "$GDC_GATEWAY_VERSION" "$gateway_archive_url" "$gateway_archive_sha"
  GDC_GATEWAY_PUBLIC_URL="${GDC_GATEWAY_PUBLIC_URL:-https://$API_HOST}"
  GDC_GATEWAY_PUBLIC_URL="${GDC_GATEWAY_PUBLIC_URL%/}"
  GDC_GATEWAY_ARCHIVE_URL="$gateway_archive_url"
  GDC_GATEWAY_ARCHIVE_SHA256="$gateway_archive_sha"
  export GDC_GATEWAY_VERSION GDC_GATEWAY_ARCHIVE_URL GDC_GATEWAY_ARCHIVE_SHA256
fi
OPS_RENDER="$GENERATED/ops"
GATEWAY_ENV="$OPS_RENDER/gateway.env"
GATEWAY_OBSERVER_ENV="$OPS_RENDER/gateway-admission-observer.env"
FAUCET_ENV="$OPS_RENDER/faucet.env"
GATEWAY_RESERVE_ENV="$OPS_RENDER/gateway-reserve-signer.env"
REMOTE="/tmp/gdc-ops-$$"
SITE_INDEX_RENDER=''
FAUCET_OPTION=''
FAUCET_SIGNER_HOME=''

if [[ "$COMPONENT" == faucet || "$COMPONENT" == gateway ]]; then
  reserve_signer_token="$SECRETS/gateway.reserve-signer-token"
  [[ ! -L "$reserve_signer_token" ]] \
    || die 'gateway reserve signer credential must not be a symbolic link'
  reserve_signer_token_state=preserved
  [[ -e "$reserve_signer_token" ]] || reserve_signer_token_state=created
  "$ROOT/scripts/make-secrets.sh" "$SECRETS" "$GENESIS_NODE" >/dev/null
  [[ -f "$reserve_signer_token" && -s "$reserve_signer_token" ]] \
    || die 'gateway reserve signer credential is unavailable after managed secret initialization'
  [[ "$(stat -c '%a' "$reserve_signer_token")" == 600 ]] \
    || die 'gateway reserve signer credential must have mode 0600'
  printf 'READY gateway reserve signer credential %s\n' "$reserve_signer_token_state"
fi

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
  local node="$PUBLIC_EDGE_NODE" edge_env edge_remote edge_start_log
  edge_env="$GENERATED/edge/$node.env"
  edge_remote="${REMOTE}-edge"
  mkdir -p "$(dirname "$edge_env")"
  "$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$node" --output "$edge_env" >/dev/null
  ssh "$node" "rm -rf '$edge_remote' && mkdir -p '$edge_remote'"
  rsync -a "$ROOT/04-ops/edge-node/" "$node:$edge_remote/edge/"
  scp -q "$edge_env" "$node:$edge_remote/edge.env"
  edge_start_log='/srv/dai/edge/start-public-grafana.log'
  ssh -T "$node" "sudo '$edge_remote/edge/install-edge.sh' '$edge_remote/edge.env'; rm -rf '$edge_remote'; cd /srv/dai/edge && docker compose --profile public-edge up -d --force-recreate public-grafana >'$edge_start_log' 2>&1; for attempt in \$(seq 1 60); do curl -fsS http://127.0.0.1:3001/api/health >/dev/null 2>&1 && break; echo \"WAIT public Grafana local health attempt=\$attempt/60 reason=connection-or-health-not-ready\"; sleep 1; done; curl -fsS http://127.0.0.1:3001/api/health >/dev/null 2>&1 || { echo 'ERROR public Grafana did not become locally healthy; inspect /srv/dai/edge/start-public-grafana.log' >&2; exit 1; }; docker compose up -d --force-recreate caddy"
}

deploy_gateway_admission() {
  local node="$PUBLIC_EDGE_NODE" admission_env admission_remote expected_sha remote_sha status_bearer_token
  admission_env="$GENERATED/edge/gateway-admission.env"
  admission_remote="${REMOTE}-gateway-admission"
  mkdir -p "$(dirname "$admission_env")"
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$INVENTORY" --node-name "$node" --output "$admission_env" >/dev/null
  status_bearer_token="$(<"$SECRETS/gateway.admission-observer-key")"
  [[ "$status_bearer_token" =~ ^[A-Za-z0-9._:-]{16,256}$ ]] \
    || die 'gateway admission status credential is missing or invalid'
  printf 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=%s\n' "$status_bearer_token" >>"$admission_env"
  chmod 0600 "$admission_env"
  expected_sha="$(sha256sum "$admission_env" | awk '{print $1}')"
  ssh "$node" "rm -rf '$admission_remote' && mkdir -p '$admission_remote'"
  rsync -a "$ROOT/04-ops/edge-node/" "$node:$admission_remote/edge/"
  scp -q "$admission_env" "$node:$admission_remote/gateway-admission.env"
  remote_sha="$(ssh -T "$node" "set -Eeuo pipefail
    sudo '$admission_remote/edge/install-gateway-admission.sh' '$admission_remote/gateway-admission.env' >/dev/null
    rm -rf '$admission_remote'
    cd /srv/dai/edge
    sudo sha256sum gateway-admission.env | awk '{print \$1}'")"
  [[ "$remote_sha" == "$expected_sha" ]] \
    || die "gateway admission environment differs after deployment: expected=$expected_sha actual=${remote_sha:-unavailable}"
  ssh -T "$node" "set -Eeuo pipefail
    cd /srv/dai/edge
    cleanup_failed_admission() {
      rc=\$?
      if (( rc != 0 )); then
        docker compose stop gateway-admission >/srv/dai/stop-gateway-admission.log 2>&1 || true
      fi
      exit \"\$rc\"
    }
    trap cleanup_failed_admission EXIT
    [[ \"\$(sudo sha256sum gateway-admission.env | awk '{print \$1}')\" == '$expected_sha' ]]
    set -a; . ./gateway-admission.env; set +a
    curl -fsS --connect-timeout 5 --max-time 15 \"\$GDC_GATEWAY_ADMISSION_STATUS_URL\" \
      -H \"Authorization: Bearer \$GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN\" \
      | jq -e '.capacity.models | type == \"object\"' >/dev/null
    docker compose up -d --force-recreate gateway-admission >start-gateway-admission.log 2>&1
    [[ -n \"\$(docker compose ps --status running -q gateway-admission)\" ]]
    trap - EXIT"
  printf 'READY gateway admission contract deployed from the selected gateway profile\n'
}

suspend_gateway_admission() {
  local remote_script="${REMOTE}-suspend-gateway-admission.sh"
  scp -q "$ROOT/04-ops/edge-node/suspend-gateway-admission.sh" \
    "$PUBLIC_EDGE_NODE:$remote_script"
  ssh -T "$PUBLIC_EDGE_NODE" "set -Eeuo pipefail
    sudo '$remote_script'
    rm -f '$remote_script'"
  printf 'READY public gateway admission is fail-closed for runtime replacement\n'
}

GATEWAY_OPTION=''
CADDY_START_COMMAND='docker compose up -d --force-recreate caddy'
POST_START_COMMAND=true
if [[ "$COMPONENT" == edge ]]; then
  step 'Install the public edge configuration without changing chain state'
  reconcile_public_grafana
  if [[ "${GDC_PUBLIC_EDGE_VERIFY:-true}" != true ]]; then
    printf 'READY public edge configuration installed\n'
    exit 0
  fi
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
    step 'Reconcile the bounded DevNet faucet reserve'
    "$ROOT/scripts/ensure-account-balance.sh" "$ACCOUNTS/gdc-faucet-cold.json" "$INVENTORY" "$faucet_initial"
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
    gateway_recipient="$(jq -er .address "$ACCOUNTS/gdc-gateway-cold.json")"
    write_env "$GATEWAY_RESERVE_ENV" \
      "FAUCET_CHAIN_ID=$CHAIN_ID" "FAUCET_GENESIS_SHA256=$faucet_genesis_sha256" \
      'FAUCET_RPC_URL=http://127.0.0.1:26657' 'FAUCET_CHAIN_REST_URL=http://127.0.0.1:1317' \
      'FAUCET_KEY_NAME=gdc-faucet-cold' "FAUCET_KEYRING_PASSWORD=$(<"$SECRETS/operator.keyring")" \
      'FAUCET_AMOUNT_NGONKA=1' 'FAUCET_LISTEN_HOST=127.0.0.1' 'FAUCET_LISTEN_PORT=18083' \
      "FAUCET_GATEWAY_RESERVE_RECIPIENT=$gateway_recipient" "FAUCET_GATEWAY_RESERVE_TOKEN=$(<"$reserve_signer_token")" \
      "FAUCET_GATEWAY_RESERVE_MAX_NGONKA=${GDC_GATEWAY_MAX_REFILL_NGONKA:-500000000000}"
    FAUCET_OPTION="--faucet-env '$REMOTE/rendered/faucet.env' --gateway-reserve-env '$REMOTE/rendered/gateway-reserve-signer.env'"
    START_COMMAND='docker compose --profile gateway-reserve up -d --build --force-recreate faucet gateway-reserve-signer'
    ENDPOINT="https://${GENESIS_PUBLIC_HOST}/faucet/health"
    ;;
  gateway)
    step 'Discard only gateway state whose every escrow is absent from committed chain state'
    "$ROOT/scripts/reset-stale-gateway-state.sh" "$GATEWAY_NODE" "${GDC_CHAIN_API_URL:-https://${PUBLIC_EDGE_HOST}/chain-api}"
    step "Provide the pinned $GDC_GATEWAY_VERSION gateway image on $GATEWAY_NODE"
    "$ROOT/scripts/build-gateway-image.sh" >"$STATE/gateway-image-$GDC_GATEWAY_VERSION.txt"
    step 'Reconcile the gateway creator reserve before escrow reuse or replacement'
    gateway_reserve_temp_count="${GDC_GATEWAY_ROTATION_TEMP_COUNT:-2}"
    gateway_reserve_target_count="${GDC_GATEWAY_ROTATION_TARGET_COUNT:-2}"
    [[ "$gateway_reserve_temp_count" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_ROTATION_TEMP_COUNT must be positive'
    [[ "$gateway_reserve_target_count" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_ROTATION_TARGET_COUNT must be positive'
    gateway_live_min_amount="$("$ROOT/scripts/inferenced.sh" query inference params \
      --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" --chain-id "$CHAIN_ID" --output json \
      | jq -er '(.params // .).devshard_escrow_params.min_amount')"
    gateway_rotation_amount="${GDC_GATEWAY_ESCROW_AMOUNT_NGONKA:-$gateway_live_min_amount}"
    [[ "$gateway_rotation_amount" =~ ^[1-9][0-9]*$ ]] || die 'gateway rotation escrow amount must be positive'
    gateway_funding_horizon="${GDC_GATEWAY_FUNDING_HORIZON_ROTATIONS:-1}"
    gateway_fee_reserve="${GDC_GATEWAY_FEE_RESERVE_NGONKA:-1000000}"
    gateway_requested_max_refill="${GDC_GATEWAY_MAX_REFILL_NGONKA:-}"
    gateway_funding_source_target="${GDC_FAUCET_INITIAL_NGONKA:-5000000000000}"
    [[ "$gateway_funding_horizon" =~ ^[0-9]+$ ]] || die 'GDC_GATEWAY_FUNDING_HORIZON_ROTATIONS must be a non-negative integer'
    [[ "$gateway_fee_reserve" =~ ^[0-9]+$ ]] || die 'GDC_GATEWAY_FEE_RESERVE_NGONKA must be a non-negative integer'
    if ! is_safe_integer "$gateway_funding_source_target" || [[ "$gateway_funding_source_target" == 0 ]]; then
      die 'GDC_FAUCET_INITIAL_NGONKA must be a positive safe integer'
    fi
    gateway_max_refill="$(
      ssh "$GATEWAY_NODE" \
        "sudo sed -n 's/^FAUCET_GATEWAY_RESERVE_MAX_NGONKA=//p' /srv/dai/ops/gateway-reserve-signer.env"
    )" || die 'deployed gateway reserve signer maximum is unavailable on the gateway node'
    if ! is_safe_integer "$gateway_max_refill" || [[ "$gateway_max_refill" == 0 ]]; then
      die 'deployed gateway reserve signer maximum must be exactly one positive safe integer'
    fi
    if [[ -n "$gateway_requested_max_refill" && "$gateway_requested_max_refill" != "$gateway_max_refill" ]]; then
      die 'GDC_GATEWAY_MAX_REFILL_NGONKA does not match the deployed gateway reserve signer maximum'
    fi
    export GDC_GATEWAY_MAX_REFILL_NGONKA="$gateway_max_refill"
    gateway_faucet_claim_amount="$(
      ssh "$GATEWAY_NODE" \
        "sudo sed -n 's/^FAUCET_AMOUNT_NGONKA=//p' /srv/dai/ops/faucet.env"
    )" || die 'deployed faucet claim amount is unavailable on the gateway node'
    if ! is_safe_integer "$gateway_faucet_claim_amount" || [[ "$gateway_faucet_claim_amount" == 0 ]]; then
      die 'deployed faucet claim amount must be exactly one positive safe integer'
    fi
    (( gateway_max_refill < gateway_funding_source_target )) \
      || die 'GDC_GATEWAY_MAX_REFILL_NGONKA must be below GDC_FAUCET_INITIAL_NGONKA'
    # The funding source is also the active public faucet. Permit one bounded
    # max-refill window of normal drift from its configured target, but retain
    # enough for a later maximum reserve refill plus one concurrent full claim.
    gateway_funding_source_minimum="$((gateway_funding_source_target - gateway_max_refill))"
    (( gateway_funding_source_minimum >= gateway_max_refill )) \
      || die 'gateway funding source must retain two maximum reserve refills'
    (( gateway_faucet_claim_amount <= gateway_funding_source_minimum - gateway_max_refill )) \
      || die 'gateway funding source must retain one faucet claim above the maximum reserve refill'
    step 'Reconcile the gateway reserve funding source'
    "$ROOT/scripts/ensure-account-balance.sh" \
      "$ACCOUNTS/gdc-faucet-cold.json" "$INVENTORY" \
      "$gateway_funding_source_target" "$gateway_funding_source_minimum"
    "$ROOT/04-ops/ensure-gateway-reserve.sh" \
      "$INVENTORY" "$ACCOUNTS/gdc-gateway-cold.json" "$gateway_live_min_amount" "$gateway_rotation_amount" \
      "$gateway_reserve_temp_count" "$gateway_reserve_target_count" "$gateway_funding_horizon" "$gateway_fee_reserve" \
      0 0 "$gateway_max_refill"
    # Re-running `ops gateway` may reuse an escrow only for the same bound
    # protocol. A Host persists the protocol binding per escrow and rejects a
    # later request that presents the same escrow through another route. The
    # deployed runtime is authoritative because the reconciler can rotate the
    # rendered ID while this command is not running.
    if [[ -n "${GDC_ESCROW_ID:-}" ]]; then
      configured_escrow="$(awk -F= '$1 == "DEVSHARD_ESCROW_ID" { print $2; exit }' "$GATEWAY_ENV" 2>/dev/null || true)"
      configured_route="$(awk -F= '$1 == "DEVSHARD_ROUTE_PREFIX" { print $2; exit }' "$GATEWAY_ENV" 2>/dev/null || true)"
      [[ "$GDC_ESCROW_ID" == "$configured_escrow" && "$configured_route" == "/devshard/$GDC_GATEWAY_VERSION" ]] \
        || die 'GDC_ESCROW_ID may reuse only the rendered escrow for the selected DevShard protocol'
    fi
    if [[ -z "${GDC_ESCROW_ID:-}" ]]; then
      gateway_creator="$(jq -er .address "$ACCOUNTS/gdc-gateway-cold.json")"
      active_gateway_state="$(ssh -T "$GATEWAY_NODE" 'set -Eeuo pipefail
        [[ -r /srv/dai/ops/gateway.env ]] || exit 0
        set -a; . /srv/dai/ops/gateway.env; set +a
        curl -fsS http://127.0.0.1:18080/v1/admin/devshards \
          -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY"' 2>/dev/null || true)"
      active_gateway_escrows="$(printf '%s\n' "$active_gateway_state" \
        | "$ROOT/scripts/select-compatible-gateway-escrows.sh" "$GDC_GATEWAY_VERSION" 2>/dev/null || true)"
      active_gateway_escrow=''
      while IFS= read -r candidate; do
        [[ "$candidate" =~ ^[1-9][0-9]*$ ]] || continue
        candidate_state="$("$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$candidate" \
          --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" --chain-id "$CHAIN_ID" --output json 2>/dev/null || true)"
        if jq -e --arg creator "$gateway_creator" --arg model "$MODEL_ID" '
          .found == true
          and .escrow.creator == $creator
          and .escrow.model_id == $model
          and ((.escrow.settled // false) == false)
        ' <<<"$candidate_state" >/dev/null 2>&1; then
          active_gateway_escrow="$candidate"
          break
        fi
      done <<<"$active_gateway_escrows"
      if [[ -n "$active_gateway_escrow" ]]; then
        export GDC_ESCROW_ID="$active_gateway_escrow"
        printf 'READY reuse active %s gateway escrow %s from deployed runtime\n' "$GDC_GATEWAY_VERSION" "$GDC_ESCROW_ID"
      elif [[ -s "$GATEWAY_ENV" ]]; then
        previous_escrow="$(awk -F= '$1 == "DEVSHARD_ESCROW_ID" { print $2; exit }' "$GATEWAY_ENV")"
        previous_route="$(awk -F= '$1 == "DEVSHARD_ROUTE_PREFIX" { print $2; exit }' "$GATEWAY_ENV")"
        if [[ "$previous_escrow" =~ ^[1-9][0-9]*$ && "$previous_route" != "/devshard/$GDC_GATEWAY_VERSION" ]]; then
          printf 'READY discard gateway escrow %s bound to incompatible route %s\n' "$previous_escrow" "${previous_route:-unavailable}"
        elif [[ "$previous_escrow" =~ ^[1-9][0-9]*$ ]]; then
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
    write_env "$GATEWAY_OBSERVER_ENV" \
      "DEVSHARD_ADMIN_API_KEY=$(<"$SECRETS/gateway.admin-key")" \
      "GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN=$(<"$SECRETS/gateway.admission-observer-key")" \
      'GDC_GATEWAY_ADMIN_STATE_URL=http://127.0.0.1:18080/v1/admin/devshards'
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
    gateway_ingress_timeout="${GDC_GATEWAY_INGRESS_TIMEOUT_SECONDS:-300}"
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
    [[ "$gateway_ingress_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_GATEWAY_INGRESS_TIMEOUT_SECONDS must be positive'
    GATEWAY_OPTION="--gateway-env '$REMOTE/rendered/gateway.env' --gateway-observer-env '$REMOTE/rendered/gateway-admission-observer.env'"
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
    START_COMMAND="docker compose up -d --force-recreate caddy; deadline=\$((SECONDS + $gateway_ingress_timeout)); while (( SECONDS < deadline )); do curl -fsS --connect-timeout 3 --max-time 10 'https://$gateway_ingress_host/health' >/dev/null && break; sleep 2; done; curl -fsS --connect-timeout 3 --max-time 10 'https://$gateway_ingress_host/health' >/dev/null; docker compose --env-file .env --env-file gateway.env up -d --force-recreate devshard-gateway; [[ -n \"\$(docker compose --env-file .env --env-file gateway.env ps --status running -q devshard-gateway)\" ]]"
    CADDY_START_COMMAND=true
    POST_START_COMMAND='sudo systemctl enable --now gdc-gateway-admission-observer.service >/dev/null && sudo systemctl restart gdc-gateway-admission-observer.service && sudo systemctl enable --now gdc-gateway-escrow-reconciler.timer >/dev/null && sudo systemctl start gdc-gateway-escrow-reconciler.service'
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
    # The compiled source contains placeholder values. Replace it with the
    # rendered deployment configuration before publishing identical assets to
    # the gateway host and the independent public edge.
    install -m 0644 "$OPS_RENDER/config.js" "$SITE_ASSETS_RENDER/config.js"
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
scp -q "$ROOT/scripts/gateway-reserve-policy.sh" "$GATEWAY_NODE:$REMOTE/04-ops/gateway-reserve-policy.sh"
[[ -z "${SITE_ASSETS_RENDER:-}" ]] || rsync -a --delete "$SITE_ASSETS_RENDER/" "$GATEWAY_NODE:$REMOTE/04-ops/site/"
rsync -a "$OPS_RENDER/" "$GATEWAY_NODE:$REMOTE/rendered/"
if [[ -n "$FAUCET_SIGNER_HOME" ]]; then
  rsync -a "$FAUCET_SIGNER_HOME/" "$GATEWAY_NODE:$REMOTE/faucet-signer/"
fi
if [[ "$COMPONENT" == gateway ]]; then
  step "Revalidate the exact $GDC_GATEWAY_VERSION approval at the activation boundary"
  "$ROOT/scripts/inferenced.sh" query inference params \
    --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" --chain-id "$CHAIN_ID" --output json \
    >"$gateway_approved_params"
  "$ROOT/scripts/verify-approved-devshard-version.sh" \
    "$gateway_approved_params" "$GDC_GATEWAY_VERSION" "$gateway_archive_url" "$gateway_archive_sha"
  step 'Suspend public admission before replacing the gateway runtime'
  suspend_gateway_admission
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
    cd /srv/dai/ops && $START_COMMAND && $CADDY_START_COMMAND && $POST_START_COMMAND
  } >/srv/dai/ops/start-$COMPONENT.log 2>&1"; then
  printf 'READY %s endpoint %s\n' "$COMPONENT" "$ENDPOINT"
else
  ssh "$GATEWAY_NODE" "tail -100 /srv/dai/ops/start-$COMPONENT.log" >&2 || true
  exit 1
fi

if [[ "$COMPONENT" == faucet ]]; then
  step 'Verify the public DevNet faucet route'
  faucet_ready=false
  faucet_attempts="${GDC_FAUCET_PUBLIC_READY_ATTEMPTS:-12}"
  for faucet_attempt in $(seq 1 "$faucet_attempts"); do
    faucet_response="$(mktemp)"
    faucet_stderr="$(mktemp)"
    set +e
    faucet_http_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$faucet_response" -w '%{http_code}' "$ENDPOINT" 2>"$faucet_stderr")"
    faucet_curl_exit=$?
    set -e
    if [[ "$faucet_curl_exit" == 0 && "$faucet_http_status" == 200 ]]; then
      if jq -e '.status == "ok"' "$faucet_response" >/dev/null; then
        rm -f "$faucet_response" "$faucet_stderr"
        faucet_ready=true
        printf 'PASS public DevNet faucet: %s\n' "$ENDPOINT"
        break
      fi
      content_type="$(file -b --mime-type "$faucet_response" 2>/dev/null || printf unknown)"
      rm -f "$faucet_response" "$faucet_stderr"
      die "public DevNet faucet returned HTTP 200 with an invalid health payload: url=$ENDPOINT content_type=$content_type"
    fi
    faucet_detail="$(tr '\n' ' ' <"$faucet_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    rm -f "$faucet_response" "$faucet_stderr"
    printf 'WAIT public DevNet faucet unavailable attempt=%s/%s url=%s http_status=%s curl_exit=%s curl_status=%s%s\n' \
      "$faucet_attempt" "$faucet_attempts" "$ENDPOINT" "${faucet_http_status:-000}" "$faucet_curl_exit" "$(curl_exit_status "$faucet_curl_exit")" "${faucet_detail:+ detail=$faucet_detail}"
    sleep 2
  done
  "$faucet_ready" || die "public DevNet faucet did not become ready after $faucet_attempts attempts: url=$ENDPOINT"
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
        | jq -e "(.devshards // [.]) | any((.active // true) == true and (.runtime.phase // .phase // \"\") == \"active\" and (.runtime.requests_blocked // .requests_blocked // false) == false and (.runtime.chain_phase // .chain_phase // \"\") == \"Inference\")" >/dev/null
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
  step 'Verify the sanitized read-only admission observer'
  observer_token="$(<"$SECRETS/gateway.admission-observer-key")"
  observer_url="https://$(node_public_host "$GATEWAY_NODE")/ops-gateway-admission-state"
  curl -fsS --connect-timeout 5 --max-time 15 "$observer_url" \
    -H "Authorization: Bearer $observer_token" \
    | jq -e --arg protocol "$GDC_GATEWAY_VERSION" '
        (.capacity.models // {}) as $models
        | any($models[]?; ((.current_weight // .total_weight // 0) | tonumber) > 0)
        and any(.devshards[]?;
          .active == true
          and .protocol_version == $protocol
          and .runtime.session_version == $protocol
          and .runtime.phase == "active"
          and .runtime.chain_phase == "Inference"
          and .runtime.requests_blocked == false)
      ' >/dev/null \
    || die "gateway admission observer does not expose the selected live protocol with positive capacity: url=$observer_url"
  step 'Deploy the matching public admission contract'
  deploy_gateway_admission
  ssh "$GATEWAY_NODE" 'test "$(stat -c %a /srv/dai/ops/gateway.env)" = 600'
  admin_key="$(<"$SECRETS/gateway.admin-key")"
  client_key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
  unauth_status="$(curl -sk -o /dev/null -w '%{http_code}' "$GDC_GATEWAY_PUBLIC_URL/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"health"}]}')"
  [[ "$unauth_status" == 401 ]] || die "unauthenticated gateway request returned $unauth_status, expected 401"
  curl -fsS "$GDC_GATEWAY_PUBLIC_URL/v1/status" -H "Authorization: Bearer $client_key" \
    | jq -e '
        ([.devshards[]?
          | select(.active == true and (.runtime.phase // .phase // "") == "active" and (.runtime.requests_blocked // .requests_blocked // false) == false)
          | .id]
         + [if (.runtime.phase // .phase // "") == "active" and (.runtime.requests_blocked // .requests_blocked // false) == false then .escrow_id? else empty end])
        | any(. != null and (tostring | test("^[1-9][0-9]*$")))
      ' >/dev/null
  # Gateway status is a local runtime view.  Prove that its selected escrow
  # still exists in committed chain state before reporting the gateway ready.
  active_escrow="$(curl -fsS "$GDC_GATEWAY_PUBLIC_URL/v1/status" -H "Authorization: Bearer $client_key" \
    | jq -er '
        ([.devshards[]?
          | select(.active == true and (.runtime.phase // .phase // "") == "active" and (.runtime.requests_blocked // .requests_blocked // false) == false)
          | .id]
         + [if (.runtime.phase // .phase // "") == "active" and (.runtime.requests_blocked // .requests_blocked // false) == false then .escrow_id? else empty end])
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
  step 'Publish the static status site on the public edge'
  site_remote="${REMOTE}-public-site"
  ssh "$PUBLIC_EDGE_NODE" "rm -rf '$site_remote' && mkdir -p '$site_remote/site'"
  rsync -a --delete "$SITE_ASSETS_RENDER/" "$PUBLIC_EDGE_NODE:$site_remote/site/"
  ssh -T "$PUBLIC_EDGE_NODE" "set -Eeuo pipefail
    sudo install -d -m 0755 /srv/dai/edge/site
    sudo rsync -a --delete --exclude preview/ '$site_remote/site/' /srv/dai/edge/site/
    rm -rf '$site_remote'
    cd /srv/dai/edge
    if [[ \"${GDC_SITE_KEEP_CADDY:-false}\" == true ]]; then
      docker compose ps -q caddy | grep -q . || { echo 'ERROR public Caddy is not running while reset requests listener preservation' >&2; exit 1; }
    else
      docker compose up -d --force-recreate caddy >/srv/dai/edge/start-site.log 2>&1
    fi"
  printf 'READY static status site published on %s\n' "$PUBLIC_EDGE_NODE"
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
    if GDC_SITE_RENDERED_ASSETS="$SITE_ASSETS_RENDER" "$ROOT/scripts/verify-public-homepage.sh"; then
      verified=true
      break
    fi
    printf 'WAIT  complete public homepage contract after site restart\n'
    sleep 3
  done
  [[ "$verified" == true ]] || die 'public homepage contract did not become stable after site restart'
fi
