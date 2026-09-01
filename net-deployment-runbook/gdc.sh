#!/usr/bin/env bash
set -Eeuo pipefail

LAUNCHER_SOURCE="${BASH_SOURCE[0]}"
LAUNCHER_PATH="$(realpath -e -- "$LAUNCHER_SOURCE")"
ROOT="$(cd "$(dirname "$LAUNCHER_PATH")" && pwd)"
if [[ "${LAUNCHER_SOURCE##*/}" == gdc.sh ]]; then
  GDC_USAGE_COMMAND='./gdc.sh'
else
  GDC_USAGE_COMMAND="${LAUNCHER_SOURCE##*/}"
fi

GDC_LAUNCHER_EXIT_RECORDED=false

record_launcher_failure() {
  local rc="$1" tmp failure_dir
  [[ "$rc" -ne 0 && -n "${GDC_LAUNCHER_ENVELOPE_DIR:-}" ]] || return 0
  # A report-publication failure retains its own local draft; making it the
  # latest incident would recursively hide the selected operational failure.
  [[ "${GDC_REPORT_MODE:-false}" != true ]] || return 0
  [[ "$GDC_LAUNCHER_EXIT_RECORDED" != true ]] || return 0
  GDC_LAUNCHER_EXIT_RECORDED=true
  failure_dir="${GDC_DATA_ROOT:?}/reporting/failures"
  mkdir -p "$failure_dir"
  chmod 0700 "${GDC_DATA_ROOT:?}/reporting" "$failure_dir" 2>/dev/null || true
  tmp="$failure_dir/.latest-failure.$$.tmp"
  {
    printf 'schema_version=1\n'
    printf 'invocation_id=%s\n' "$GDC_LAUNCHER_INVOCATION_ID"
    printf 'exit_code=%s\n' "$rc"
    printf 'failure_stage=%s\n' "${GDC_ACTIVE_PHASE:-pre-phase}"
    printf 'active_phase=%s\n' "${GDC_ACTIVE_PHASE:-unavailable}"
    printf 'run_id=%s\n' "${GDC_RUN_ID:-unavailable}"
    printf 'run_log=%s\n' "${GDC_RUN_LOG:-unavailable}"
    [[ -z "${GDC_RUN_ID:-}" ]] || printf 'run_manifest=%s\n' "$GDC_HOME/runs/$GDC_RUN_ID/manifest.env"
    printf 'envelope=%s\n' "$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"
    [[ -z "${GDC_DIAGNOSTIC_ENVELOPE:-}" ]] || printf 'diagnostic_envelope=%s\n' "$GDC_DIAGNOSTIC_ENVELOPE"
    [[ -z "${GDC_JOIN_PREFLIGHT_RECEIPT:-}" ]] || printf 'preflight_receipt=%s\n' "$GDC_JOIN_PREFLIGHT_RECEIPT"
    printf 'recorded_at=%s\n' "$(date -u +%FT%TZ)"
  } >"$GDC_LAUNCHER_ENVELOPE_DIR/failure.env"
  chmod 0600 "$GDC_LAUNCHER_ENVELOPE_DIR/failure.env"
  printf '%s\n' "$GDC_LAUNCHER_INVOCATION_ID" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$failure_dir/latest-failure"
  printf 'Hint: review the retained local failure and run gdc report github when you are ready to disclose a sanitized report.\n' >&2
}

on_launcher_exit() {
  local rc="$?"
  trap - EXIT
  set +e
  record_launcher_failure "$rc"
  exit "$rc"
}

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

