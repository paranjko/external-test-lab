#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  ./gdc.sh --release testnet-0.2.14 identities
  ./gdc.sh --release testnet-0.2.14 qualify-ml
  ./gdc.sh --release testnet-0.2.14 genesis
  ./gdc.sh --release testnet-0.2.14 genesis --time=+5m
  ./gdc.sh --release testnet-0.2.14 join node1
  ./gdc.sh join node2
  ./gdc.sh join node3
  ./gdc.sh join node4
  ./gdc.sh governance devshard
  ./gdc.sh vote <proposal-id> [yes|no|abstain|no_with_veto]
  ./gdc.sh ops gateway
  ./gdc.sh ops monitoring
  ./gdc.sh ops site
  ./gdc.sh ops meter
  ./gdc.sh ops explorer
  ./gdc.sh telegram-bot
  ./gdc.sh node stop node1
  ./gdc.sh node start node1
  ./gdc.sh node verify node1
  ./gdc.sh ops edge
  ./gdc.sh --release testnet-0.2.14 verify
  ./gdc.sh settle
  ./gdc.sh --release testnet-0.2.15 upgrade-proposal
  ./gdc.sh --release testnet-0.2.15 upgrade-worker <proposal-id>
  ./gdc.sh --release testnet-0.2.15 advance-after-upgrade <proposal-id>
  ./gdc.sh --release testnet-0.2.15 advance-after-upgrade-worker <proposal-id>
  ./gdc.sh --release testnet-0.2.15 upgrade
  ./gdc.sh ha v4
  ./gdc.sh bridge sepolia
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
  prepare|identities|verify|reset|settle|qualify-ml|audit|telegram-bot)
    [[ "$COMMAND" == reset || $# -eq 0 ]] || { usage; exit 2; }
    if [[ "$COMMAND" == reset ]]; then
      exec "$ROOT/scripts/phase-reset.sh" "$@"
    fi
    if [[ "$COMMAND" == telegram-bot ]]; then
      run_phase telegram-bot "$ROOT/scripts/deploy-telegram-bot.sh"
    elif [[ "$COMMAND" == audit ]]; then
      run_phase lifecycle-audit "$ROOT/scripts/phase-audit-lifecycle.sh"
    else
      run_phase "$COMMAND" "$ROOT/scripts/phase-$COMMAND.sh" "$@"
    fi
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
    [[ $# -eq 1 && "$1" =~ ^(gateway|monitoring|site|meter|explorer|edge)$ ]] || { usage; exit 2; }
    run_phase "ops-$1" "$ROOT/scripts/phase-ops.sh" "$1"
    ;;
  node)
    [[ $# -eq 2 && "$1" =~ ^(stop|start|verify)$ ]] || { usage; exit 2; }
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
  bridge)
    [[ $# -eq 1 && "$1" == sepolia ]] || { usage; exit 2; }
    run_phase bridge-sepolia "$ROOT/scripts/phase-bridge-sepolia.sh"
    ;;
  join)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    run_phase "join-$1" "$ROOT/scripts/phase-join.sh" "$1"
    ;;
  help|-h|--help) usage ;;
  *) echo "Unknown phase: $COMMAND" >&2; usage; exit 2 ;;
esac
