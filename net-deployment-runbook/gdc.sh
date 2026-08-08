#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="$ROOT/state/.gdc.lock"
mkdir -p "$ROOT/state"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo 'another gdc lifecycle phase is already running; wait for it to finish before starting a new one' >&2
  exit 1
fi

run_phase() {
  local phase="$1"
  shift
  local state run_id_file run_id run_dir log rc
  state="$ROOT/state"
  run_id_file="$state/active-run-id"
  mkdir -p "$state"
  if [[ -s "$run_id_file" ]]; then
    run_id="$(<"$run_id_file")"
  else
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    printf '%s\n' "$run_id" >"$run_id_file"
  fi
  run_dir="$ROOT/artifacts/runs/$run_id"
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

usage() {
  cat <<'EOF'
Gonka DevNet Community manual deployment

Create .env from .env.example, then run:
  ./gdc.sh --release testnet-0.2.14 --model qwen3-0.6b prepare
  ./gdc.sh --release testnet-0.2.14 qualify-ml [SSH_ALIAS]
  ./gdc.sh --release testnet-0.2.14 genesis
  ./gdc.sh --release testnet-0.2.14 baseline
  ./gdc.sh --release testnet-0.2.14 bootstrap-access
  ./gdc.sh telegram-key-probe Qwen/Qwen3-0.6B 60s
  ./gdc.sh --release testnet-0.2.14 gateway-continuity
  ./gdc.sh --release testnet-0.2.14 join <SSH_ALIAS>
  ./gdc.sh --release testnet-0.2.14 ml attach <SSH_ALIAS>
  ./gdc.sh --release testnet-0.2.14 handoff create <SSH_ALIAS>
  ./gdc.sh --release testnet-0.2.14 handoff approve <SSH_ALIAS> <activation-request.json>
  ./gdc.sh ops monitoring
  ./gdc.sh ops site
  ./gdc.sh ops explorer
  ./gdc.sh telegram-bot
  ./gdc.sh node stop <SSH_ALIAS>
  ./gdc.sh node start <SSH_ALIAS>
  ./gdc.sh node verify <SSH_ALIAS>
  ./gdc.sh node reset <SSH_ALIAS>
  ./gdc.sh ops edge
  ./gdc.sh --release testnet-0.2.14 verify
  ./gdc.sh --release testnet-0.2.15 upgrade-proposal
  ./gdc.sh --release testnet-0.2.15 upgrade-worker <proposal-id>
  ./gdc.sh --release testnet-0.2.15 advance-after-upgrade <proposal-id>
  ./gdc.sh --release testnet-0.2.15 advance-after-upgrade-worker <proposal-id>
  ./gdc.sh --release testnet-0.2.15 upgrade
  ./gdc.sh --release testnet-0.2.15 governance devshard
  ./gdc.sh --release testnet-0.2.15 vote <proposal-id> [yes|no|abstain|no_with_veto]
  GDC_GATEWAY_VERSION=v3 GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false ./gdc.sh --release testnet-0.2.15 ops gateway
  ./gdc.sh --release testnet-0.2.15 settle
  GDC_GATEWAY_VERSION=v4 GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false ./gdc.sh --release testnet-0.2.15 ops gateway
  ./gdc.sh --release testnet-0.2.15 settle
  ./gdc.sh --release testnet-0.2.15 ha v4
  ./gdc.sh --release testnet-0.2.15 bridge-deploy sepolia
  ./gdc.sh --release testnet-0.2.15 bridge-register sepolia
  ./gdc.sh --release testnet-0.2.15 bridge sepolia
  ./gdc.sh audit

Start a clean rehearsal with:
  ./gdc.sh reset --yes
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
[[ -z "$RELEASE" || "$RELEASE" =~ ^testnet-0\.2\.(14|15)$ ]] || { echo "Unknown release: $RELEASE" >&2; exit 2; }
[[ -z "$MODEL" || "$MODEL" == qwen3-0.6b ]] || { echo "Unknown model overlay: $MODEL" >&2; exit 2; }
[[ -z "$RELEASE" ]] || export GDC_RELEASE_PROFILE="$RELEASE"
[[ -z "$MODEL" ]] || export GDC_MODEL_PROFILE="$MODEL"

COMMAND="${1:-help}"
shift || true
case "$COMMAND" in
  prepare|verify|reset|baseline|settle|bootstrap-access|gateway-continuity|audit|telegram-bot|telegram-key-probe)
    [[ "$COMMAND" == reset || "$COMMAND" == telegram-key-probe || $# -eq 0 ]] || { usage; exit 2; }
    if [[ "$COMMAND" == reset ]]; then
      run_phase reset "$ROOT/scripts/phase-reset.sh" "$@"
      exit $?
    fi
    if [[ "$COMMAND" == telegram-bot ]]; then
      run_phase telegram-bot "$ROOT/scripts/deploy-telegram-bot.sh"
    elif [[ "$COMMAND" == telegram-key-probe ]]; then
      [[ $# -eq 2 ]] || { usage; exit 2; }
      run_phase telegram-key-probe "$ROOT/scripts/phase-telegram-key-probe.sh" "$@"
    elif [[ "$COMMAND" == baseline ]]; then
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
    # Resolve topology after parsing flags so the same command works for any
    # valid SSH alias supplied by the operator inventory.
    source "$ROOT/scripts/lib.sh"
    load_project
    qualification_target="${1:-$GENESIS_NODE}"
    topology_contains_node "$qualification_target" || { echo "qualify-ml expects an alias from GDC_NODE_ALIASES, got: $qualification_target" >&2; exit 2; }
    qualification_target="$(node_ml_host "$qualification_target" || printf '%s' "$qualification_target")"
    export GDC_QUALIFY_HOSTS="$qualification_target"
    run_phase qualify-ml "$ROOT/scripts/phase-qualify-ml.sh"
    ;;
  genesis)
    [[ $# -le 1 && ( $# -eq 0 || "$1" == --time=* ) ]] || { usage; exit 2; }
    run_phase genesis "$ROOT/scripts/phase-genesis.sh" "$@"
    ;;
  upgrade)
    [[ $# -eq 0 ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == testnet-0.2.15 ]] || {
      echo 'upgrade requires --release testnet-0.2.15' >&2; exit 2;
    }
    run_phase upgrade "$ROOT/scripts/phase-upgrade.sh"
    ;;
  upgrade-proposal)
    [[ $# -eq 0 ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == testnet-0.2.15 ]] || {
      echo 'upgrade-proposal requires --release testnet-0.2.15' >&2; exit 2;
    }
    run_phase upgrade-proposal "$ROOT/scripts/phase-propose-upgrade.sh"
    ;;
  upgrade-worker)
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == testnet-0.2.15 ]] || {
      echo 'upgrade-worker requires --release testnet-0.2.15' >&2; exit 2;
    }
    run_phase "upgrade-worker-$1" "$ROOT/scripts/phase-upgrade-worker.sh" "$1"
    ;;
  advance-after-upgrade)
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == testnet-0.2.15 ]] || {
      echo 'advance-after-upgrade requires --release testnet-0.2.15' >&2; exit 2;
    }
    run_phase "advance-after-upgrade-$1" "$ROOT/scripts/phase-advance-after-upgrade.sh" "$1"
    ;;
  advance-after-upgrade-worker)
    [[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == testnet-0.2.15 ]] || {
      echo 'advance-after-upgrade-worker requires --release testnet-0.2.15' >&2; exit 2;
    }
    run_phase "advance-after-upgrade-worker-$1" "$ROOT/scripts/phase-advance-after-upgrade-worker.sh" "$1"
    ;;
  ops)
    [[ $# -ge 1 ]] || { usage; exit 2; }
    if [[ "$1" == edge-node ]]; then
      [[ $# -eq 2 ]] || { usage; exit 2; }
      source "$ROOT/scripts/lib.sh"
      load_project
      topology_contains_node "$2" || { echo "ops edge-node expects an alias from GDC_NODE_ALIASES, got: $2" >&2; exit 2; }
      run_phase "ops-edge-node-$2" "$ROOT/scripts/phase-ops.sh" "$1" "$2"
    else
      [[ $# -eq 1 && "$1" =~ ^(gateway|monitoring|site|explorer|edge)$ ]] || { usage; exit 2; }
      run_phase "ops-$1" "$ROOT/scripts/phase-ops.sh" "$1"
    fi
    ;;
  node)
    [[ $# -eq 2 && "$1" =~ ^(stop|start|verify|reset)$ ]] || { usage; exit 2; }
    source "$ROOT/scripts/lib.sh"
    load_project
    topology_contains_node "$2" || { echo "node $1 expects an alias from GDC_NODE_ALIASES, got: $2" >&2; exit 2; }
    run_phase "node-$1-$2" "$ROOT/scripts/phase-node.sh" "$1" "$2"
    ;;
  governance)
    [[ $# -eq 1 && "$1" == devshard ]] || { usage; exit 2; }
    run_phase governance-devshard "$ROOT/scripts/phase-governance-devshard.sh"
    ;;
  vote)
    [[ $# -eq 1 || $# -eq 2 ]] || { usage; exit 2; }
    run_phase "vote-proposal-$1" "$ROOT/scripts/phase-vote-proposal.sh" "$@"
    ;;
  ha)
    [[ $# -eq 1 && "$1" == v4 ]] || { usage; exit 2; }
    run_phase ha-v4 "$ROOT/scripts/phase-ha-v4.sh"
    ;;
  bridge-deploy)
    [[ $# -eq 1 && "$1" == sepolia ]] || { usage; exit 2; }
    [[ "${GDC_RELEASE_PROFILE:-}" == testnet-0.2.15 ]] || {
      echo 'bridge-deploy requires --release testnet-0.2.15' >&2; exit 2;
    }
    run_phase bridge-deploy-sepolia "$ROOT/scripts/phase-bridge-deploy-sepolia.sh"
    ;;
  bridge-register)
    [[ "${1:-}" == sepolia ]] || { echo 'usage: ./gdc.sh --release testnet-0.2.15 bridge-register sepolia' >&2; exit 2; }
    shift
    [[ "$RELEASE_PROFILE" == testnet-0.2.15 ]] || {
      echo 'bridge-register requires --release testnet-0.2.15' >&2; exit 2;
    }
    run_phase bridge-register-sepolia "$ROOT/scripts/phase-bridge-register-sepolia.sh"
    ;;
  bridge)
    [[ $# -eq 1 && "$1" == sepolia ]] || { usage; exit 2; }
    run_phase bridge-sepolia "$ROOT/scripts/phase-bridge-sepolia.sh"
    ;;
  join)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    run_phase "join-$1" "$ROOT/scripts/phase-join.sh" "$1"
    ;;
  ml)
    [[ $# -eq 2 && "$1" == attach ]] || { usage; exit 2; }
    source "$ROOT/scripts/lib.sh"
    load_project
    topology_contains_node "$2" || { echo "ml attach expects an alias from GDC_NODE_ALIASES, got: $2" >&2; exit 2; }
    [[ -n "$(node_ml_host "$2" || true)" ]] || { echo "no network GPU configured for $2 in GDC_NODE_ML_HOSTS" >&2; exit 2; }
    run_phase "ml-attach-$2" "$ROOT/scripts/phase-ml-attach.sh" "$2"
    ;;
  handoff)
    [[ $# -ge 2 ]] || { usage; exit 2; }
    case "$1" in
      create)
        [[ $# -eq 2 ]] || { usage; exit 2; }
        run_phase "handoff-create-$2" "$ROOT/scripts/phase-handoff-create.sh" "$2"
        ;;
      approve)
        [[ $# -eq 3 ]] || { usage; exit 2; }
        run_phase "handoff-approve-$2" "$ROOT/scripts/phase-handoff-approve.sh" "$2" "$3"
        ;;
      *) usage; exit 2 ;;
    esac
    ;;
  help|-h|--help) usage ;;
  *) echo "Unknown phase: $COMMAND" >&2; usage; exit 2 ;;
esac