initialize_launcher_envelope() {
  local base
  base="$GDC_DATA_ROOT/reporting/invocations"
  mkdir -p "$base"
  chmod 0700 "$GDC_DATA_ROOT/reporting" "$base" 2>/dev/null || true
  GDC_LAUNCHER_ENVELOPE_DIR="$(mktemp -d "$base/invocation.XXXXXX")"
  GDC_LAUNCHER_INVOCATION_ID="${GDC_LAUNCHER_ENVELOPE_DIR##*/invocation.}"
  chmod 0700 "$GDC_LAUNCHER_ENVELOPE_DIR"
  {
    printf 'schema_version=1\n'
    printf 'invocation_id=%s\n' "$GDC_LAUNCHER_INVOCATION_ID"
    printf 'created_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'runbook_revision=%s\n' "$(runbook_revision)"
    printf 'gdc_launcher_sha256=%s\n' "$(gdc_launcher_sha256)"
  } >"$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"
  chmod 0600 "$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"
  export GDC_LAUNCHER_ENVELOPE_DIR GDC_LAUNCHER_INVOCATION_ID
}

initialize_launcher_envelope
trap on_launcher_exit EXIT

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
  printf '%q%s\n' 'gdc' "$rendered"
}

run_phase() {
  local phase="$1"
  shift
  local state run_id_file run_id run_dir log rc diagnostic_envelope
  state="$STATE"
  acquire_operator_lock
  run_id_file="$state/active-run-id"
  mkdir -p "$state"
  # An assurance adapter owns one evidence namespace per scenario execution.
  # Do not silently append it to the last operator's lifecycle run.
  if [[ -n "${GDC_ASSURANCE_RUN_ID:-}" ]]; then
    run_id="assurance-${GDC_ASSURANCE_RUN_ID}"
    printf '%s\n' "$run_id" >"$run_id_file"
  elif [[ "${GDC_FORCE_NEW_RUN:-false}" == true || "${GDC_JOIN_RECOVERY_NEW_RUN:-false}" == true ]]; then
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
  if (( rc != 0 )); then
    diagnostic_envelope="$(find "$run_dir" -maxdepth 2 -type f -name diagnostic-envelope.v1.json -print 2>/dev/null | LC_ALL=C sort | tail -n1 || true)"
    if [[ -z "$diagnostic_envelope" ]]; then
      "$ROOT/scripts/phase-diagnostic-adapter.sh" "$run_dir/diagnostic-envelope.v1.json" "$phase" "$rc"
      diagnostic_envelope="$run_dir/diagnostic-envelope.v1.json"
    fi
    [[ -z "$diagnostic_envelope" ]] || export GDC_DIAGNOSTIC_ENVELOPE="$diagnostic_envelope"
  fi
  set -e
  return "$rc"
}

run_join_preflight() {
  local checkpoint="$1" state="$2" category="$3" tool="$4" summary="$5" rc diagnostic typed
  shift 5
  if "$@"; then
    return 0
  else
    rc=$?
  fi
  if [[ "$category" == lineage && -r "${GDC_JOIN_LINEAGE_FAILURE_FILE:-}" ]]; then
    typed="$(<"$GDC_JOIN_LINEAGE_FAILURE_FILE")"
    if [[ "$typed" =~ ^(rpc_quorum_conflict|rpc_fault_domain_alias|snapshot_unavailable|snapshot_incompatible|trust_expired|historical_replay_unsupported|apphash_divergence|lineage_verification_failed|signer_activation_unsafe)$ ]]; then
      tool="${typed//_/-}"
    fi
  fi
  # JOIN has not selected a local profile or touched a Host at this point.
  # Retain a bounded, structured diagnostic in the launcher envelope rather
  # than manufacturing a lifecycle manifest for an unselected release.
  GDC_ACTIVE_PHASE='join-preflight'
  diagnostic="$GDC_LAUNCHER_ENVELOPE_DIR/diagnostic-envelope.v1.json"
  "$ROOT/scripts/diagnostic-envelope.sh" write "$diagnostic" \
    join join-preflight "$checkpoint" "$state" "$category" "$tool" "$rc" \
    safe join-repeat "$summary"
  export GDC_DIAGNOSTIC_ENVELOPE="$diagnostic"
  write_join_preflight_receipt "$checkpoint" failed "$category" "$tool"
  printf 'ERROR JOIN preflight failed checkpoint=%s preflight_receipt=%s\n' \
    "$checkpoint" "$GDC_JOIN_PREFLIGHT_RECEIPT" >&2
  return "$rc"
}

