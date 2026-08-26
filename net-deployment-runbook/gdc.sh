#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

on_launcher_error() {
  local rc="$?"
  trap - ERR
  printf 'ERROR gdc command failed phase=%s exit=%s run_log=%s command=%s\n' \
    "${GDC_ACTIVE_PHASE:-unavailable}" "$rc" "${GDC_RUN_LOG:-unavailable}" \
    "${GDC_INVOCATION_COMMAND:-$ROOT/gdc.sh}" >&2
  exit "$rc"
}
trap 'on_launcher_error "$LINENO"' ERR

source "$ROOT/scripts/lib.sh"
init_gdc_data_root

acquire_operator_lock() {
  [[ "${GDC_OPERATOR_LOCK_STATE:-}" == "$STATE" ]] && return 0
  local lock_file="$STATE/.lifecycle.lock"
  mkdir -p "$STATE"
  exec 9>"$lock_file"
  if ! flock -n 9; then
    echo 'another lifecycle phase is already running for this operator; wait for it to finish before starting another phase' >&2
    exit 1
  fi
  export GDC_OPERATOR_LOCK_STATE="$STATE"
}

format_safe_invocation() {
  local arg redact_next=false rendered=''
  for arg in "$@"; do
    if [[ "$redact_next" == true ]]; then
      rendered+=" $(printf '%q' '<redacted>')"
      redact_next=false
      continue
    fi
    case "$arg" in
      --*key|--*key-file|--*token|--*password|--*secret|--*mnemonic|--*credential)
        rendered+=" $(printf '%q' "$arg")"
        redact_next=true
        ;;
      --*key=*|--*key-file=*|--*token=*|--*password=*|--*secret=*|--*mnemonic=*|--*credential=*)
        rendered+=" $(printf '%q' "${arg%%=*}=<redacted>")"
        ;;
      *)
        rendered+=" $(printf '%q' "$arg")"
        ;;
    esac
  done
  printf '%q%s\n' "$ROOT/gdc.sh" "$rendered"
}

