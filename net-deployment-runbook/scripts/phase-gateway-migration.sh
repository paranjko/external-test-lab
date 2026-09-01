#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
target_version="${2:-}"
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

install_route() (
  local port="$1" role="$2" failure_mode="${3:-rollback}"
  local route_dir observer_env edge_env remote token expected_sha remote_sha client_key
  local observer_backup edge_backup_ready=false observer_backup_ready=false route_committed=false
  if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    die 'gateway route port is invalid'
  fi
  [[ "$failure_mode" =~ ^(rollback|fail-closed)$ ]] || die 'gateway route failure mode is invalid'
  route_dir="$GDC_HOME/runs/${GDC_RUN_ID:?}/gateway-migration-route-$role"
  observer_env="$route_dir/gateway-admission-observer.env"
  edge_env="$route_dir/gateway-admission.env"
  remote="/tmp/gdc-gateway-route-$$"
  observer_backup="/tmp/gdc-gateway-observer-backup-$$.env"
  mkdir -p "$route_dir"
  token="$(<"$SECRETS/gateway.admission-observer-key")"
  [[ "$token" =~ ^[A-Za-z0-9._:-]{16,256}$ ]] || die 'gateway observer credential is invalid'
  write_env "$observer_env" \
    "DEVSHARD_ADMIN_API_KEY=$(<"$SECRETS/gateway.admin-key")" \
    "GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN=$token" \
    "GDC_GATEWAY_ADMIN_STATE_URL=http://127.0.0.1:$port/v1/admin/state"
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
            if [[ "$observer_url" =~ ^http://127\.0\.0\.1:([1-9][0-9]{0,4})/v1/admin/state$ ]]; then
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
  curl -fsS --connect-timeout 5 --max-time 30 "https://$API_HOST/v1/status" \
    -H "Authorization: Bearer $client_key" \
    | jq -e 'type == "object"' >/dev/null
  curl -fsS --connect-timeout 5 --max-time 30 "https://$API_HOST/v1/models" \
    -H "Authorization: Bearer $client_key" \
    | jq -e --arg model "$MODEL_ID" '.data | any(.id == $model)' >/dev/null
  "$ROOT/04-ops/test-inference.sh" "https://$API_HOST" "$client_key" >/dev/null
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
      [[ "$target_version" == "$requested_target" ]] \
        || die "another gateway migration is active target=$target_version requested=$requested_target"
      remote_status=''
      remote_status_rc=0
      remote_status="$(ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' status '$remote_dir'" 2>/dev/null)" \
        || remote_status_rc=$?
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
        prepared|cutover_pending|cutover|drained|completed)
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
        ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' mark '$remote_dir' cutover_pending"
        install_route "$target_port" target
        ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' mark '$remote_dir' cutover"
        ;;
      cutover_pending)
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
    timeout="${target_version:-900}"
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