initialize_join_preflight_receipt() {
  GDC_JOIN_PREFLIGHT_RECEIPT="$STATE/preflight-receipt.env"
  export GDC_JOIN_PREFLIGHT_RECEIPT
  write_join_preflight_receipt initialized pending unavailable unavailable
}

write_join_preflight_receipt() {
  local checkpoint="$1" result="$2" category="$3" tool="$4" tmp
  [[ -n "${GDC_JOIN_PREFLIGHT_RECEIPT:-}" ]] || return 0
  tmp="${GDC_JOIN_PREFLIGHT_RECEIPT}.tmp.$$"
  {
    printf 'schema_version=1\n'
    printf 'invocation_id=%s\n' "$GDC_LAUNCHER_INVOCATION_ID"
    printf 'checkpoint=%s\nresult=%s\ncategory=%s\ntool=%s\n' \
      "$checkpoint" "$result" "$category" "$tool"
    printf 'recorded_at=%s\n' "$(date -u +%FT%TZ)"
    [[ -z "${GDC_NETWORK_FINGERPRINT:-}" ]] || printf 'network_fingerprint=%s\n' "$GDC_NETWORK_FINGERPRINT"
    [[ -z "${GDC_NETWORK_CHAIN_ID:-}" ]] || printf 'chain_id=%s\n' "$GDC_NETWORK_CHAIN_ID"
    [[ -z "${GDC_NETWORK_GENESIS_SHA256:-}" ]] || printf 'genesis_sha256=%s\n' "$GDC_NETWORK_GENESIS_SHA256"
    [[ -z "${GDC_NETWORK_CORE_VERSION:-}" ]] || printf 'core_version=%s\ncore_commit=%s\n' "$GDC_NETWORK_CORE_VERSION" "$GDC_NETWORK_CORE_COMMIT"
    [[ -z "${GDC_NETWORK_DAPI_VERSION:-}" ]] || printf 'dapi_version=%s\ndapi_commit=%s\n' "$GDC_NETWORK_DAPI_VERSION" "$GDC_NETWORK_DAPI_COMMIT"
    [[ -z "${GDC_NETWORK_DEVSHARD_APPROVALS:-}" ]] || printf 'devshard_approvals=%q\n' "$GDC_NETWORK_DEVSHARD_APPROVALS"
    [[ -z "${GDC_RELEASE_PROFILE:-}" ]] || printf 'release_profile=%s\n' "$GDC_RELEASE_PROFILE"
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$GDC_JOIN_PREFLIGHT_RECEIPT"
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
  sed "s#\\./gdc\\.sh#$GDC_USAGE_COMMAND#g" <<'EOF'
Gonka DevNet Community manual deployment

See the role guides for required input, then run:
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] [--public-edge <SSH_ALIAS>] [--skip-qualification]
  ./gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>] [--public-edge <SSH_ALIAS>] --no-bootstrap-access
  ./gdc.sh --release v2026.07.23 baseline
  ./gdc.sh report github
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
  ./gdc.sh network bootstrap verify FILE
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
  ./gdc.sh --composition <COMPOSITION> governance devshard submit [--protocols v3,v4,v5]
  ./gdc.sh --composition <COMPOSITION> governance devshard verify <proposal-id> [--protocols v3,v4,v5]
  ./gdc.sh --release v2026.08.06 governance vote <proposal-id> [yes|no|abstain|no_with_veto]
  ./gdc.sh --release v2026.08.06 bridge contract deploy sepolia
  ./gdc.sh --release v2026.08.06 bridge contract register sepolia
  ./gdc.sh --release v2026.08.06 bridge observer apply|status|verify <SSH_ALIAS>
  ./gdc.sh release candidate prepare --source-ref ak/height-sync-protocol-dapi --layer core
  ./gdc.sh release candidate build <vYYYY.MM.DD-rc.N> [--dry-run] [--retry] [--wait]
  ./gdc.sh release candidate profile <vYYYY.MM.DD-rc.N> [--build-manifest <PATH>]
  ./gdc.sh release candidate verify <vYYYY.MM.DD-rc.N> [--build-manifest <PATH>]
  ./gdc.sh release composition create --core <CORE_PROFILE> --devshard <DEVSHARD_PROFILE> [--output <PATH>] [--materialize <PATH>]
  ./gdc.sh release composition verify <PATH|NAME>
  ./gdc.sh release composition materialize <PATH|NAME> [--output <PATH>]
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
  ./gdc.sh --composition <COMPOSITION> governance devshard [--protocols v3,v4,v5]
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
{
  printf 'safe_invocation=%q\n' "$GDC_INVOCATION_COMMAND"
  printf 'invocation_cwd=%q\n' "$GDC_INVOCATION_CWD"
} >>"$GDC_LAUNCHER_ENVELOPE_DIR/envelope.env"

