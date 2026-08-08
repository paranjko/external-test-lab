#!/usr/bin/env bash
set -Eeuo pipefail

kit_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

evidence_exit_trap() {
  local rc=$?
  if (( rc != 0 )) && [[ -n "${RUN:-}" && -d "$RUN" && ! -s "$RUN/verdict.md" ]]; then
    cat >"$RUN/verdict.md" <<EOF
# ${EVIDENCE_VERDICT_HEADING:-Lifecycle phase}: INCONCLUSIVE

The phase stopped with exit code $rc before it could write its final verdict.
Inspect the run log and evidence in this directory. No PASS is implied.
EOF
  fi
}

install_evidence_exit_trap() {
  [[ $# -eq 1 && -n "$1" ]] || die 'evidence verdict heading is required'
  EVIDENCE_VERDICT_HEADING="$1"
  trap evidence_exit_trap EXIT
}

load_env() {
  local file="$1"
  [[ -s "$file" ]] || die "missing environment file: $file"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

load_public_observability_hosts() {
  SITE_HOST="${GDC_SITE_HOST:-gonka-dev.net}"
  GRAFANA_HOST="${GDC_GRAFANA_HOST:-grafana.gonka-dev.net}"
}

# Every participant is identified by an operator-provided SSH alias.  Public
# DNS, hardware profile and an optional separate ML host belong to that alias;
# no lifecycle command may infer them from a particular lab host name.
topology_value() {
  local mapping="$1" key="$2" entry name value
  for entry in $mapping; do
    name="${entry%%=*}"
    value="${entry#*=}"
    [[ "$name" == "$key" && "$value" != "$entry" ]] && { printf '%s\n' "$value"; return 0; }
  done
  return 1
}

topology_contains_node() {
  local node="$1" candidate
  for candidate in "${GDC_NODES[@]}"; do [[ "$candidate" == "$node" ]] && return 0; done
  return 1
}

node_public_host() { topology_value "$GDC_NODE_PUBLIC_HOSTS" "$1" || die "no public host configured for SSH alias $1"; }
node_gpu_profile() { topology_value "$GDC_NODE_GPU_PROFILES" "$1" || die "no GPU profile configured for SSH alias $1"; }
node_p2p_port() { topology_value "$GDC_NODE_P2P_PORTS" "$1" || printf '%s\n' 5000; }
node_ml_host() { topology_value "${GDC_NODE_ML_HOSTS:-}" "$1"; }

node_for_ml_host() {
  local ml_host="$1" node
  for node in "${GDC_NODES[@]}"; do
    [[ "$(node_ml_host "$node" || true)" == "$ml_host" ]] && { printf '%s\n' "$node"; return 0; }
  done
  return 1
}

load_topology() {
  [[ -n "${GDC_NODE_ALIASES:-}" ]] || die 'set GDC_NODE_ALIASES in .env'
  read -r -a GDC_NODES <<<"$GDC_NODE_ALIASES"
  (( ${#GDC_NODES[@]} >= 1 )) || die 'GDC_NODE_ALIASES must contain at least one SSH alias'
  local -A seen=() ml_seen=()
  local node host profile ml_alias
  for node in "${GDC_NODES[@]}"; do
    [[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid SSH alias in GDC_NODE_ALIASES: $node"
    [[ -z "${seen[$node]:-}" ]] || die "duplicate SSH alias in GDC_NODE_ALIASES: $node"
    seen[$node]=1
    host="$(node_public_host "$node")"
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid public host for $node: $host"
    profile="$(node_gpu_profile "$node")"
    [[ -n "$profile" ]] || die "empty GPU profile for $node"
    ml_alias="$(node_ml_host "$node" || true)"
    if [[ -n "$ml_alias" ]]; then
      [[ "$ml_alias" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid ML SSH alias for $node: $ml_alias"
      [[ -z "${seen[$ml_alias]:-}" ]] || die "ML SSH alias must differ from a validator alias: $ml_alias"
      [[ -z "${ml_seen[$ml_alias]:-}" ]] || die "network GPU SSH alias is mapped more than once: $ml_alias"
      ml_seen[$ml_alias]=1
    fi
  done
  GENESIS_NODE="${GDC_GENESIS_NODE:-${GDC_NODES[0]}}"
  PUBLIC_EDGE_NODE="${GDC_PUBLIC_EDGE_NODE:-$GENESIS_NODE}"
  GATEWAY_NODE="${GDC_GATEWAY_NODE:-$GENESIS_NODE}"
  TELEGRAM_BOT_HOST="${GDC_TELEGRAM_BOT_HOST:-$GATEWAY_NODE}"
  topology_contains_node "$GENESIS_NODE" || die "GDC_GENESIS_NODE is not in GDC_NODE_ALIASES: $GENESIS_NODE"
  topology_contains_node "$PUBLIC_EDGE_NODE" || die "GDC_PUBLIC_EDGE_NODE is not in GDC_NODE_ALIASES: $PUBLIC_EDGE_NODE"
  topology_contains_node "$GATEWAY_NODE" || die "GDC_GATEWAY_NODE is not in GDC_NODE_ALIASES: $GATEWAY_NODE"
  topology_contains_node "$TELEGRAM_BOT_HOST" || die "GDC_TELEGRAM_BOT_HOST is not in GDC_NODE_ALIASES: $TELEGRAM_BOT_HOST"
  GENESIS_PUBLIC_HOST="$(node_public_host "$GENESIS_NODE")"
  PUBLIC_EDGE_HOST="$(node_public_host "$PUBLIC_EDGE_NODE")"

  # Render templates still use positional NODE<n> variables.  They are derived
  # from the supplied alias inventory here, never assigned to this lab's DNS
  # names or hardware.  Lifecycle scripts use the alias helpers above.
  local index=0 ml_alias ml_endpoint
  for node in "${GDC_NODES[@]}"; do
    printf -v "NODE${index}_PUBLIC_HOST" '%s' "$(node_public_host "$node")"
    printf -v "NODE${index}_GPU_PROFILE" '%s' "$(node_gpu_profile "$node")"
    printf -v "NODE${index}_P2P_PORT" '%s' "$(node_p2p_port "$node")"
    ml_alias="$(node_ml_host "$node" || true)"
    if [[ -n "$ml_alias" ]]; then
      ml_endpoint="$(ssh -G "$ml_alias" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
      [[ -n "$ml_endpoint" ]] || die "cannot determine ML endpoint from SSH alias $ml_alias"
      printf -v "NODE${index}_ML_ENDPOINT" '%s' "$ml_endpoint"
      printf -v "NODE${index}_ML_MONITOR_HOST" '%s' "$ml_endpoint"
    fi
    index=$((index + 1))
  done
}

write_env() {
  local file="$1"
  shift
  install -d -m 0700 "$(dirname "$file")"
  umask 077
  printf '%s\n' "$@" >"$file"
}

capture_canonical_genesis() {
  local endpoint="$1" output="$2" raw
  raw="$(mktemp)"
  if ! curl -fsS --max-time 15 "$endpoint" >"$raw"; then
    rm -f "$raw"
    return 1
  fi
  if ! jq -eS '.result.genesis' "$raw" >"$output"; then
    rm -f "$raw" "$output"
    return 1
  fi
  rm -f "$raw"
}

genesis_sha256() {
  [[ -s "$1" ]] || return 1
  sha256sum "$1" | awk '{print $1}'
}

# Variables initialized here are consumed by scripts that source this library.
# shellcheck disable=SC2034
load_project() {
  ROOT="$(kit_root)"
  ENV_FILE="${GDC_ENV:-$ROOT/.env}"
  [[ -s "$ENV_FILE" ]] || die "create $ROOT/.env from .env.example"
  # A shell invocation is the explicit per-rehearsal override.  Do not let an
  # empty example value in .env silently re-include an intentionally skipped
  # host (for example: GDC_SKIP_HOSTS='validator-b validator-c' ./gdc.sh prepare).
  local caller_skip_hosts='' resolved_profile_key
  local caller_skip_hosts_set=false
  if [[ ${GDC_SKIP_HOSTS+x} ]]; then
    caller_skip_hosts="$GDC_SKIP_HOSTS"
    caller_skip_hosts_set=true
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/profile.sh"
  resolved_profile_key="${GDC_RELEASE_PROFILE:-testnet-0.2.14}+${GDC_DEPLOYMENT_PROFILE:-community-lab}+${GDC_OPERATOR_SERVICES_PROFILE:-gdc-lab}"
  if [[ -z "${GDC_RESOLVED_IMAGE_LOCK:-}" && -r "$ROOT/state/resolved-images/$resolved_profile_key.lock" ]]; then
    export GDC_RESOLVED_IMAGE_LOCK="$ROOT/state/resolved-images/$resolved_profile_key.lock"
  fi
  load_profiles
  set +a
  if [[ "$caller_skip_hosts_set" == true ]]; then
    export GDC_SKIP_HOSTS="$caller_skip_hosts"
  fi

  # Keep a fresh Community DevNet recognisable across its reproducible
  # baseline and upgrade rehearsals. An explicit deployment override remains
  # possible through .env for an isolated experiment.
  CHAIN_ID="${CHAIN_ID:-gonka-devnet-community}"
  BASE_DENOM=ngonka
  BASE_DOMAIN=gonka-dev.net
  load_public_observability_hosts
  API_HOST=api.gonka-dev.net
  TELEGRAM_BOT_URL="${GDC_TELEGRAM_BOT_URL:-}"
  if [[ -n "$TELEGRAM_BOT_URL" && ! "$TELEGRAM_BOT_URL" =~ ^https://t\.me/[A-Za-z0-9_]{5,32}$ ]]; then
    die 'GDC_TELEGRAM_BOT_URL must be https://t.me/<bot_username>; never put a BotFather token here'
  fi
  load_topology
  DATA_ROOT=/srv/dai
  GENESIS_INSTALL_PATH=/srv/dai/shared/genesis.json
  HF_CACHE_ROOT=/srv/dai/hf-cache
  GRAFANA_PUBLIC_DASHBOARD_UID=gdc-overview
  # Public-dashboard URLs are intentionally capability links, not credentials.
  # Keep this stable so re-running ops monitoring repairs the same share.
  GRAFANA_PUBLIC_DASHBOARD_SHARE_UID=5fd40e12-5334-4d32-aea2-dcfe85afb3f2
  GRAFANA_PUBLIC_DASHBOARD_TOKEN=321a0d961e7f4b4ea6da843777c032eb

  mapfile -t genesis_addresses < <(getent ahostsv4 "$GENESIS_PUBLIC_HOST" | awk '{print $1}' | sort -u)
  (( ${#genesis_addresses[@]} == 1 )) || die "$GENESIS_PUBLIC_HOST must resolve to exactly one IPv4 address"
  MONITORING_CIDR="${genesis_addresses[0]}/32"
  mapfile -t edge_addresses < <(getent ahostsv4 "$PUBLIC_EDGE_HOST" | awk '{print $1}' | sort -u)
  (( ${#edge_addresses[@]} == 1 )) || die "$PUBLIC_EDGE_HOST must resolve to exactly one IPv4 address"
  PUBLIC_EDGE_CIDR="${edge_addresses[0]}/32"

  require ACME_EMAIL
  STATE="$ROOT/state"
  SECRETS="$STATE/secrets"
  IDENTITIES="$STATE/identities"
  GENERATED="$STATE/generated"
  GENESIS="$ROOT/artifacts/genesis"
  ACCOUNTS="$ROOT/artifacts/accounts"
  INVENTORY="$STATE/inventory.env"
  mkdir -p "$STATE" "$ROOT/artifacts"
  GDC_RUN_ID="${GDC_RUN_ID:-$(cat "$STATE/active-run-id" 2>/dev/null || true)}"
  if [[ -n "$GDC_RUN_ID" ]]; then
    GDC_RUN_LOG="${GDC_RUN_LOG:-$ROOT/artifacts/runs/$GDC_RUN_ID/run.log}"
    export GDC_RUN_ID GDC_RUN_LOG
  fi
  write_inventory
}

record_phase_profile() {
  local phase="$1" file
  file="$STATE/phase-profiles/$phase.env"
  mkdir -p "$(dirname "$file")"
  {
    profile_summary
    printf 'profile_hash=%s\n' "$(profile_hash)"
  } >"$file"
  while IFS= read -r line; do
    printf 'PROFILE phase=%s %s\n' "$phase" "$line"
  done <"$file"
}

assert_baseline_release() {
  [[ "$GDC_RELEASE_PROFILE" == testnet-0.2.14 ]] || die "baseline phases require testnet-0.2.14, got $GDC_RELEASE_PROFILE"
}

require_ml_qualification() {
  local host="$1" report
  report="$(latest_ml_qualification_report "$host" || true)"
  [[ -n "$report" ]] || \
    die "no successful ML qualification for $host; run ./gdc.sh qualify-ml ${host%-ml} before creating its chain participant"
  jq -e --arg model "$MODEL_ID" '.data[] | select(.id == $model)' "$report/models.json" >/dev/null || die "$host qualification does not prove $MODEL_ID"
  jq -e '.choices[0].message.content | type == "string"' "$report/completion.json" >/dev/null || die "$host qualification lacks a completion"
}

ensure_ml_qualification() {
  local host="$1" warn
  local auto_qualify="${GDC_AUTO_QUALIFY_ML:-1}"
  if latest_ml_qualification_report "$host" >/dev/null; then
    if require_ml_qualification "$host" >/dev/null 2>&1; then
      return 0
    fi
    warn="qualification for $host exists but is not valid for current model or completion"
  else
    warn='no successful ML qualification evidence found'
  fi

  if [[ "$auto_qualify" == 0 || "$auto_qualify" == false ]]; then
    die "${warn}; run ./gdc.sh qualify-ml ${host%-ml} before creating its chain participant"
  fi

  step "${warn^}, running qualification for $host automatically"
  GDC_QUALIFY_HOSTS="$host" "$ROOT/scripts/phase-qualify-ml.sh"
  require_ml_qualification "$host"
}

# Qualification attempts may fail after creating their report directory. Select
# the newest complete evidence bundle instead of letting an incomplete later
# attempt hide a prior successful qualification for the same pinned model.
latest_ml_qualification_report() {
  local host="$1" report
  while IFS= read -r report; do
    [[ -s "$report/models.json" && -s "$report/completion.json" && -s "$report/vram.csv" ]] || continue
    printf '%s\n' "$report"
    return 0
  done < <(find "$ROOT/artifacts/runs" -mindepth 2 -maxdepth 2 -type d -path "*-ml-qualification/$host" -print 2>/dev/null | LC_ALL=C sort -r)
  return 1
}

require() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" && "${!name}" != REPLACE_* ]] || die "set $name in .env"
  done
}

host_is_skipped() {
  local host="$1" skipped
  for skipped in ${GDC_SKIP_HOSTS:-}; do
    [[ "$skipped" == "$host" ]] && return 0
  done
  return 1
}

# This affects only the vLLM kernel implementation, not the pinned model,
# revision, dtype, context, or PoC parameters. Tesla T4 (Turing) cannot run
# FlashAttention/FlashInfer, whereas the other configured P0 GPUs can.
attention_backend_for_profile() {
  case "$1" in
    t4-16g) printf '%s\n' XFORMERS ;;
    *) printf '%s\n' FLASHINFER ;;
  esac
}

write_inventory() {
  umask 077
  inventory_value() { printf '%s=%q\n' "$1" "$2"; }
  {
    inventory_value CHAIN_ID "$CHAIN_ID"
    inventory_value BASE_DENOM "$BASE_DENOM"
    inventory_value BASE_DOMAIN "$BASE_DOMAIN"
    inventory_value SITE_HOST "$SITE_HOST"
    inventory_value API_HOST "$API_HOST"
    inventory_value GRAFANA_HOST "$GRAFANA_HOST"
    inventory_value ACME_EMAIL "$ACME_EMAIL"
    inventory_value MONITORING_CIDR "$MONITORING_CIDR"
    inventory_value PUBLIC_EDGE_CIDR "$PUBLIC_EDGE_CIDR"
    inventory_value GDC_NODE_ALIASES "$GDC_NODE_ALIASES"
    inventory_value GDC_NODE_PUBLIC_HOSTS "$GDC_NODE_PUBLIC_HOSTS"
    inventory_value GDC_NODE_GPU_PROFILES "$GDC_NODE_GPU_PROFILES"
    inventory_value GDC_NODE_P2P_PORTS "$GDC_NODE_P2P_PORTS"
    inventory_value GDC_NODE_ML_HOSTS "${GDC_NODE_ML_HOSTS:-}"
    inventory_value GENESIS_NODE "$GENESIS_NODE"
    inventory_value GENESIS_PUBLIC_HOST "$GENESIS_PUBLIC_HOST"
    inventory_value GENESIS_P2P_PORT "$(node_p2p_port "$GENESIS_NODE")"
    inventory_value PUBLIC_EDGE_NODE "$PUBLIC_EDGE_NODE"
    inventory_value PUBLIC_EDGE_HOST "$PUBLIC_EDGE_HOST"
    inventory_value GATEWAY_NODE "$GATEWAY_NODE"
    inventory_value TELEGRAM_BOT_HOST "$TELEGRAM_BOT_HOST"
    inventory_value GRAFANA_PUBLIC_DASHBOARD_UID "$GRAFANA_PUBLIC_DASHBOARD_UID"
    inventory_value GRAFANA_PUBLIC_DASHBOARD_SHARE_UID "$GRAFANA_PUBLIC_DASHBOARD_SHARE_UID"
    inventory_value GRAFANA_PUBLIC_DASHBOARD_TOKEN "$GRAFANA_PUBLIC_DASHBOARD_TOKEN"
    inventory_value TELEGRAM_BOT_URL "$TELEGRAM_BOT_URL"
    inventory_value DATA_ROOT "$DATA_ROOT"
    inventory_value GENESIS_INSTALL_PATH "$GENESIS_INSTALL_PATH"
    inventory_value HF_CACHE_ROOT "$HF_CACHE_ROOT"
  } >"$INVENTORY"
  local index=0 node endpoint_var monitor_var
  for node in "${GDC_NODES[@]}"; do
    inventory_value "NODE${index}_PUBLIC_HOST" "$(node_public_host "$node")" >>"$INVENTORY"
    inventory_value "NODE${index}_P2P_PORT" "$(node_p2p_port "$node")" >>"$INVENTORY"
    inventory_value "NODE${index}_GPU_PROFILE" "$(node_gpu_profile "$node")" >>"$INVENTORY"
    if [[ -n "$(node_ml_host "$node" || true)" ]]; then
      endpoint_var="NODE${index}_ML_ENDPOINT"
      monitor_var="NODE${index}_ML_MONITOR_HOST"
      inventory_value "NODE${index}_ML_ENDPOINT" "${!endpoint_var:-}" >>"$INVENTORY"
      inventory_value "NODE${index}_ML_MONITOR_HOST" "${!monitor_var:-}" >>"$INVENTORY"
    fi
    index=$((index + 1))
  done
}

node_name() {
  local node="${1:-}"
  topology_contains_node "$node" || die "unknown SSH alias: $node"
  [[ "$node" != "$GENESIS_NODE" ]] || die "cannot join the Genesis node: $node"
  printf '%s\n' "$node"
}

node_url() {
  local node="$1"
  topology_contains_node "$node" || die "unknown SSH alias: $node"
  # A split public edge can proxy the genesis participant.  This is a role
  # relationship, not a statement about a numbered node.
  if [[ "$node" == "$GENESIS_NODE" && "${GDC_GENESIS_PUBLIC_VIA_EDGE:-true}" == true ]]; then
    printf 'https://%s\n' "$PUBLIC_EDGE_HOST"
    return
  fi
  printf 'https://%s\n' "$(node_public_host "$node")"
}

participant_onboarding_state() {
  case "${1:-}" in
    ACTIVE|PARTICIPANT_STATUS_ACTIVE|1) printf '%s\n' active ;;
    INVALID|PARTICIPANT_STATUS_INVALID|3) printf '%s\n' invalid ;;
    '') printf '%s\n' new ;;
    *) printf '%s\n' registered ;;
  esac
}

reset_evidence_bundle_is_valid() {
  local bundle="$1"
  shift
  [[ -d "$bundle" && -s "$bundle/public-reset-state.png" ]] || return 1
  [[ "$(od -An -tx1 -N8 "$bundle/public-reset-state.png" | tr -d ' \n')" == 89504e470d0a1a0a ]] || return 1
  [[ -s "$bundle/verdict.md" ]] && grep -qx '# DevNet reset preservation: PASS' "$bundle/verdict.md" || return 1
  [[ -s "$bundle/pre-reset.env" ]] || return 1
  grep -Eq '^pre_reset_chain_id=[a-zA-Z0-9._-]+$' "$bundle/pre-reset.env" || return 1
  grep -Eq '^pre_reset_genesis_sha256=[0-9a-f]{64}$' "$bundle/pre-reset.env" || return 1
  [[ -f "$bundle/artifacts-runs.before.sha256" && -f "$bundle/artifacts-runs.after.sha256" ]] || return 1
  cmp -s "$bundle/artifacts-runs.before.sha256" "$bundle/artifacts-runs.after.sha256" || return 1

  local host
  for host in "$@"; do
    [[ -s "$bundle/$host.before" && -s "$bundle/$host.after" ]] || return 1
    cmp -s "$bundle/$host.before" "$bundle/$host.after" || return 1
  done
}

write_upgrade_blocked_verdict() {
  local file="$1" stage="${2:-unknown}" node="${3:-none}" completed="${4:-none}" rc="${5:-1}"
  cat >"$file" <<EOF
# DevNet upgrade: BLOCKED

- Failed stage: $stage
- Failed node: $node
- Completed target nodes: $completed
- Exit status: $rc

Do not reset Genesis and do not downgrade a node after the approved upgrade
height. Preserve this bundle, diagnose the failed node, restore its pinned
target deployment, and rerun the same command:
./gdc.sh --release testnet-0.2.15 upgrade
The command permits a
resume only when every already changed node has the exact target profile
marker; a third or mixed release remains a hard failure.
EOF
}

ssh_ready() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
    "$1" true </dev/null >/dev/null 2>&1
}

configured_node_indexes() {
  local index=0 node
  for node in "${GDC_NODES[@]}"; do
    [[ -e "$STATE/joined/$node" ]] && printf '%s\n' "$index"
    index=$((index + 1))
  done
}

configured_nodes() {
  local node
  for node in "${GDC_NODES[@]}"; do
    [[ -e "$STATE/joined/$node" ]] && printf '%s\n' "$node"
  done
}

node_index() {
  local wanted="$1" index=0 node
  for node in "${GDC_NODES[@]}"; do
    [[ "$node" == "$wanted" ]] && { printf '%s\n' "$index"; return 0; }
    index=$((index + 1))
  done
  die "unknown SSH alias: $wanted"
}

latest_baseline_pass_bundle() {
  local verdict bundle environment genesis_profile_hash
  genesis_profile_hash="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$STATE/phase-profiles/genesis.env" 2>/dev/null || true)"
  [[ -n "$genesis_profile_hash" ]] || return 1
  while IFS= read -r verdict; do
    grep -qx '# DevNet verification: PASS' "$verdict" || continue
    bundle="$(dirname "$verdict")"
    environment="$bundle/environment.txt"
    [[ -s "$environment" && -s "$bundle/node-sync.json" && -s "$bundle/participants.json" ]] || continue
    grep -qx 'release_profile=testnet-0.2.14' "$environment" || continue
    grep -qx "chain_id=$CHAIN_ID" "$environment" || continue
    grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$environment" || continue
    grep -qx "profile_hash=$genesis_profile_hash" "$environment" || continue
    printf '%s\n' "$bundle"
    return 0
  done < <(find "$ROOT/artifacts/runs" -mindepth 2 -maxdepth 2 -name verdict.md -print 2>/dev/null | LC_ALL=C sort -r)
  return 1
}

# An old Genesis marker is not proof that the current live topology passed the
# P0 baseline gate. Before any upgrade action, require a matching verify bundle
# and reconcile it with local joined state, committed chain participants, live
# node services and caught-up public RPC endpoints.
require_current_baseline_pass() {
  local bundle index node address marker status node_height node_catching
  local reference_height lag genesis_profile_hash
  local -a indexes expected_addresses live_addresses evidence_nodes

  step 'Require a current 0.2.14 baseline PASS before the upgrade lifecycle'
  bundle="$(latest_baseline_pass_bundle || true)"
  [[ -n "$bundle" ]] || die 'no matching 0.2.14 verification PASS; restore every intended participant and run ./gdc.sh --release testnet-0.2.14 verify'

  mapfile -t indexes < <(configured_node_indexes)
  (( ${#indexes[@]} > 0 )) || die 'no joined participants are recorded for the verified baseline'
  mapfile -t evidence_nodes < <(jq -er '.[].node' "$bundle/node-sync.json" | LC_ALL=C sort)
  ((${#evidence_nodes[@]} == ${#indexes[@]})) || die 'baseline PASS participant count differs from current joined state; run verify again'

  expected_addresses=()
  reference_height="$(ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:26657/status' | jq -er '.result.sync_info.latest_block_height | tonumber')"
  genesis_profile_hash="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$STATE/phase-profiles/genesis.env")"
  for node in "${GDC_NODES[@]}"; do
    [[ -e "$STATE/joined/$node" ]] || continue
    grep -qx "$node" <(printf '%s\n' "${evidence_nodes[@]}") || die "$node is absent from the baseline PASS bundle; run verify again"
    address="$(jq -er .address "$ACCOUNTS/$node-cold.json")"
    expected_addresses+=("$address")
    marker="$(ssh "$node" "cat /srv/dai/deploy/$node/.gdc-release 2>/dev/null || true")"
    [[ "$marker" == "testnet-0.2.14 $genesis_profile_hash" ]] || die "$node does not have the verified 0.2.14 deployment marker"
    ssh -T "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env ps node api proxy explorer --format '{{.Service}} {{.State}}'" \
      | awk '
          $1 == "node" || $1 == "api" || $1 == "proxy" || $1 == "explorer" { seen[$1]=1; if ($2 != "running") bad=1 }
          END { exit bad || !(seen["node"] && seen["api"] && seen["proxy"] && seen["explorer"]) }
        ' || die "$node does not have all required Network Node services running"
    status="$(curl -fsS "$(node_url "$node")/chain-rpc/status")"
    node_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$status")"
    node_catching="$(jq -r '.result.sync_info.catching_up | tostring' <<<"$status")"
    lag=$(( reference_height > node_height ? reference_height - node_height : node_height - reference_height ))
    [[ "$node_catching" == false && "$lag" -le "${GDC_MAX_NODE_LAG_BLOCKS:-5}" ]] \
      || die "$node is not currently synchronized (height=$node_height reference=$reference_height lag=$lag catching_up=$node_catching)"
  done

  mapfile -t expected_addresses < <(printf '%s\n' "${expected_addresses[@]}" | LC_ALL=C sort -u)
  mapfile -t live_addresses < <(
    ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant' \
      | jq -er '.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1") | .address' \
      | LC_ALL=C sort -u
  )
  [[ "$(printf '%s\n' "${expected_addresses[@]}")" == "$(printf '%s\n' "${live_addresses[@]}")" ]] \
    || die 'ACTIVE chain participants differ from current joined state; restore/reset the topology and run verify again'

  printf 'PASS current baseline evidence: %s (%s participants)\n' "$bundle" "${#indexes[@]}"
}

start_stack() {
  local host="$1" path="$2"
  printf 'WAIT  start %s:%s\n' "$host" "$path"
  if ssh "$host" "cd '$path' && docker compose up -d >start.log 2>&1"; then
    printf 'READY started %s:%s\n' "$host" "$path"
  else
    ssh "$host" "tail -100 '$path/start.log'" >&2 || true
    return 1
  fi
}