run_phase() {
  local phase="$1"
  shift
  local state run_id_file run_id run_dir log rc
  state="$STATE"
  acquire_operator_lock
  run_id_file="$state/active-run-id"
  mkdir -p "$state"
  # An assurance adapter owns one evidence namespace per scenario execution.
  # Do not silently append it to the last operator's lifecycle run.
  if [[ -n "${GDC_ASSURANCE_RUN_ID:-}" ]]; then
    run_id="assurance-${GDC_ASSURANCE_RUN_ID}"
    printf '%s\n' "$run_id" >"$run_id_file"
  elif [[ "${GDC_FORCE_NEW_RUN:-false}" == true ]]; then
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    printf '%s\n' "$run_id" >"$run_id_file"
  elif [[ -s "$run_id_file" ]]; then
    run_id="$(<"$run_id_file")"
  else
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    printf '%s\n' "$run_id" >"$run_id_file"
  fi
  run_dir="$GDC_HOME/runs/$run_id"
  log="$run_dir/run.log"
  mkdir -p "$run_dir"
  export GDC_RUN_ID="$run_id" GDC_RUN_LOG="$log" GDC_ACTIVE_PHASE="$phase"
  # This immutable envelope exists before the invoked phase can mutate a
  # Host. `record_phase_profile` enriches it once role input is loaded.
  ensure_run_manifest "$phase"

  set +e
  {
    [[ -z "${GDC_INVOCATION_COMMAND:-}" ]] || printf 'INVOCATION command=%s\n' "$GDC_INVOCATION_COMMAND"
    printf 'LAUNCHER runbook_revision=%s gdc_launcher_sha256=%s\n' "$(runbook_revision)" "$(gdc_launcher_sha256)"
    printf 'BEGIN phase=%s timestamp=%s run_id=%s\n' "$phase" "$(date -u +%FT%TZ)" "$run_id"
    "$@"
    rc=$?
    printf 'END phase=%s status=%s timestamp=%s\n' "$phase" "$rc" "$(date -u +%FT%TZ)"
    exit "$rc"
  } 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

use_node_data_home() {
  select_node_data_home "$1"
}

use_network_owner_data_home() {
  select_network_owner_data_home || return 0
}

use_operator_inventory() {
  [[ -s "$GDC_DATA_ROOT/.env" ]] || return 0
  export GDC_ENV="$GDC_DATA_ROOT/.env"
}

usage() {
  cat <<'EOF'
Gonka DevNet Community manual deployment

See the role guides for required input, then run:
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] [--public-edge <SSH_ALIAS>] [--skip-qualification]
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] [--public-edge <SSH_ALIAS>] --no-bootstrap-access
  ./gdc.sh --release v2026.07.23 baseline
  ./gdc.sh --release v2026.07.23 bootstrap-access
  ./gdc.sh --release v2026.07.23 gateway-continuity
  ./gdc.sh host join --public-host <IP_OR_DOMAIN> <SSH_ALIAS>
  ./gdc.sh host backup <SSH_ALIAS>
  ./gdc.sh --release v2026.07.23 ml attach <SSH_ALIAS>
  ./gdc.sh ops faucet
  ./gdc.sh ops monitoring
  ./gdc.sh ops site
  ./gdc.sh ops explorer
  ./gdc.sh ops consumer telegram apply
  ./gdc.sh ops consumer telegram status
  ./gdc.sh ops consumer telegram verify [MODEL] [SLA]
  ./gdc.sh gateway access-key ensure telegram
  ./gdc.sh gateway access-key revoke telegram
  ./gdc.sh gateway access-key list
  ./gdc.sh --release v2026.07.23 gateway apply v3
  ./gdc.sh --release v2026.07.23 gateway reconcile v3
  ./gdc.sh gateway status
  ./gdc.sh gateway verify [SLA]
  ./gdc.sh --release v2026.07.23 gateway continuity
  ./gdc.sh --release v2026.07.23 gateway settle
  ./gdc.sh --release v2026.08.06 gateway ha v4
  ./gdc.sh --release v2026.07.23 network genesis <SSH_ALIAS>
  ./gdc.sh --release v2026.07.23 network verify
  ./gdc.sh --release v2026.07.23 network gate-b verify
  ./gdc.sh --release v2026.07.23 network confirmation-poc verify
  ./gdc.sh --release v2026.08.06 network upgrade verify <proposal-id>
  ./gdc.sh network reset --yes [--hosts <SSH_ALIAS[,SSH_ALIAS...]>]
  ./gdc.sh --release v2026.08.06 host upgrade prepare <ssh-alias> <proposal-id>
  ./gdc.sh --release v2026.08.06 host upgrade watch <ssh-alias> <proposal-id>
  ./gdc.sh --release v2026.07.23 host ml-attach <SSH_ALIAS>
  ./gdc.sh host stop|start|verify <SSH_ALIAS>
  ./gdc.sh host reset <SSH_ALIAS> [<SSH_ALIAS> ...]
  ./gdc.sh --release v2026.08.06 governance devshard submit
  ./gdc.sh --release v2026.08.06 governance devshard verify <proposal-id>
  ./gdc.sh --release v2026.08.06 governance vote <proposal-id> [yes|no|abstain|no_with_veto]
  ./gdc.sh --release v2026.08.06 bridge contract deploy sepolia
  ./gdc.sh --release v2026.08.06 bridge contract register sepolia
  ./gdc.sh --release v2026.08.06 bridge observer apply|status|verify <SSH_ALIAS>
  ./gdc.sh release candidate prepare --source-ref upgrade-v0.2.16
  ./gdc.sh release candidate build <vYYYY.MM.DD-rc.N> [--dry-run] [--retry] [--wait]
  ./gdc.sh release candidate profile <vYYYY.MM.DD-rc.N> [--build-manifest <PATH>]
  ./gdc.sh release candidate verify <vYYYY.MM.DD-rc.N> [--build-manifest <PATH>]
  ./gdc.sh node stop <SSH_ALIAS>
  ./gdc.sh node start <SSH_ALIAS>
  ./gdc.sh node verify <SSH_ALIAS>
  ./gdc.sh node reset <SSH_ALIAS>
  ./gdc.sh ops edge
  ./gdc.sh --release v2026.07.23 verify
  ./gdc.sh --release v2026.08.06 upgrade-proposal
  ./gdc.sh --release v2026.08.06 upgrade-worker <proposal-id>
  ./gdc.sh --release v2026.08.06 advance-after-upgrade <proposal-id>
  ./gdc.sh --release v2026.08.06 advance-after-upgrade-worker <proposal-id>
  ./gdc.sh --release v2026.08.06 upgrade
  ./gdc.sh --release v2026.08.06 governance devshard
  ./gdc.sh --release v2026.08.06 vote <proposal-id> [yes|no|abstain|no_with_veto]
  GDC_GATEWAY_VERSION=v3 GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false ./gdc.sh --release v2026.08.06 ops gateway
  ./gdc.sh --release v2026.08.06 settle
  GDC_GATEWAY_VERSION=v4 GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false ./gdc.sh --release v2026.08.06 ops gateway
  ./gdc.sh --release v2026.08.06 settle
  ./gdc.sh --release v2026.08.06 ha v4
  ./gdc.sh --release v2026.08.06 bridge-deploy sepolia
  ./gdc.sh --release v2026.08.06 bridge-register sepolia
  ./gdc.sh --release v2026.08.06 bridge sepolia
  ./gdc.sh audit

Start a clean rehearsal with:
  ./gdc.sh reset --yes

Runtime data defaults to \$HOME/.gdc-data. Override it per operator with:
  GDC_HOME=/absolute/path ./gdc.sh <command>
EOF
}

GDC_INVOCATION_COMMAND="$(format_safe_invocation "$@")"
GDC_INVOCATION_CWD="$PWD"
export GDC_INVOCATION_COMMAND GDC_INVOCATION_CWD

