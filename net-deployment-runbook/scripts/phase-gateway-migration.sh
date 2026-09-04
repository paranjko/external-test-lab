#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
target_version="${2:-}"
action_argument="${2:-}"
migration_state="$STATE/gateway-migrations/active.env"

load_migration_state() {
  [[ -f "$migration_state" && ! -L "$migration_state" ]] || die 'no retained gateway migration exists'
  # shellcheck disable=SC1090
  source "$migration_state"
  [[ "${schema_version:-}" == 1 && "${remote_dir:-}" == /srv/dai/ops/gateway-migrations/* \
    && "${phase:-}" =~ ^(preparing|prepared|cutover_pending|cutover|drained|promoting|rolled_back|completed|failed)$ \
    && "${source_version:-}" =~ ^v[345]$ && "${target_version:-}" =~ ^v[45]$ \
    && "$source_version" != "$target_version" \
    && "${source_port:-}" =~ ^[1-9][0-9]{0,4}$ && "${target_port:-}" =~ ^[1-9][0-9]{0,4}$ \
    && "$source_port" != "$target_port" \
    && ( "${target_escrow_id:-}" =~ ^[1-9][0-9]*$ \
      || ( "${target_escrow_id:-}" == pending && "${phase:-}" =~ ^(preparing|failed)$ ) ) \
    && "${target_project:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || die 'retained gateway migration state is invalid'
  remote_helper="$remote_dir/04-ops/gateway-migration-remote.sh"
}

remote_phase() {
  ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' status '$remote_dir'" | jq -er .phase
}

suspend_and_verify_admission() {
  step 'Suspend and verify public admission before changing the gateway route'
  ssh -T "$PUBLIC_EDGE_NODE" 'set -Eeuo pipefail
    cd /srv/dai/edge
    docker compose stop gateway-admission >/srv/dai/edge/suspend-gateway-migration.log 2>&1
    running="$(docker compose ps --status running -q gateway-admission)"
    [[ -z "$running" ]] || {
      echo "ERROR public gateway admission remains running after stop" >&2
      exit 1
    }'
}

wait_public_gateway_routable() {
  local client_key="$1" role="$2" timeout deadline attempt=0 response stderr_file http_status curl_rc
  timeout="${GDC_GATEWAY_MIGRATION_READY_TIMEOUT_SECONDS:-600}"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die 'gateway migration readiness timeout must be a positive integer'
  deadline=$((SECONDS + timeout))
  response="$(mktemp)"
  stderr_file="$(mktemp)"
  while (( SECONDS < deadline )); do
    set +e
    http_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$response" -w '%{http_code}' \
      "https://$API_HOST/v1/status" -H "Authorization: Bearer $client_key" 2>"$stderr_file")"
    curl_rc=$?
    set -e
    if (( curl_rc == 0 )) && [[ "$http_status" == 200 ]] \
      && "$ROOT/04-ops/gateway-status-routable.sh" <"$response" >/dev/null 2>&1; then
      rm -f "$response" "$stderr_file"
      printf 'PASS public gateway is routable role=%s\n' "$role"
      return 0
    fi
    (( attempt += 1 ))
    if (( attempt == 1 || attempt % 5 == 0 )); then
      printf 'WAIT public gateway is not routable role=%s http_status=%s curl_exit=%s curl_status=%s\n' \
        "$role" "${http_status:-000}" "$curl_rc" "$(curl_exit_status "$curl_rc")"
    fi
    sleep 3
  done
  rm -f "$response" "$stderr_file"
  echo "ERROR public gateway did not become routable within ${timeout}s role=$role" >&2
  return 1
}

wait_cutover_window() {
  local timeout runway
  timeout="${GDC_GATEWAY_MIGRATION_WINDOW_TIMEOUT_SECONDS:-600}"
  runway="${GDC_GATEWAY_MIGRATION_CUTOVER_RUNWAY_BLOCKS:-30}"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] \
    || die 'gateway migration window timeout must be a positive integer'
  [[ "$runway" =~ ^[1-9][0-9]*$ ]] \
    || die 'gateway migration cutover runway must be a positive integer'
  step 'Wait for an Inference window before changing the public gateway route'
  ssh -T "$GATEWAY_NODE" \
    "sudo env GDC_GATEWAY_MIGRATION_MIN_RUNWAY_BLOCKS='$runway' \
      '$remote_helper' preflight-window '$timeout'"
}

archive_completed_migration_state() {
  local migration_id archive_root archive_dir archive_path
  migration_id="${remote_dir##*/}"
  archive_root="$STATE/gateway-migrations/completed"
  archive_dir="$archive_root/$migration_id"
  archive_path="$archive_dir/active.env"
  mkdir -p "$archive_root"
  [[ ! -e "$archive_dir" && ! -L "$archive_dir" ]] \
    || die "completed gateway migration archive already exists path=$archive_dir"
  mkdir "$archive_dir" \
    || die "cannot reserve completed gateway migration archive path=$archive_dir"
  [[ ! -e "$archive_path" && ! -L "$archive_path" ]] \
    || die "completed gateway migration archive is not empty path=$archive_path"
  cp --preserve=mode,timestamps -- "$migration_state" "$archive_path" \
    || die "cannot archive completed gateway migration state path=$archive_path"
  cmp -s "$migration_state" "$archive_path" \
    || die "completed gateway migration archive differs from active state path=$archive_path"
  rm -- "$migration_state"
  printf 'ARCHIVED completed gateway migration state path=%s\n' "$archive_path"
}

refresh_target_before_cutover() {
  step 'Refresh and prove the target gateway immediately before cutover'
  ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' refresh-target '$remote_dir'"
}

install_route() (
  local port="$1" role="$2" failure_mode="${3:-rollback}"
  local route_dir observer_env edge_env remote token expected_sha remote_sha client_key route_version gateway_host
  local migration_status role_binary_sha chain_params chain_params_stderr chain_params_http chain_params_rc
  local role_protocol_url role_protocol_contract chain_api_base
  local observer_backup edge_backup_ready=false observer_backup_ready=false route_committed=false
  if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    die 'gateway route port is invalid'
  fi
  [[ "$failure_mode" =~ ^(rollback|fail-closed)$ ]] || die 'gateway route failure mode is invalid'
  case "$role" in
    source) route_version="$source_version" ;;
    target) route_version="$target_version" ;;
    *) die 'gateway route role is invalid' ;;
  esac
  gateway_host="$(node_public_host "$GATEWAY_NODE")"
  route_dir="$GDC_HOME/runs/${GDC_RUN_ID:?}/gateway-migration-route-$role"
  observer_env="$route_dir/gateway-admission-observer.env"
  edge_env="$route_dir/gateway-admission.env"
  remote="/tmp/gdc-gateway-route-$$"
  observer_backup="/tmp/gdc-gateway-observer-backup-$$.env"
  mkdir -p "$route_dir"
  migration_status="$(ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' status '$remote_dir'")" \
    || die "cannot read retained gateway identities before route switch role=$role"
  role_binary_sha="$(jq -er --arg role "$role" '.images[$role].binary_sha256
    | select(type == "string" and test("^[0-9a-f]{64}$"))' <<<"$migration_status")" \
    || die "retained gateway binary identity is unavailable role=$role"
  chain_api_base="${GDC_CHAIN_API_URL:-https://${PUBLIC_EDGE_HOST}/chain-api}"
  chain_params="$route_dir/inference-params.json"
  chain_params_stderr="$route_dir/inference-params.curl.stderr"
  set +e
  chain_params_http="$(curl -sS --connect-timeout 5 --max-time 20 -o "$chain_params" -w '%{http_code}' \
    "${chain_api_base%/}/productscience/inference/inference/params" 2>"$chain_params_stderr")"
  chain_params_rc=$?
  set -e
  if (( chain_params_rc != 0 )) || [[ "$chain_params_http" != 200 ]]; then
    die "cannot read approved DevShard contracts before route switch role=$role url=${chain_api_base%/}/productscience/inference/inference/params http_status=${chain_params_http:-000} curl_exit=$chain_params_rc curl_status=$(curl_exit_status "$chain_params_rc")"
  fi
  role_protocol_url="$(jq -er --arg version "$route_version" --arg sha "$role_binary_sha" '
    [.params.devshard_escrow_params.approved_versions[]?
      | select(.name == $version and .sha256 == $sha)]
    | if length == 1 then .[0].binary
      | select(type == "string" and test("^https://"))
      else error("missing or ambiguous protocol") end
  ' "$chain_params")" \
    || die "gateway runtime does not match one unique approved protocol role=$role version=$route_version sha256=$role_binary_sha"
  "$ROOT/scripts/verify-approved-devshard-version.sh" \
    "$chain_params" "$route_version" "$role_protocol_url" "$role_binary_sha" >/dev/null \
    || die "gateway runtime protocol is not approved role=$role version=$route_version"
  role_protocol_contract="$(jq -cnS \
    --arg version "$route_version" --arg binary "$role_protocol_url" --arg sha256 "$role_binary_sha" \
    '{($version):{binary:$binary,sha256:$sha256}}')"
  token="$(<"$SECRETS/gateway.admission-observer-key")"
  [[ "$token" =~ ^[A-Za-z0-9._:-]{16,256}$ ]] || die 'gateway observer credential is invalid'
  write_env "$observer_env" \
    "DEVSHARD_ADMIN_API_KEY=$(<"$SECRETS/gateway.admin-key")" \
    "GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN=$token" \
    "GDC_GATEWAY_ADMIN_STATE_URL=http://127.0.0.1:$port/v1/admin/state"
  GDC_GATEWAY_VERSION="$route_version" \
    GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON_OVERRIDE="$role_protocol_contract" \
    GDC_GATEWAY_ADMISSION_UPSTREAM_PORT="$port" \
    "$ROOT/04-ops/edge-node/render-env.sh" \
      --inventory "$INVENTORY" --node-name "$PUBLIC_EDGE_NODE" --output "$edge_env" >/dev/null
  printf 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=%s\n' "$token" >>"$edge_env"
  chmod 0600 "$observer_env" "$edge_env"
  expected_sha="$(sha256sum "$edge_env" | awk '{print $1}')"

  # Invoked only by the EXIT trap below.
  # shellcheck disable=SC2317
  rollback_route() {
    local rc=$?
    local observer_url upstream_url observer_port upstream_port
    local recovery_failed=false admission_stopped=false
    if (( rc != 0 )) && [[ "$route_committed" != true ]]; then
      if suspend_and_verify_admission; then
        admission_stopped=true
      else
        recovery_failed=true
        echo "ERROR public gateway admission shutdown could not be proven; route recovery was not attempted role=$role" >&2
      fi
      if [[ "$admission_stopped" == true && "$failure_mode" == rollback ]]; then
        if [[ "$observer_backup_ready" != true ]] || ! ssh -T "$GATEWAY_NODE" "set -Eeuo pipefail
          sudo install -m 0600 '$observer_backup' /srv/dai/ops/gateway-admission-observer.env
          sudo systemctl restart gdc-gateway-admission-observer.service" >/dev/null 2>&1; then
          recovery_failed=true
          echo "ERROR previous gateway observer could not be restored role=$role" >&2
        fi
        if [[ "$edge_backup_ready" != true ]] || ! ssh -T "$PUBLIC_EDGE_NODE" "set -Eeuo pipefail
          sudo cp -a '$remote/backup/.' /srv/dai/edge/
          cd /srv/dai/edge
          docker compose up -d --force-recreate caddy \
            >/srv/dai/edge/rollback-gateway-route.log 2>&1" >/dev/null 2>&1; then
          recovery_failed=true
          echo "ERROR previous public gateway route could not be restored role=$role" >&2
        fi
        if [[ "$recovery_failed" != true ]]; then
          observer_url="$(ssh -T "$GATEWAY_NODE" \
            "sudo awk -F= '\$1 == \"GDC_GATEWAY_ADMIN_STATE_URL\" {print substr(\$0, index(\$0, \"=\") + 1)}' /srv/dai/ops/gateway-admission-observer.env")" \
            || recovery_failed=true
          upstream_url="$(ssh -T "$PUBLIC_EDGE_NODE" \
            "sudo awk -F= '\$1 == \"GDC_GATEWAY_ADMISSION_UPSTREAM\" {print substr(\$0, index(\$0, \"=\") + 1)}' /srv/dai/edge/gateway-admission.env")" \
            || recovery_failed=true
          if [[ "$recovery_failed" != true ]]; then
            if [[ "$observer_url" =~ ^http://127\.0\.0\.1:([1-9][0-9]{0,4})/v1/admin/(state|devshards)$ ]]; then
              observer_port="${BASH_REMATCH[1]}"
            else
              recovery_failed=true
            fi
            if [[ "$upstream_url" =~ ^http://[^/:]+:([1-9][0-9]{0,4})$ ]]; then
              upstream_port="${BASH_REMATCH[1]}"
            else
              recovery_failed=true
            fi
            if [[ "$recovery_failed" != true && "$observer_port" != "$upstream_port" ]]; then
              recovery_failed=true
            fi
          fi
          if [[ "$recovery_failed" == true ]]; then
            echo "ERROR restored gateway observer and public upstream identities do not match role=$role" >&2
          fi
        fi
        if [[ "$recovery_failed" != true ]]; then
          if ! ssh -T "$PUBLIC_EDGE_NODE" 'set -Eeuo pipefail
            cd /srv/dai/edge
            docker compose up -d --force-recreate gateway-admission \
              >/srv/dai/edge/restart-gateway-admission-after-rollback.log 2>&1
            running="$(docker compose ps --status running -q gateway-admission)"
            [[ -n "$running" ]]'; then
            recovery_failed=true
            echo "ERROR restored public gateway admission did not start role=$role" >&2
          fi
        fi
      fi
      if [[ "$admission_stopped" == true && "$failure_mode" == fail-closed ]]; then
        echo "ERROR public gateway route switch failed; admission is verified stopped role=$role" >&2
      elif [[ "$admission_stopped" == true && "$recovery_failed" == true ]]; then
        echo "ERROR public gateway route recovery is incomplete; admission was not restarted role=$role" >&2
      elif [[ "$admission_stopped" == true ]]; then
        echo "ERROR public gateway route switch failed; previous observer and upstream were restored before admission restart role=$role" >&2
      fi
    fi
    ssh -T "$PUBLIC_EDGE_NODE" "sudo rm -rf '$remote'" >/dev/null 2>&1 || true
    ssh -T "$GATEWAY_NODE" "sudo rm -f '$observer_backup' '$remote-observer.env'" >/dev/null 2>&1 || true
    exit "$rc"
  }
  trap rollback_route EXIT

  step "Verify the public edge can reach the $role gateway"
  if ! ssh -T "$PUBLIC_EDGE_NODE" "set -Eeuo pipefail
    curl -sS --connect-timeout 3 --max-time 8 'http://$gateway_host:$port/v1/status' \
      | jq -e 'type == \"object\"' >/dev/null"; then
    die "public edge cannot reach gateway role=$role host=$gateway_host port=$port; apply the current gateway Host firewall policy"
  fi

  step "Stage a reversible public route change for the $role gateway"
  ssh "$PUBLIC_EDGE_NODE" "rm -rf '$remote' && mkdir -p '$remote/backup'"
  rsync -a "$ROOT/04-ops/edge-node/" "$PUBLIC_EDGE_NODE:$remote/edge/"
  scp -q "$edge_env" "$PUBLIC_EDGE_NODE:$remote/edge.env"
  ssh -T "$PUBLIC_EDGE_NODE" "set -Eeuo pipefail
    for name in .env compose.yaml Caddyfile gateway-admission.env gateway-admission-proxy.py; do
      sudo test -f \"/srv/dai/edge/\$name\"
      sudo cp -a \"/srv/dai/edge/\$name\" '$remote/backup/'
    done"
  edge_backup_ready=true
  ssh -T "$GATEWAY_NODE" "set -Eeuo pipefail
    sudo test -f /srv/dai/ops/gateway-admission-observer.env
    sudo cp -a /srv/dai/ops/gateway-admission-observer.env '$observer_backup'"
  observer_backup_ready=true

  suspend_and_verify_admission

  step "Bind the admission observer to the $role gateway"
  scp -q "$observer_env" "$GATEWAY_NODE:$remote-observer.env"
  ssh -T "$GATEWAY_NODE" "set -Eeuo pipefail
    sudo install -m 0600 '$remote-observer.env' /srv/dai/ops/gateway-admission-observer.env
    rm -f '$remote-observer.env'
    sudo systemctl restart gdc-gateway-admission-observer.service"
  printf 'GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN=%s\n' "$token" \
    | ssh -T "$GATEWAY_NODE" 'set -Eeuo pipefail
        set -a; . /dev/stdin; set +a
        curl -fsS --connect-timeout 3 --max-time 15 http://127.0.0.1:18084/v1/status \
          -H "Authorization: Bearer $GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN" \
          | jq -e ".capacity.models | type == \"object\"" >/dev/null'

  step "Switch the public gateway route to the $role runtime"
  remote_sha="$(ssh -T "$PUBLIC_EDGE_NODE" "set -Eeuo pipefail
    sudo '$remote/edge/install-edge.sh' '$remote/edge.env' >/dev/null
    sudo '$remote/edge/install-gateway-admission.sh' '$remote/edge.env' >/dev/null
    cd /srv/dai/edge
    docker compose up -d --force-recreate caddy gateway-admission >/srv/dai/edge/start-gateway-route.log 2>&1
    sudo sha256sum gateway-admission.env | awk '{print \$1}'")"
  [[ "$remote_sha" == "$expected_sha" ]] \
    || die "public gateway route differs after installation role=$role expected=$expected_sha actual=${remote_sha:-unavailable}"

  client_key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
  wait_public_gateway_routable "$client_key" "$role"
  curl -fsS --connect-timeout 5 --max-time 30 "https://$API_HOST/v1/models" \
    -H "Authorization: Bearer $client_key" \
    | jq -e --arg model "$MODEL_ID" '.data | any(.id == $model)' >/dev/null
  GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS=25 \
    "$ROOT/04-ops/test-inference-until-ready.sh" \
      "https://$API_HOST" "$client_key" "$route_dir/inference-smoke" \
      "$route_dir/inference-smoke-completion.json" 300 >/dev/null
  route_committed=true
  ssh -T "$PUBLIC_EDGE_NODE" "sudo rm -rf '$remote'"
  ssh -T "$GATEWAY_NODE" "sudo rm -f '$observer_backup'"
  trap - EXIT
  printf 'PASS public gateway route switched role=%s port=%s\n' "$role" "$port"
)

case "$action" in
  prepare)
    [[ "$target_version" =~ ^v[45]$ ]] || die 'gateway migration prepare requires target v4 or v5'
    if [[ -s "$migration_state" ]]; then
      requested_target="$target_version"
      load_migration_state
      remote_status=''
      remote_status_rc=0
      remote_status="$(ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' status '$remote_dir'" 2>/dev/null)" \
        || remote_status_rc=$?
      if [[ "$phase" == completed ]]; then
        (( remote_status_rc == 0 )) \
          || die 'completed gateway migration status could not be verified; refusing to rotate retained state'
        [[ "$(jq -r '.phase // empty' <<<"$remote_status" 2>/dev/null || true)" == completed ]] \
          || die 'local completed gateway migration disagrees with remote state; refusing to rotate retained state'
        archive_completed_migration_state
        target_version="$requested_target"
      else
        [[ "$target_version" == "$requested_target" ]] \
          || die "another gateway migration is active target=$target_version requested=$requested_target"
        if (( remote_status_rc != 0 )); then
          remote_manifest_presence="$(ssh -T "$GATEWAY_NODE" \
            "if sudo test -s '$remote_dir/manifest.env'; then printf present; else printf absent; fi")" \
            || die 'retained gateway migration host is unreachable'
          if [[ "$remote_manifest_presence" != absent || "$phase" != preparing ]]; then
            die "retained gateway migration status is unavailable local_phase=$phase remote_manifest=$remote_manifest_presence"
          fi
        fi
        remote_status_phase="$(jq -r '.phase // empty' <<<"$remote_status" 2>/dev/null || true)"
        case "$remote_status_phase" in
          prepared|cutover_pending|cutover|drained)
            printf 'READY matching gateway migration is already retained target=%s phase=%s\n' \
              "$target_version" "$remote_status_phase"
            exit 0
            ;;
          preparing|failed|rolled_back|'')
            printf 'READY resume incomplete gateway migration target=%s phase=%s\n' \
              "$target_version" "${remote_status_phase:-unmaterialized}"
            ;;
          *) die "retained gateway migration is not resumable phase=$remote_status_phase" ;;
        esac
      fi
    fi
    if [[ -s "$migration_state" ]]; then
      # phase-ops creates a unique migration identity for a new cycle. A retry
      # must reuse the exact retained identity rather than deriving another
      # remote directory, Compose project, or data volume.
      export GDC_GATEWAY_MIGRATION_ID="${remote_dir##*/}"
      export GDC_GATEWAY_MIGRATION_TARGET_PROJECT="$target_project"
      export GDC_GATEWAY_MIGRATION_TARGET_PORT="$target_port"
    fi
    export GDC_GATEWAY_VERSION="$target_version"
    export GDC_GATEWAY_MIGRATION_PREPARE=true
    "$ROOT/scripts/phase-ops.sh" gateway
    ;;
  status)
    [[ $# -eq 1 ]] || die 'gateway migration status takes no target version'
    load_migration_state
    ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' status '$remote_dir'"
    ;;
  cutover)
    [[ $# -eq 1 ]] || die 'gateway migration cutover takes no target version'
    load_migration_state
    phase="$(remote_phase)"
    case "$phase" in
      prepared)
        refresh_target_before_cutover
        wait_cutover_window
        ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' mark '$remote_dir' cutover_pending"
        install_route "$target_port" target
        ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' mark '$remote_dir' cutover"
        ;;
      cutover_pending)
        refresh_target_before_cutover
        wait_cutover_window
        install_route "$target_port" target
        ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' mark '$remote_dir' cutover"
        ;;
      cutover|drained) printf 'READY target gateway route was already cut over phase=%s\n' "$phase" ;;
      *) die "gateway migration cannot cut over from phase=$phase" ;;
    esac
    ;;
  drain)
    [[ $# -le 2 ]] || die 'gateway migration drain accepts one optional timeout'
    load_migration_state
    timeout="${action_argument:-900}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die 'gateway migration drain timeout must be a positive integer'
    phase="$(remote_phase)"
    case "$phase" in
      cutover) ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' drain '$remote_dir' '$timeout'" ;;
      drained) printf 'READY source gateway was already drained\n' ;;
      *) die "gateway migration cannot drain source from phase=$phase" ;;
    esac
    ;;
  rollback)
    [[ $# -eq 1 ]] || die 'gateway migration rollback takes no target version'
    load_migration_state
    phase="$(remote_phase)"
    case "$phase" in
      prepared|cutover_pending|cutover|drained|failed|preparing)
        install_route "$source_port" source
        ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' restore-source '$remote_dir'"
        ;;
      promoting)
        suspend_and_verify_admission
        ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' restore-source '$remote_dir'"
        install_route "$source_port" source
        ;;
      rolled_back)
        install_route "$source_port" source
        printf 'READY source gateway route and lifecycle were already restored\n'
        ;;
      *) die "gateway migration cannot roll back from phase=$phase" ;;
    esac
    ;;
  complete)
    [[ $# -eq 1 ]] || die 'gateway migration complete takes no target version'
    load_migration_state
    phase="$(remote_phase)"
    if [[ "$phase" == completed ]]; then
      install_route 18080 target fail-closed
      printf 'READY target gateway promotion was already completed\n'
      exit 0
    fi
    [[ "$phase" =~ ^(drained|promoting)$ ]] || die "gateway migration cannot complete from phase=$phase"
    suspend_and_verify_admission
    ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' promote '$remote_dir'"
    install_route 18080 target fail-closed
    ;;
  *)
    die 'expected gateway migration prepare v4|v5, status, cutover, drain [seconds], rollback, or complete'
    ;;
esac
