#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/scripts/lib.sh"
init_gdc_data_root
LOCK_FILE="$GDC_DATA_ROOT/.gdc.lock"
mkdir -p "$GDC_DATA_ROOT"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo 'another gdc lifecycle phase is already running; wait for it to finish before starting a new one' >&2
  exit 1
fi

run_phase() {
  local phase="$1"
  shift
  local state run_id_file run_id run_dir log rc
  state="$STATE"
  run_id_file="$state/active-run-id"
  mkdir -p "$state"
  # An assurance adapter owns one evidence namespace per scenario execution.
  # Do not silently append it to the last operator's lifecycle run.
  if [[ -n "${GDC_ASSURANCE_RUN_ID:-}" ]]; then
    run_id="assurance-${GDC_ASSURANCE_RUN_ID}"
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
  export GDC_RUN_ID="$run_id" GDC_RUN_LOG="$log"

  set +e
  {
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

usage() {
  cat <<'EOF'
Gonka DevNet Community manual deployment

See the role guides for required input, then run:
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] [--skip-qualification]
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] --no-bootstrap-access
  ./gdc.sh --release v2026.07.23 baseline
  ./gdc.sh --release v2026.07.23 bootstrap-access
  ./gdc.sh --release v2026.07.23 gateway-continuity
  ./gdc.sh host join [--skip-qualification] <SSH_ALIAS> [<GPU_SSH_ALIAS>]
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
  ./gdc.sh network reset --yes
  ./gdc.sh host join [--skip-qualification] <SSH_ALIAS> [<GPU_SSH_ALIAS>]
  ./gdc.sh --release v2026.07.23 host ml-attach <SSH_ALIAS>
  ./gdc.sh host stop|start|verify <SSH_ALIAS>
  ./gdc.sh host reset <SSH_ALIAS> [<SSH_ALIAS> ...]
  ./gdc.sh --release v2026.08.06 governance devshard submit
  ./gdc.sh --release v2026.08.06 governance devshard verify <proposal-id>
  ./gdc.sh --release v2026.08.06 governance vote <proposal-id> [yes|no|abstain|no_with_veto]
  ./gdc.sh --release v2026.08.06 bridge contract deploy sepolia
  ./gdc.sh --release v2026.08.06 bridge contract register sepolia
  ./gdc.sh --release v2026.08.06 bridge observer apply|status|verify <SSH_ALIAS>
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

Runtime data defaults to ../net-deployment-data. Override it per operator with:
  GDC_HOME=/absolute/path ./gdc.sh <command>
EOF
}

RELEASE=''
MODEL=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
[[ -z "$RELEASE" || "$RELEASE" =~ ^v2026\.(07\.23|08\.06)$ ]] || { echo "Unknown release: $RELEASE" >&2; exit 2; }
[[ -z "$MODEL" || "$MODEL" == qwen3-0.6b ]] || { echo "Unknown model overlay: $MODEL" >&2; exit 2; }
[[ -z "$RELEASE" ]] || export GDC_RELEASE_PROFILE="$RELEASE"
[[ -z "$MODEL" ]] || export GDC_MODEL_PROFILE="$MODEL"

COMMAND="${1:-help}"
shift || true

# Domain aliases make the authority boundary visible without invalidating
# existing executable evidence that still names the original lifecycle phases.
case "$COMMAND" in
  network)
    subcommand="${1:-}"; shift || true
    case "$subcommand" in
      genesis|verify|reset) COMMAND="$subcommand" ;;
      *) usage; exit 2 ;;
    esac
    ;;
  host)
    subcommand="${1:-}"; shift || true
    case "$subcommand" in
      join) COMMAND='join' ;;
      ml-attach) COMMAND=ml; set -- attach "$@" ;;
      start|stop|verify|reset) COMMAND=node; set -- "$subcommand" "$@" ;;
      *) usage; exit 2 ;;
    esac
    ;;