RELEASE=''
MODEL=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
[[ -z "$RELEASE" || "$RELEASE" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "Invalid release profile: $RELEASE" >&2; exit 2; }
[[ -z "$RELEASE" || -r "$ROOT/profiles/releases/$RELEASE.lock" ]] || { echo "Unknown release: $RELEASE" >&2; exit 2; }
[[ -z "$MODEL" || "$MODEL" == qwen3-0.6b ]] || { echo "Unknown model overlay: $MODEL" >&2; exit 2; }
[[ -z "$RELEASE" ]] || export GDC_RELEASE_PROFILE="$RELEASE"
[[ -z "$MODEL" ]] || export GDC_MODEL_PROFILE="$MODEL"

is_upgrade_target_profile() {
  local profile="${GDC_RELEASE_PROFILE:-}" lock
  [[ -n "$profile" ]] || return 1
  [[ "$profile" == v2026.08.06 ]] && return 0
  lock="$ROOT/profiles/releases/$profile.lock"
  [[ -r "$lock" ]] && grep -Eq '^UPGRADE_FROM_PROFILE=[a-z0-9][a-z0-9.-]*$' "$lock"
}

COMMAND="${1:-help}"
shift || true

# Domain aliases make the authority boundary visible without invalidating
# existing executable evidence that still names the original lifecycle phases.
case "$COMMAND" in
  network)
    subcommand="${1:-}"; shift || true
    case "$subcommand" in
      genesis|verify|reset) COMMAND="$subcommand" ;;
      gate-b) [[ "${1:-}" == verify && $# -eq 1 ]] || { usage; exit 2; }; shift; COMMAND=public-network-verify ;;
      confirmation-poc) [[ "${1:-}" == verify && $# -eq 1 ]] || { usage; exit 2; }; shift; COMMAND=confirmation-poc ;;
      upgrade) [[ "${1:-}" == verify && $# -eq 2 ]] || { usage; exit 2; }; COMMAND=public-upgrade-verify; set -- "$2" ;;
      *) usage; exit 2 ;;
    esac
    ;;
  host)
    subcommand="${1:-}"; shift || true
    case "$subcommand" in
      join) COMMAND='join' ;;
      backup) COMMAND='host-backup' ;;
      upgrade)
        upgrade_action="${1:-}"; shift || true
        [[ "$upgrade_action" =~ ^(prepare|watch)$ ]] || { usage; exit 2; }
        COMMAND="host-upgrade-$upgrade_action"
        ;;
      ml-attach) COMMAND=ml; set -- attach "$@" ;;
      start|stop|verify|reset) COMMAND=node; set -- "$subcommand" "$@" ;;
      *) usage; exit 2 ;;
    esac
    ;;