RELEASE=''
MODEL=''
COMPOSITION=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:-}"; shift 2 ;;
    --release=*) RELEASE="${1#--release=}"; shift ;;
    --composition) COMPOSITION="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
if [[ -n "$COMPOSITION" ]]; then
  export GDC_COMPOSITION="$COMPOSITION"
  if [[ -r "$COMPOSITION" ]]; then
    :
  elif [[ "$COMPOSITION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && -r "$ROOT/profiles/compositions/$COMPOSITION.json" ]]; then
    :
  else
    echo "Unknown composition: $COMPOSITION" >&2
    exit 2
  fi
  composition_env="$("$ROOT/scripts/release-candidate.py" composition export-env "$COMPOSITION")" || exit $?
  eval "$composition_env"
  export GDC_COMPOSITION="$COMPOSITION"
fi
if [[ -n "$RELEASE" ]]; then
  [[ "$RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { echo "Invalid release profile: $RELEASE" >&2; exit 2; }
  [[ -r "$ROOT/profiles/releases/$RELEASE.lock" || -r "$ROOT/profiles/compositions/$RELEASE.json" || -r "$RELEASE" ]] || { echo "Unknown release: $RELEASE" >&2; exit 2; }
  [[ -z "$COMPOSITION" || "$RELEASE" == "$GDC_RELEASE_PROFILE" ]] \
    || { echo "Release profile $RELEASE conflicts with composition core profile $GDC_RELEASE_PROFILE" >&2; exit 2; }
  export GDC_RELEASE_PROFILE="$RELEASE"
fi
[[ -z "$MODEL" || "$MODEL" == qwen3-0.6b ]] || { echo "Unknown model overlay: $MODEL" >&2; exit 2; }
[[ -z "$MODEL" ]] || export GDC_MODEL_PROFILE="$MODEL"

is_upgrade_target_profile() {
  local profile="${GDC_RELEASE_PROFILE:-}" lock
  if [[ -n "${GDC_COMPOSITION:-}" ]]; then
    return 0
  fi
  [[ -n "$profile" ]] || return 1
  [[ "$profile" == v2026.08.06 ]] && return 0
  if [[ -f "$ROOT/profiles/compositions/$profile.json" || -f "$profile" ]]; then
    return 0
  fi
  lock="$ROOT/profiles/releases/$profile.lock"
  [[ -r "$lock" ]] && grep -Eq '^UPGRADE_FROM_PROFILE=[a-z0-9][a-z0-9.-]*$' "$lock"
}

configure_devshard_governance_protocols() {
  local raw="$1" protocol normalized=''
  local -a protocols=()
  [[ -n "$raw" ]] || { echo 'DevShard protocol list must not be empty' >&2; exit 2; }
  IFS=',' read -r -a protocols <<<"$raw"
  ((${#protocols[@]} > 0)) || { echo 'DevShard protocol list must not be empty' >&2; exit 2; }
  for protocol in "${protocols[@]}"; do
    [[ "$protocol" =~ ^v[1-9][0-9]*$ ]] || { echo "Invalid DevShard protocol: $protocol" >&2; exit 2; }
    case " $normalized " in
      *" $protocol "*) echo "Duplicate DevShard protocol: $protocol" >&2; exit 2 ;;
    esac
    normalized="${normalized:+$normalized }$protocol"
  done
  export GDC_GOVERNANCE_DEVSHARD_PROTOCOLS="$normalized"
}

COMMAND="${1:-help}"
shift || true

# Domain aliases make the authority boundary visible without invalidating
# existing executable evidence that still names the original lifecycle phases.
case "$COMMAND" in
  network)
    subcommand="${1:-}"; shift || true
    case "$subcommand" in
      bootstrap)
        if [[ "${1:-}" != verify ]] || { [[ "$#" -ne 2 ]] && { [[ "$#" -ne 3 || "${2:-}" != --online ]]; }; }; then
          usage
          exit 2
        fi
        COMMAND='network-bootstrap-verify'
        if [[ "${2:-}" == --online ]]; then set -- --online "$3"; else set -- "$2"; fi
        ;;
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
  network-bootstrap-verify)
    if [[ "${1:-}" == --online ]]; then
      [[ $# -eq 2 && -f "$2" && -r "$2" ]] || { echo 'network bootstrap verify --online requires one readable file' >&2; exit 2; }
      exec "$ROOT/scripts/network-bootstrap.sh" online "$2"
    fi
    [[ $# -eq 1 && -f "$1" && -r "$1" ]] || { echo 'network bootstrap verify requires one readable file' >&2; exit 2; }
    exec "$ROOT/scripts/network-bootstrap.sh" verify "$1"
    ;;
  release)
    case "${1:-}" in
      candidate)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        shift
        "$ROOT/scripts/release-candidate.py" "$@"
        ;;
      composition)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        "$ROOT/scripts/release-candidate.py" "$@"
        ;;
      *)
        usage; exit 2
        ;;
    esac
    ;;
  report)
    [[ "${1:-}" == github && $# -eq 1 ]] || { usage; exit 2; }
    export GDC_REPORT_MODE=true
    "$ROOT/scripts/gdc-report-github.sh"
    ;;
  public-network-verify|confirmation-poc|public-upgrade-verify)
    [[ $# -le 1 ]] || { usage; exit 2; }
    if [[ "$COMMAND" == confirmation-poc ]]; then
      use_network_owner_data_home
      use_operator_inventory
    fi
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
    if [[ "$COMMAND" == verify || "$COMMAND" == gateway-continuity || "$COMMAND" == audit ]]; then
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
    export GDC_FORCE_NEW_RUN=true
    use_network_owner_data_home
    governance_action="${1:-}"; shift || true
    if [[ "$governance_action" == devshard ]]; then
      case "${1:-}" in
        '') run_phase governance-devshard "$ROOT/scripts/phase-governance-devshard.sh" ;;
        --protocols)
          [[ $# -eq 2 ]] || { usage; exit 2; }
          configure_devshard_governance_protocols "$2"
          run_phase governance-devshard "$ROOT/scripts/phase-governance-devshard.sh"
          ;;
        submit)
          shift
          if [[ $# -gt 0 ]]; then
            [[ $# -eq 2 && "$1" == --protocols ]] || { usage; exit 2; }
            configure_devshard_governance_protocols "$2"
          fi
          GDC_GOVERNANCE_SUBMIT=true run_phase governance-devshard-submit "$ROOT/scripts/phase-governance-devshard.sh"
          ;;
        verify)
          shift
          proposal_id="${1:-}"
          [[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
          shift
          if [[ $# -gt 0 ]]; then
            [[ $# -eq 2 && "$1" == --protocols ]] || { usage; exit 2; }
            configure_devshard_governance_protocols "$2"
          fi
          GDC_GOVERNANCE_PROPOSAL_ID="$proposal_id" run_phase "governance-devshard-verify-$proposal_id" "$ROOT/scripts/phase-governance-devshard.sh"
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
    export GDC_FORCE_NEW_RUN=true
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
    join_alias='' join_gpu_alias='' join_public_host='' join_restore_archive='' join_bootstrap_file='' join_p2p_port='' skip_qualification=false verification=false
    # JOIN derives its exact compatible composition from independently
    # observed Bootstrap seeds. An operator-selected release or composition
    # could otherwise turn retained evidence into a software authority.
    [[ -z "$RELEASE" ]] || { echo 'host join does not accept --release; composition is selected from verified seed observations' >&2; exit 2; }
    [[ -z "$COMPOSITION" ]] || { echo 'host join does not accept --composition; composition is selected from verified seed observations' >&2; exit 2; }
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --release|--release=*|--composition|--composition=*)
          echo 'host join does not accept release or composition selectors; composition is selected from verified seed observations' >&2
          exit 2
          ;;
        --skip-qualification) skip_qualification=true ;;
        --verification) verification=true ;;
        --public-host)
          join_public_host="${2:-}"
          [[ "$join_public_host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'host join --public-host requires an IP address or domain' >&2; exit 2; }
          shift
          ;;
        --bootstrap-file)
          join_bootstrap_file="${2:-}"
          [[ -r "$join_bootstrap_file" ]] || { echo 'host join --bootstrap-file requires a readable file' >&2; exit 2; }
          join_bootstrap_file="$(realpath -e -- "$join_bootstrap_file")"
          shift
          ;;
        --p2p-port)
          join_p2p_port="${2:-}"
          [[ "$join_p2p_port" =~ ^[1-9][0-9]{0,4}$ && "$join_p2p_port" -le 65535 ]] || { echo 'host join --p2p-port requires a port from 1 through 65535' >&2; exit 2; }
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
    # Persist a bounded receipt before any Bootstrap fetch or network
    # observation. It is updated atomically as public facts become available.
    initialize_join_preflight_receipt
    # Bootstrap observation precedes both CLI installation and role-input
    # creation. The public network therefore selects the local immutable
    # profile before any software download or Host mutation.
    join_genesis="$GDC_HOME/genesis"
    join_secrets="$STATE/secrets"
    if [[ -z "$join_bootstrap_file" ]]; then
      join_bootstrap_file="$STATE/network-bootstrap.json"
      run_join_preflight bootstrap-fetch unavailable network curl \
        'The public Bootstrap descriptor could not be fetched and validated.' \
        "$ROOT/scripts/fetch-network-bootstrap.sh" --url https://gonka-dev.net/gonka-devnet-community/bootstrap.json --output "$join_bootstrap_file"
    else
      run_join_preflight bootstrap-verify invalid-bootstrap configuration bootstrap \
        'The supplied Bootstrap descriptor did not satisfy the local validation contract.' \
        "$ROOT/scripts/network-bootstrap.sh" verify "$join_bootstrap_file" >/dev/null
    fi
    join_composition="$STATE/network-composition.env"
    run_join_preflight software-observation unavailable network seed-observer \
      'Public seed observations did not establish one safe software composition.' \
      "$ROOT/scripts/observe-network-composition.sh" --bootstrap-file "$join_bootstrap_file" --output "$join_composition"
    # The observer only emits fixed-name, shell-quoted values after validating
    # the complete local lock mapping.
    unset GDC_COMPOSITION GDC_COMPOSITION_HASH
    # shellcheck disable=SC1090
    source "$join_composition"
    # Sourcing assigns shell variables but does not export them.  Every
    # subsequent helper is a child process, so export the network-selected
    # profile before installing its CLI, creating the run manifest, or
    # invoking the JOIN phase.
    export GDC_NETWORK_FINGERPRINT GDC_NETWORK_CHAIN_ID GDC_NETWORK_GENESIS_SHA256
    export GDC_NETWORK_COMETBFT_VERSION GDC_NETWORK_CORE_VERSION GDC_NETWORK_CORE_COMMIT
    export GDC_NETWORK_DAPI_VERSION GDC_NETWORK_DAPI_COMMIT GDC_NETWORK_DEVSHARD_APPROVALS
    export GDC_RELEASE_PROFILE
    write_join_preflight_receipt software-observation passed unavailable seed-observer
    join_lineage_receipt="$STATE/lineage-preflight.json"
    join_lineage_env="$STATE/lineage-preflight.env"
    GDC_JOIN_LINEAGE_FAILURE_FILE="$STATE/lineage-preflight.failure"
    export GDC_JOIN_LINEAGE_FAILURE_FILE
    rm -f "$GDC_JOIN_LINEAGE_FAILURE_FILE"
    run_join_preflight lineage-preflight refused lineage lineage-preflight \
      'Independent RPC lineage and trust were not established for native P2P state sync.' \
      "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$join_bootstrap_file" --composition-env "$join_composition" \
        --receipt "$join_lineage_receipt" --env "$join_lineage_env"
    # The preflight writes fixed-name, shell-quoted values only after it has
    # bound them to the observed runtime fingerprint and two fault domains.
    # shellcheck disable=SC1090
    source "$join_lineage_env"
    export GDC_JOIN_BOOTSTRAP_MODE GDC_JOIN_TRUST_HEIGHT GDC_JOIN_TRUST_HASH GDC_JOIN_SNAPSHOT_PEERS
    export GDC_JOIN_RPC_SERVER_1 GDC_JOIN_RPC_SERVER_2 GDC_JOIN_TRUSTED_BLOCK_PERIOD GDC_JOIN_LINEAGE_RECEIPT
    GDC_JOIN_LINEAGE_RECEIPT_SHA256="$(sha256sum "$GDC_JOIN_LINEAGE_RECEIPT" | awk '{print $1}')"
    export GDC_JOIN_LINEAGE_RECEIPT_SHA256
    write_join_preflight_receipt lineage-preflight passed unavailable lineage-preflight
    run_join_preflight inferenced-cli unavailable dependency inferenced \
      'The pinned operator CLI was not available after safe installation checks.' \
      "$ROOT/scripts/ensure-inferenced-cli.sh"
    run_join_preflight bootstrap-stage unavailable chain bootstrap \
       'The validated Bootstrap descriptor could not be staged locally.' \
       "$ROOT/scripts/stage-network-bootstrap.sh" --bootstrap-file "$join_bootstrap_file" --genesis-dir "$join_genesis" --state-dir "$STATE" --secrets-dir "$join_secrets"
    export GDC_JOIN_SKIP_QUALIFICATION="$skip_qualification"
    export GDC_JOIN_VERIFICATION="$verification"
    if [[ -n "$join_restore_archive" ]]; then
      export GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE="$join_restore_archive"
      # Recovery is not a continuation of a historical software decision.
      # It receives a new manifest bound to the currently observed network.
      export GDC_JOIN_RECOVERY_NEW_RUN=true
    fi
    join_role_ready=false
    join_role_config=''
    if [[ -n "${GDC_ENV:-}" && -s "$GDC_ENV" ]]; then
      join_role_config="$GDC_ENV"
    elif [[ -s "$GDC_HOME/.env" ]]; then
      join_role_config="$GDC_HOME/.env"
    elif [[ -s "$STATE/active-role-config" ]]; then
      join_role_config="$(<"$STATE/active-role-config")"
    fi
    if [[ -s "$join_role_config" ]]; then
      # This is a locally generated, mode-0600 role file.
      # shellcheck disable=SC1090
      source "$join_role_config"
    fi
    if [[ -s "$join_role_config" ]] && (
        # This is a locally generated, mode-0600 role file.
        # shellcheck disable=SC1090
        source "$join_role_config"
        # A bootstrap can rotate between attempts. Generated JOIN role inputs
        # therefore never bypass preparation on a new invocation.
        [[ "${GDC_JOIN_ROLE_INPUT:-false}" != true ]] || exit 1
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
      join_config_args+=(--bootstrap-file "$join_bootstrap_file")
      [[ -n "$join_public_host" ]] && join_config_args+=(--public-host "$join_public_host")
      [[ -n "$join_gpu_alias" ]] && join_config_args+=(--gpu-ssh-alias "$join_gpu_alias")
      [[ -n "$join_p2p_port" ]] && join_config_args+=(--p2p-port "$join_p2p_port")
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