esac
case "$COMMAND" in
  prepare|verify|reset|baseline|settle|bootstrap-access|gateway-continuity|audit)
    use_network_owner_data_home
    [[ "$COMMAND" == reset || $# -eq 0 ]] || { usage; exit 2; }
    if [[ "$COMMAND" == reset ]]; then
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
    genesis_public_host=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --time=*) [[ -z "$genesis_time" ]] || { usage; exit 2; }; genesis_time="$1" ;;
        --no-bootstrap-access) bootstrap_access=false ;;
        --skip-qualification) skip_qualification=true ;;
        --public-host) genesis_public_host="${2:-}"; shift ;;
        *) [[ -z "$genesis_alias" ]] || { usage; exit 2; }; genesis_alias="$1" ;;
      esac
      shift
    done
    [[ -n "$genesis_alias" ]] || { echo 'genesis requires an SSH alias' >&2; usage; exit 2; }
    use_node_data_home "$genesis_alias"
    genesis_input="$STATE/role-inputs/genesis-$genesis_alias"
    genesis_config_args=(--output "$genesis_input" --ssh-alias "$genesis_alias")
    [[ -n "$genesis_public_host" ]] && genesis_config_args+=(--public-host "$genesis_public_host")
    "$ROOT/scripts/write-genesis-role-config.sh" "${genesis_config_args[@]}"
    printf '%s\n' "$genesis_input" >"$STATE/active-role-config"
    export GDC_ENV="$genesis_input"
    source "$ROOT/scripts/lib.sh"
    load_project
    topology_contains_node "$genesis_alias" || { echo "genesis expects an alias from GDC_NODE_ALIASES, got: $genesis_alias" >&2; exit 2; }
    # A one-node network owns every live role on its sole operator-supplied
    # alias.  These process-local overrides do not rewrite the operator .env.
    export GDC_GENESIS_NODE="$genesis_alias" GDC_PUBLIC_EDGE_NODE="$genesis_alias" GDC_GATEWAY_NODE="$genesis_alias" GDC_TELEGRAM_BOT_HOST="$genesis_alias"
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
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'upgrade requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase upgrade "$ROOT/scripts/phase-upgrade.sh"
    ;;
  upgrade-proposal)
    use_network_owner_data_home
    [[ $# -eq 0 ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'upgrade-proposal requires --release v2026.08.06' >&2; exit 2;
    }
    run_phase upgrade-proposal "$ROOT/scripts/phase-propose-upgrade.sh"
    ;;
  upgrade-worker)
    use_network_owner_data_home
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || {
      echo 'upgrade-worker requires --release v2026.08.06' >&2; exit 2;
    }
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
        [[ $# -le 1 && "${1:-v3}" =~ ^v[34]$ ]] || { usage; exit 2; }
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
    join_alias='' join_gpu_alias='' skip_qualification=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --skip-qualification) skip_qualification=true ;;
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
    [[ "$join_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid Host SSH alias: $join_alias" >&2; exit 2; }
    if [[ -n "$join_gpu_alias" ]]; then
      [[ "$join_gpu_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid GPU SSH alias: $join_gpu_alias" >&2; exit 2; }
      [[ "$join_gpu_alias" != "$join_alias" ]] || { echo 'Host and GPU SSH aliases must be different' >&2; exit 2; }
    fi
    use_node_data_home "$join_alias"
    export GDC_JOIN_SKIP_QUALIFICATION="$skip_qualification"
    join_role_ready=false
    join_role_config=''
    if [[ -n "${GDC_ENV:-}" && -s "$GDC_ENV" ]]; then
      join_role_config="$GDC_ENV"
    elif [[ -s "$GDC_HOME/.env" ]]; then
      join_role_config="$GDC_HOME/.env"
    elif [[ -s "$STATE/active-role-config" ]]; then
      join_role_config="$(<"$STATE/active-role-config")"
    fi
    if [[ -s "$join_role_config" ]] && (
        # This is a locally generated, mode-0600 role file.
        # shellcheck disable=SC1090
        source "$join_role_config"
        [[ " ${GDC_NODE_ALIASES:-} " == *" $join_alias "* ]] || exit 1
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
      [[ -n "$join_gpu_alias" ]] && join_config_args+=(--gpu-ssh-alias "$join_gpu_alias")
      "$ROOT/scripts/prepare-join-role-config.sh" "${join_config_args[@]}"
      printf '%s\n' "$join_input" >"$STATE/active-role-config"
      export GDC_ENV="$join_input"
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