esac
case "$COMMAND" in
  release)
    [[ "${1:-}" == candidate && $# -ge 2 ]] || { usage; exit 2; }
    shift
    exec "$ROOT/scripts/release-candidate.py" "$@"
    ;;
  public-network-verify|confirmation-poc|public-upgrade-verify)
    [[ $# -le 1 ]] || { usage; exit 2; }
    case "$COMMAND" in
      public-network-verify) run_phase public-network-verify "$ROOT/scripts/phase-public-network-verify.sh" ;;
      confirmation-poc) run_phase confirmation-poc "$ROOT/scripts/phase-confirmation-poc.sh" ;;
      public-upgrade-verify)
        [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] && is_upgrade_target_profile || { usage; exit 2; }
        run_phase "public-upgrade-verify-$1" "$ROOT/scripts/phase-public-upgrade-verify.sh" "$1"
        ;;
    esac
    ;;
  host-upgrade-prepare|host-upgrade-watch)
    [[ $# -eq 2 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$2" =~ ^[1-9][0-9]*$ ]] && is_upgrade_target_profile || { usage; exit 2; }
    use_node_data_home "$1"
    if [[ "$COMMAND" == host-upgrade-prepare ]]; then
      run_phase "host-upgrade-prepare-$1-$2" "$ROOT/scripts/phase-host-upgrade-prepare.sh" "$1" "$2"
    else
      run_phase "host-upgrade-watch-$1-$2" "$ROOT/scripts/phase-host-upgrade-watch.sh" "$1" "$2"
    fi
    ;;
  host-backup)
    backup_alias="${1:-}"
    [[ $# -eq 1 && "$backup_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'host backup requires exactly one SSH alias' >&2; exit 2; }
    use_node_data_home "$backup_alias"
    backup_role_config=''
    if [[ -s "$GDC_HOME/.env" ]]; then backup_role_config="$GDC_HOME/.env";
    elif [[ -s "$STATE/active-role-config" ]]; then backup_role_config="$(<"$STATE/active-role-config")"; fi
    [[ -s "$backup_role_config" ]] || { echo "host backup requires retained operator state for $backup_alias; a running Host cannot recreate cold or warm recovery material" >&2; exit 1; }
    export GDC_ENV="$backup_role_config"
    source "$ROOT/scripts/lib.sh"
    load_project
    run_phase "backup-$backup_alias" "$ROOT/scripts/phase-host-backup.sh" "$backup_alias"
    ;;
  prepare|verify|reset|baseline|settle|bootstrap-access|gateway-continuity|audit)
    use_network_owner_data_home
    if [[ "$COMMAND" == gateway-continuity || "$COMMAND" == audit ]]; then
      use_operator_inventory
    fi
    [[ "$COMMAND" == reset || $# -eq 0 ]] || { usage; exit 2; }
    if [[ "$COMMAND" == reset ]]; then
      # A completed Genesis keeps its narrow role input under the network-owner
      # Host. Reset must instead use the operator inventory at the data-root so
      # an explicit future Host can be reset before it has ever joined.
      if [[ -s "$GDC_DATA_ROOT/.env" ]]; then
        export GDC_ENV="$GDC_DATA_ROOT/.env"
        # A completed network may have left a runtime topology behind.  Reset
        # is an operator-inventory operation, so its public edge must come
        # from that inventory rather than from the network being removed.
        inventory_public_edge="$(awk -F= '$1 == "GDC_PUBLIC_EDGE_NODE" { print $2; exit }' "$GDC_DATA_ROOT/.env")"
        if [[ -n "$inventory_public_edge" ]]; then
          export GDC_PUBLIC_EDGE_NODE="$inventory_public_edge"
        fi
      fi
      # Reset begins a new evidence namespace. A prior lifecycle may have
      # been recorded against another release profile, which must not block
      # removal of the managed deployment state.
      export GDC_FORCE_NEW_RUN=true
      run_phase reset "$ROOT/scripts/phase-reset.sh" "$@"
      exit $?
    fi
    if [[ "$COMMAND" == baseline ]]; then
      run_phase baseline "$ROOT/scripts/phase-baseline.sh"
    elif [[ "$COMMAND" == bootstrap-access ]]; then
      run_phase bootstrap-access "$ROOT/scripts/phase-bootstrap-access.sh"
    elif [[ "$COMMAND" == gateway-continuity ]]; then
      run_phase gateway-continuity "$ROOT/scripts/phase-gateway-continuity.sh"
    elif [[ "$COMMAND" == audit ]]; then
      run_phase lifecycle-audit "$ROOT/scripts/phase-audit-lifecycle.sh"
    else
      run_phase "$COMMAND" "$ROOT/scripts/phase-$COMMAND.sh" "$@"
    fi
    ;;
  qualify-ml)
    [[ $# -le 1 ]] || { usage; exit 2; }
    if [[ $# -eq 1 ]]; then
      use_node_data_home "$1"
    else
      use_network_owner_data_home
    fi
    # Resolve topology after parsing flags so the same command works for any
    # valid SSH alias supplied by the operator inventory.
    source "$ROOT/scripts/lib.sh"
    load_project
    qualification_node="${1:-$GENESIS_NODE}"
    topology_contains_node "$qualification_node" || { echo "qualify-ml expects an alias from GDC_NODE_ALIASES, got: $qualification_node" >&2; exit 2; }
    use_node_data_home "$qualification_node"
    load_project
    qualification_target="$(node_ml_host "$qualification_node" || printf '%s' "$qualification_node")"
    export GDC_QUALIFY_HOSTS="$qualification_target"
    run_phase qualify-ml "$ROOT/scripts/phase-qualify-ml.sh"
    ;;
  genesis)
    genesis_alias='' genesis_time='' bootstrap_access=true skip_qualification=false
    genesis_public_host='' genesis_public_edge=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --time=*) [[ -z "$genesis_time" ]] || { usage; exit 2; }; genesis_time="$1" ;;
        --no-bootstrap-access) bootstrap_access=false ;;
        --skip-qualification) skip_qualification=true ;;
        --public-host) genesis_public_host="${2:-}"; shift ;;
        --public-edge) genesis_public_edge="${2:-}"; shift ;;
        *) [[ -z "$genesis_alias" ]] || { usage; exit 2; }; genesis_alias="$1" ;;
      esac
      shift
    done
    [[ -n "$genesis_alias" ]] || { echo 'genesis requires an SSH alias' >&2; usage; exit 2; }
    [[ -z "$genesis_public_edge" || "$genesis_public_edge" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
      echo "invalid public edge SSH alias: $genesis_public_edge" >&2; exit 2;
    }
    [[ -n "$genesis_public_edge" ]] || genesis_public_edge="$genesis_alias"
    use_node_data_home "$genesis_alias"
    genesis_input="$STATE/role-inputs/genesis-$genesis_alias"
    genesis_config_args=(--output "$genesis_input" --ssh-alias "$genesis_alias")
    [[ -n "$genesis_public_host" ]] && genesis_config_args+=(--public-host "$genesis_public_host")
    genesis_config_args+=(--public-edge-ssh-alias "$genesis_public_edge")
    "$ROOT/scripts/write-genesis-role-config.sh" "${genesis_config_args[@]}"
    printf '%s\n' "$genesis_input" >"$STATE/active-role-config"
    export GDC_ENV="$genesis_input"
    source "$ROOT/scripts/lib.sh"
    load_project
    topology_contains_node "$genesis_alias" || { echo "genesis expects an alias from GDC_NODE_ALIASES, got: $genesis_alias" >&2; exit 2; }
    topology_contains_node "$genesis_public_edge" || { echo "public edge expects an alias from GDC_NODE_ALIASES, got: $genesis_public_edge" >&2; exit 2; }
    export GDC_GENESIS_NODE="$genesis_alias" GDC_PUBLIC_EDGE_NODE="$genesis_public_edge" GDC_GATEWAY_NODE="$genesis_alias" GDC_TELEGRAM_BOT_HOST="$genesis_alias"
    export GDC_GENESIS_SKIP_QUALIFICATION="$skip_qualification"
    if [[ "$bootstrap_access" == true ]]; then
      export GDC_GENESIS_GUARDIAN_ENABLED=true GDC_GENESIS_BOOTSTRAP_ACCESS=true
    else
      export GDC_GENESIS_BOOTSTRAP_ACCESS=false
    fi
    genesis_args=()
    [[ -n "$genesis_time" ]] && genesis_args+=("$genesis_time")
    run_phase "genesis-$genesis_alias" "$ROOT/scripts/phase-genesis.sh" "${genesis_args[@]}"
    printf '%s\n' "$genesis_alias" >"$GDC_DATA_ROOT/network-owner"
    ;;
  upgrade)
    use_network_owner_data_home
    [[ $# -eq 0 ]] || { usage; exit 2; }
    is_upgrade_target_profile || { echo 'upgrade requires an upgrade-capable release profile' >&2; exit 2; }
    run_phase upgrade "$ROOT/scripts/phase-upgrade.sh"
    ;;
  upgrade-proposal)
    use_network_owner_data_home
    [[ $# -eq 0 ]] || { usage; exit 2; }
    is_upgrade_target_profile || { echo 'upgrade-proposal requires an upgrade-capable release profile' >&2; exit 2; }
    run_phase upgrade-proposal "$ROOT/scripts/phase-propose-upgrade.sh"
    ;;
  upgrade-worker)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    is_upgrade_target_profile || { echo 'upgrade-worker requires an upgrade-capable release profile' >&2; exit 2; }
    run_phase "upgrade-worker-$1" "$ROOT/scripts/phase-upgrade-worker.sh" "$1"
    ;;
  advance-after-upgrade)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'advance-after-upgrade requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase "advance-after-upgrade-$1" "$ROOT/scripts/phase-advance-after-upgrade.sh" "$1"
    ;;
  advance-after-upgrade-worker)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'advance-after-upgrade-worker requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase "advance-after-upgrade-worker-$1" "$ROOT/scripts/phase-advance-after-upgrade-worker.sh" "$1"
    ;;
  ops)
    use_network_owner_data_home
    # OPS configuration is owned by the network data root.  The network owner
    # has a node-local role input as well, but it must not shadow public
    # service settings such as the Telegram conversation URL.
    export GDC_ENV="$GDC_DATA_ROOT/.env"
    [[ $# -ge 1 ]] || { usage; exit 2; }
    if [[ "$1" == consumer ]]; then
      [[ $# -ge 3 && $# -le 5 && "$2" == telegram && "$3" =~ ^(apply|status|verify)$ ]] || { usage; exit 2; }
      [[ "$3" == verify || $# -eq 3 ]] || { usage; exit 2; }
      run_phase "ops-consumer-telegram-$3" "$ROOT/scripts/phase-telegram-consumer.sh" "${@:3}"
    elif [[ "$1" == edge-node ]]; then
      [[ $# -eq 2 ]] || { usage; exit 2; }
      source "$ROOT/scripts/lib.sh"
      load_project
      topology_contains_node "$2" || { echo "ops edge-node expects an alias from GDC_NODE_ALIASES, got: $2" >&2; exit 2; }
      run_phase "ops-edge-node-$2" "$ROOT/scripts/phase-ops.sh" "$1" "$2"
    else
      [[ $# -eq 1 && "$1" =~ ^(gateway|faucet|monitoring|site|explorer|edge)$ ]] || { usage; exit 2; }
      run_phase "ops-$1" "$ROOT/scripts/phase-ops.sh" "$1"
    fi
    ;;
  gateway)
    use_network_owner_data_home
    use_operator_inventory
    gateway_action="${1:-}"; shift || true
    case "$gateway_action" in
      access-key)
        if [[ "${1:-}" == list && $# -eq 1 ]]; then
          run_phase gateway-access-key-list "$ROOT/scripts/phase-gateway-access-key.sh" list
        elif [[ $# -eq 2 && "$1" =~ ^(ensure|revoke)$ && "$2" == telegram ]]; then
          run_phase "gateway-access-key-$1-telegram" "$ROOT/scripts/phase-gateway-access-key.sh" "$1" telegram
        else
          usage; exit 2
        fi
        ;;
      apply|reconcile)
        [[ $# -le 1 && "${1:-v3}" =~ ^v[345]$ ]] || { usage; exit 2; }
        export GDC_GATEWAY_VERSION="${1:-v3}"
        run_phase "gateway-$gateway_action-$GDC_GATEWAY_VERSION" "$ROOT/scripts/phase-ops.sh" gateway
        ;;
      status|verify)
        [[ "$gateway_action" == verify || $# -eq 0 ]] || { usage; exit 2; }
        [[ $# -le 1 ]] || { usage; exit 2; }
        run_phase "gateway-$gateway_action" "$ROOT/scripts/phase-gateway-observe.sh" "$gateway_action" "$@"
        ;;
      continuity)
        [[ $# -eq 0 ]] || { usage; exit 2; }
        run_phase gateway-continuity "$ROOT/scripts/phase-gateway-continuity.sh"
        ;;
      settle)
        [[ $# -eq 0 ]] || { usage; exit 2; }
        run_phase settle "$ROOT/scripts/phase-settle.sh"
        ;;
      ha)
        [[ $# -eq 1 && "$1" == v4 ]] || { usage; exit 2; }
        run_phase ha-v4 "$ROOT/scripts/phase-ha-v4.sh"
        ;;
      *) usage; exit 2 ;;
    esac
    ;;
  node)
    node_action="${1:-}"
    shift || true
    [[ "$node_action" =~ ^(stop|start|verify|reset)$ ]] || { usage; exit 2; }
    if [[ "$node_action" == reset ]]; then
      [[ $# -ge 1 ]] || { usage; exit 2; }
      # Reset deliberately starts fresh evidence. It must remain usable after
      # a prior lifecycle under another release profile and must never alter
      # that prior manifest.
      export GDC_FORCE_NEW_RUN=true
    else
      [[ $# -eq 1 ]] || { usage; exit 2; }
    fi
    for node_alias in "$@"; do
      [[ "$node_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "node $node_action received an invalid SSH alias: $node_alias" >&2; exit 2; }
    done
    if [[ "$node_action" != reset ]]; then
      use_node_data_home "$1"
      source "$ROOT/scripts/lib.sh"
      load_project
      topology_contains_node "$1" || { echo "node $node_action expects an alias from GDC_NODE_ALIASES, got: $1" >&2; exit 2; }
    fi
    # A multi-host reset deliberately invokes the identical one-host phase for
    # each alias. This preserves its safety checks and makes failure semantics
    # the same as running the commands separately: completed hosts stay reset,
    # and processing stops at the first failed host.
    for node_alias in "$@"; do
      use_node_data_home "$node_alias"
      run_phase "node-$node_action-$node_alias" "$ROOT/scripts/phase-node.sh" "$node_action" "$node_alias"
    done
    ;;
  governance)
    use_network_owner_data_home
    governance_action="${1:-}"; shift || true
    if [[ "$governance_action" == devshard ]]; then
      case "${1:-}" in
        '') run_phase governance-devshard "$ROOT/scripts/phase-governance-devshard.sh" ;;
        submit)
          [[ $# -eq 1 ]] || { usage; exit 2; }
          GDC_GOVERNANCE_SUBMIT=true run_phase governance-devshard-submit "$ROOT/scripts/phase-governance-devshard.sh"
          ;;
        verify)
          [[ $# -eq 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
          GDC_GOVERNANCE_PROPOSAL_ID="$2" run_phase "governance-devshard-verify-$2" "$ROOT/scripts/phase-governance-devshard.sh"
          ;;
        *) usage; exit 2 ;;
      esac
    elif [[ "$governance_action" == vote ]]; then
      [[ $# -eq 1 || $# -eq 2 ]] || { usage; exit 2; }
      run_phase "vote-proposal-$1" "$ROOT/scripts/phase-vote-proposal.sh" "$@"
    else
      usage; exit 2
    fi
    ;;
  vote)
    use_network_owner_data_home
    [[ $# -eq 1 || $# -eq 2 ]] || { usage; exit 2; }
    run_phase "vote-proposal-$1" "$ROOT/scripts/phase-vote-proposal.sh" "$@"
    ;;
  ha)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" == v4 ]] || { usage; exit 2; }
    run_phase ha-v4 "$ROOT/scripts/phase-ha-v4.sh"
    ;;
  bridge-deploy)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" == sepolia ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'bridge-deploy requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase bridge-deploy-sepolia "$ROOT/scripts/phase-bridge-deploy-sepolia.sh"
    ;;
  bridge-register)
    use_network_owner_data_home
    [[ "${1:-}" == sepolia ]] || { echo 'usage: ./gdc.sh --release v2026.08.06 bridge-register sepolia' >&2; exit 2; }
    shift
    [[ "$RELEASE_PROFILE" == v2026.08.06 ]] || {
      echo 'bridge-register requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase bridge-register-sepolia "$ROOT/scripts/phase-bridge-register-sepolia.sh"
    ;;
  bridge)
    use_network_owner_data_home
    bridge_scope="${1:-}"; shift || true
    case "$bridge_scope" in
      sepolia)
        [[ $# -eq 0 ]] || { usage; exit 2; }
        run_phase bridge-sepolia "$ROOT/scripts/phase-bridge-observer.sh" apply "${GDC_BRIDGE_HOST:-$GENESIS_NODE}"
        ;;
      contract)
        bridge_action="${1:-}"; network="${2:-}"; [[ $# -eq 2 && "$network" == sepolia ]] || { usage; exit 2; }
        case "$bridge_action" in
          deploy) run_phase bridge-contract-deploy-sepolia "$ROOT/scripts/phase-bridge-deploy-sepolia.sh" ;;
          register) run_phase bridge-contract-register-sepolia "$ROOT/scripts/phase-bridge-register-sepolia.sh" ;;
          *) usage; exit 2 ;;
        esac
        ;;
      observer)
        bridge_action="${1:-}"; bridge_host="${2:-}"; [[ $# -eq 2 && "$bridge_action" =~ ^(apply|status|verify)$ ]] || { usage; exit 2; }
        run_phase "bridge-observer-$bridge_action-$bridge_host" "$ROOT/scripts/phase-bridge-observer.sh" "$bridge_action" "$bridge_host"
        ;;
      *) usage; exit 2 ;;
    esac
    ;;
  join)
    join_alias='' join_gpu_alias='' join_public_host='' join_restore_archive='' skip_qualification=false verification=true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --skip-qualification) skip_qualification=true ;;
        --verification) verification=true ;;
        --public-host)
          join_public_host="${2:-}"
          [[ "$join_public_host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'host join --public-host requires an IP address or domain' >&2; exit 2; }
          shift
          ;;
        --restore)
          join_restore_archive="${2:-}"
          [[ -n "$join_restore_archive" && -f "$join_restore_archive" && -r "$join_restore_archive" ]] || {
            echo 'host join --restore requires a readable validator backup archive' >&2; exit 2;
          }
          join_restore_archive="$(realpath -e -- "$join_restore_archive")"
          shift
          ;;
        --*) echo "unknown host join option: $1" >&2; usage; exit 2 ;;
        *)
          if [[ -z "$join_alias" ]]; then
            join_alias="$1"
          elif [[ -z "$join_gpu_alias" ]]; then
            join_gpu_alias="$1"
          else
            usage
            exit 2
          fi
          ;;
      esac
      shift
    done
    [[ -n "$join_alias" ]] || { echo 'host join requires an SSH alias' >&2; usage; exit 2; }
    [[ "$join_alias" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "invalid Host SSH alias: $join_alias (use lowercase letters, digits, _ or -)" >&2; exit 2; }
    if [[ -n "$join_gpu_alias" ]]; then
      [[ "$join_gpu_alias" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "invalid GPU SSH alias: $join_gpu_alias (use lowercase letters, digits, _ or -)" >&2; exit 2; }
      [[ "$join_gpu_alias" != "$join_alias" ]] || { echo 'Host and GPU SSH aliases must be different' >&2; exit 2; }
    fi
    use_node_data_home "$join_alias"
    acquire_operator_lock
    export GDC_JOIN_SKIP_QUALIFICATION="$skip_qualification"
    export GDC_JOIN_VERIFICATION="$verification"
    [[ -z "$join_restore_archive" ]] || export GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE="$join_restore_archive"
    join_role_ready=false
    join_role_config=''
    join_dispatch_marker="$STATE/join-bootstrap-dispatched.manifest.sha256"
    join_role_dispatched=false
    if [[ -n "${GDC_ENV:-}" && -s "$GDC_ENV" ]]; then
      join_role_config="$GDC_ENV"
    elif [[ -s "$GDC_HOME/.env" ]]; then
      join_role_config="$GDC_HOME/.env"
    elif [[ -s "$STATE/active-role-config" ]]; then
      join_role_config="$(<"$STATE/active-role-config")"
    fi
    join_marker_schema='' join_marker_manifest='' join_marker_role_sha256=''
    join_marker_alias='' join_marker_public_host='' join_marker_gpu_alias=''
    if [[ -e "$join_dispatch_marker" ]]; then
      [[ -s "$join_dispatch_marker" ]] || { echo 'JOIN bootstrap dispatch marker is empty; refusing to replace the prepared bootstrap' >&2; exit 1; }
      while IFS='=' read -r key value; do
        case "$key" in
          schema_version) join_marker_schema="$value" ;;
          manifest_sha256) join_marker_manifest="$value" ;;
          role_sha256) join_marker_role_sha256="$value" ;;
          host_alias) join_marker_alias="$value" ;;
          public_host) join_marker_public_host="$value" ;;
          gpu_alias) join_marker_gpu_alias="$value" ;;
          *) echo 'JOIN bootstrap dispatch marker has an unsupported field; refusing to replace the prepared bootstrap' >&2; exit 1 ;;
        esac
      done <"$join_dispatch_marker"
      [[ "$join_marker_schema" == 1 && "$join_marker_manifest" =~ ^[0-9a-f]{64}$ && "$join_marker_role_sha256" =~ ^[0-9a-f]{64}$ && "$join_marker_alias" =~ ^[a-z0-9][a-z0-9_-]*$ && "$join_marker_public_host" =~ ^[A-Za-z0-9.-]+$ && "$join_marker_gpu_alias" =~ ^[a-z0-9_-]*$ ]] || {
        echo 'JOIN bootstrap dispatch marker is invalid; refusing to replace the prepared bootstrap' >&2
        exit 1
      }
      join_role_dispatched=true
      [[ "$join_alias" == "$join_marker_alias" ]] || { echo 'JOIN has already dispatched with a different Host topology; use a separately validated recovery workflow' >&2; exit 1; }
      [[ -z "$join_public_host" || "$join_public_host" == "$join_marker_public_host" ]] || { echo 'JOIN has already dispatched with a different public Host; use a separately validated recovery workflow' >&2; exit 1; }
      [[ -z "$join_gpu_alias" || "$join_gpu_alias" == "$join_marker_gpu_alias" ]] || { echo 'JOIN has already dispatched with a different GPU Host; use a separately validated recovery workflow' >&2; exit 1; }
    fi
    if [[ -s "$join_role_config" ]]; then
      # This is a locally generated, mode-0600 role file.
      # shellcheck disable=SC1090
      source "$join_role_config"
      if [[ "$join_role_dispatched" == true ]]; then
        [[ "$(sha256sum "$join_role_config" | awk '{print $1}')" == "$join_marker_role_sha256" ]] || {
          echo 'JOIN dispatch binding disagrees with the selected role input; refusing to replace it' >&2
          exit 1
        }
        [[ "${GDC_JOIN_BOOTSTRAP_MANIFEST_SHA256:-}" == "$join_marker_manifest" ]] || {
          echo 'JOIN dispatch binding disagrees with the selected bootstrap; refusing to replace it' >&2
          exit 1
        }
        [[ "$(topology_value "${GDC_NODE_PUBLIC_HOSTS:-}" "$join_alias" || true)" == "$join_marker_public_host" ]] || {
          echo 'JOIN dispatch binding disagrees with the selected public Host; refusing to replace it' >&2
          exit 1
        }
        [[ "$(topology_value "${GDC_NODE_ML_HOSTS:-}" "$join_alias" || true)" == "$join_marker_gpu_alias" ]] || {
          echo 'JOIN dispatch binding disagrees with the selected GPU Host; refusing to replace it' >&2
          exit 1
        }
      fi
    fi
    if [[ -s "$join_role_config" ]] && (
        # This is a locally generated, mode-0600 role file.
        # shellcheck disable=SC1090
        source "$join_role_config"
        # Public bootstrap can rotate between attempts. Generated JOIN role
        # inputs therefore never bypass preparation on a new invocation.
        [[ "${GDC_JOIN_ROLE_INPUT:-false}" != true || "$join_role_dispatched" == true ]] || exit 1
        [[ " ${GDC_NODE_ALIASES:-} " == *" $join_alias "* ]] || exit 1
        [[ -z "$join_public_host" ]] || [[ "$(topology_value "${GDC_NODE_PUBLIC_HOSTS:-}" "$join_alias" || true)" == "$join_public_host" ]] || exit 1
        [[ -z "$join_gpu_alias" ]] && exit 0
        for mapping in ${GDC_NODE_ML_HOSTS:-}; do
          [[ "$mapping" == "$join_alias=$join_gpu_alias" ]] && exit 0
        done
        exit 1
      ); then
      join_role_ready=true
      export GDC_ENV="$join_role_config"
    fi
    if [[ "$join_role_ready" != true ]]; then
      join_input="$STATE/role-inputs/join-$join_alias"
      join_config_args=(--output "$join_input" --ssh-alias "$join_alias")
      [[ -n "$join_public_host" ]] && join_config_args+=(--public-host "$join_public_host")
      [[ -n "$join_gpu_alias" ]] && join_config_args+=(--gpu-ssh-alias "$join_gpu_alias")
      [[ -n "${GDC_JOIN_BOOTSTRAP_URL:-}" ]] && join_config_args+=(--bootstrap-url "$GDC_JOIN_BOOTSTRAP_URL")
      "$ROOT/scripts/prepare-join-role-config.sh" "${join_config_args[@]}"
      printf '%s\n' "$join_input" >"$STATE/active-role-config"
      export GDC_ENV="$join_input"
      join_role_config="$join_input"
      # shellcheck disable=SC1090
      source "$join_role_config"
    fi
    run_phase "join-$join_alias" "$ROOT/scripts/phase-join.sh" "$join_alias"
    ;;
  ml)
    [[ $# -eq 2 && "$1" == attach ]] || { usage; exit 2; }
    use_node_data_home "$2"
    source "$ROOT/scripts/lib.sh"
    load_project
    topology_contains_node "$2" || { echo "ml attach expects an alias from GDC_NODE_ALIASES, got: $2" >&2; exit 2; }
    [[ -n "$(node_ml_host "$2" || true)" ]] || { echo "no network GPU configured for $2 in GDC_NODE_ML_HOSTS" >&2; exit 2; }
    run_phase "ml-attach-$2" "$ROOT/scripts/phase-ml-attach.sh" "$2"
    ;;
  help|-h|--help) usage ;;
  *) echo "Unknown phase: $COMMAND" >&2; usage; exit 2 ;;
esac
