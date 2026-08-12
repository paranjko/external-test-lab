#!/usr/bin/env bash
set -Eeuo pipefail

kit_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

init_gdc_paths() {
  ROOT="${ROOT:-$(kit_root)}"
  local configured_home="${GDC_HOME:-$(dirname "$ROOT")/net-deployment-data}"
  [[ -n "$configured_home" ]] || { echo 'error: GDC_HOME must not be empty' >&2; return 1; }
  if [[ "$configured_home" != /* ]]; then
    configured_home="$PWD/$configured_home"
  fi
  configured_home="$(realpath -m -- "$configured_home")"
  [[ "$configured_home" != / ]] || { echo 'error: GDC_HOME must not be /' >&2; return 1; }
  GDC_HOME="$configured_home"
  STATE="$GDC_HOME/state"
  export GDC_HOME STATE
}

init_gdc_paths

# GDC_HOME is the operator's data root. Commands that act on a particular
# Network Node select a child directory named after that operator-provided SSH
# alias. This keeps private keys, imported Genesis material and evidence from
# independent Hosts out of one shared state directory.
init_gdc_data_root() {
  GDC_DATA_ROOT="${GDC_DATA_ROOT:-$GDC_HOME}"
  if [[ "$GDC_DATA_ROOT" != /* ]]; then
    GDC_DATA_ROOT="$PWD/$GDC_DATA_ROOT"
  fi
  GDC_DATA_ROOT="$(realpath -m -- "$GDC_DATA_ROOT")"
  [[ "$GDC_DATA_ROOT" != / ]] || die 'error: GDC_DATA_ROOT must not be /'
  export GDC_DATA_ROOT
}

select_node_data_home() {
  local node="$1"
  [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid SSH alias for data directory: $node"
  init_gdc_data_root
  GDC_HOME="$GDC_DATA_ROOT/$node"
  init_gdc_paths
}

select_network_owner_data_home() {
  local owner_file="$GDC_DATA_ROOT/network-owner" owner
  [[ -s "$owner_file" ]] || return 1
  owner="$(<"$owner_file")"
  select_node_data_home "$owner"
}

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

inferenced_runs_path() {
  local host_path runs_root
  [[ $# -eq 1 ]] || die 'inferenced_runs_path expects one host path'
  runs_root="$(realpath -m -- "$GDC_HOME/runs")"
  host_path="$(realpath -m -- "$1")"
  [[ "$host_path" == "$runs_root/"* ]] || die "inferenced input is outside $GDC_HOME/runs: $host_path"
  printf '/gdc-runs/%s\n' "${host_path#"$runs_root/"}"
}

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
  done
  for node in "${GDC_NODES[@]}"; do
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

persist_runtime_topology() {
  write_env "$STATE/runtime-topology.env" \
    "GDC_GENESIS_NODE=$GENESIS_NODE" \
    "GDC_GENESIS_GUARDIAN_ENABLED=${GDC_GENESIS_GUARDIAN_ENABLED:-false}"
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
  # CometBFT exposes the running Genesis after its legacy-to-current field
  # conversion: `consensus.params` becomes `consensus_params`, null app_hash
  # becomes an empty string, and initial_height becomes a string. Those are
  # the same Genesis, not a new chain. Hash the canonical chain identity so a
  # Host that imports the generated file can be bound to the public endpoint
  # without weakening the raw genesis.sha256 integrity check made at build.
  jq -eS '
    del(.app_name, .app_version)
    | if has("app_hash") then .app_hash = (.app_hash // "") else . end
    | if has("initial_height") then .initial_height = (.initial_height | tostring) else . end
    | if .consensus.params? then
        .consensus_params = .consensus.params | del(.consensus)
      else
        .
      end
  ' "$1" | sha256sum | awk '{print $1}'
}

# Variables initialized here are consumed by scripts that source this library.
# shellcheck disable=SC2034
load_project() {
  ROOT="$(kit_root)"
  init_gdc_paths
  ENV_FILE="${GDC_ENV:-$GDC_HOME/.env}"
  # OPS owns the root .env, while GENESIS and JOIN own their per-Host data
  # directories. A lifecycle phase may therefore use OPS input without moving
  # the Host's keys, Genesis or evidence back into the OPS data root.
  if [[ ! -s "$ENV_FILE" && -z "${GDC_ENV:-}" && -n "${GDC_DATA_ROOT:-}" && "$GDC_HOME" != "$GDC_DATA_ROOT" && -s "$GDC_DATA_ROOT/.env" ]]; then
    ENV_FILE="$GDC_DATA_ROOT/.env"
  fi
  if [[ ! -s "$ENV_FILE" && -z "${GDC_ENV:-}" && -s "$STATE/active-role-config" ]]; then
    ENV_FILE="$(<"$STATE/active-role-config")"
  fi
  [[ -s "$ENV_FILE" ]] || die 'no role input is available; GENESIS and JOIN create it automatically, while OPS requires .env'
  local caller_genesis_node='' caller_public_edge_node='' caller_gateway_node='' caller_telegram_bot_host='' caller_guardian_enabled='' caller_gateway_max_concurrent_requests='' caller_gateway_max_input_tokens_in_flight='' resolved_profile_key runtime_topology runtime_genesis_node runtime_guardian_enabled runtime_home
  local caller_genesis_node_set=false caller_public_edge_node_set=false caller_gateway_node_set=false caller_telegram_bot_host_set=false caller_guardian_enabled_set=false caller_gateway_max_concurrent_requests_set=false caller_gateway_max_input_tokens_in_flight_set=false
  if [[ ${GDC_GENESIS_NODE+x} ]]; then caller_genesis_node="$GDC_GENESIS_NODE"; caller_genesis_node_set=true; fi
  if [[ ${GDC_PUBLIC_EDGE_NODE+x} ]]; then caller_public_edge_node="$GDC_PUBLIC_EDGE_NODE"; caller_public_edge_node_set=true; fi
  if [[ ${GDC_GATEWAY_NODE+x} ]]; then caller_gateway_node="$GDC_GATEWAY_NODE"; caller_gateway_node_set=true; fi
  if [[ ${GDC_TELEGRAM_BOT_HOST+x} ]]; then caller_telegram_bot_host="$GDC_TELEGRAM_BOT_HOST"; caller_telegram_bot_host_set=true; fi
  if [[ ${GDC_GENESIS_GUARDIAN_ENABLED+x} ]]; then caller_guardian_enabled="$GDC_GENESIS_GUARDIAN_ENABLED"; caller_guardian_enabled_set=true; fi
  if [[ ${GDC_GATEWAY_MAX_CONCURRENT_REQUESTS+x} ]]; then caller_gateway_max_concurrent_requests="$GDC_GATEWAY_MAX_CONCURRENT_REQUESTS"; caller_gateway_max_concurrent_requests_set=true; fi
  if [[ ${GDC_GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT+x} ]]; then caller_gateway_max_input_tokens_in_flight="$GDC_GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT"; caller_gateway_max_input_tokens_in_flight_set=true; fi
  runtime_home="$GDC_HOME"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # GDC_HOME locates .env itself, so it is a process-level input rather than a
  # value that can recursively relocate the file from inside that file.
  GDC_HOME="$runtime_home"
  init_gdc_paths
  # Genesis persists only its own network authority, never credentials or
  # independently operated OPS/Gateway placement. A later bootstrap-access
  # must keep using the selected Genesis alias, while .env remains
  # authoritative for Public Edge, Gateway, and Telegram consumer hosts.
  runtime_topology="$STATE/runtime-topology.env"
  if [[ -s "$runtime_topology" ]]; then
    runtime_genesis_node="$(awk -F= '$1 == "GDC_GENESIS_NODE" { print $2; exit }' "$runtime_topology")"
    runtime_guardian_enabled="$(awk -F= '$1 == "GDC_GENESIS_GUARDIAN_ENABLED" { print $2; exit }' "$runtime_topology")"
    [[ -n "$runtime_genesis_node" ]] && GDC_GENESIS_NODE="$runtime_genesis_node"
    [[ -n "$runtime_guardian_enabled" ]] && GDC_GENESIS_GUARDIAN_ENABLED="$runtime_guardian_enabled"
  fi
  # shellcheck disable=SC1091
  source "$ROOT/scripts/profile.sh"
  resolved_profile_key="${GDC_RELEASE_PROFILE:-v2026.07.23}+${GDC_DEPLOYMENT_PROFILE:-community-lab}+${GDC_OPERATOR_SERVICES_PROFILE:-gdc-lab}"
  if [[ -z "${GDC_RESOLVED_IMAGE_LOCK:-}" && -r "$STATE/resolved-images/$resolved_profile_key.lock" ]]; then
    export GDC_RESOLVED_IMAGE_LOCK="$STATE/resolved-images/$resolved_profile_key.lock"
  fi
  load_profiles
  set +a
  if [[ "$caller_genesis_node_set" == true ]]; then export GDC_GENESIS_NODE="$caller_genesis_node"; fi
  if [[ "$caller_public_edge_node_set" == true ]]; then export GDC_PUBLIC_EDGE_NODE="$caller_public_edge_node"; fi
  if [[ "$caller_gateway_node_set" == true ]]; then export GDC_GATEWAY_NODE="$caller_gateway_node"; fi
  if [[ "$caller_telegram_bot_host_set" == true ]]; then export GDC_TELEGRAM_BOT_HOST="$caller_telegram_bot_host"; fi
  if [[ "$caller_guardian_enabled_set" == true ]]; then export GDC_GENESIS_GUARDIAN_ENABLED="$caller_guardian_enabled"; fi
  if [[ "$caller_gateway_max_concurrent_requests_set" == true ]]; then export GDC_GATEWAY_MAX_CONCURRENT_REQUESTS="$caller_gateway_max_concurrent_requests"; fi
  if [[ "$caller_gateway_max_input_tokens_in_flight_set" == true ]]; then export GDC_GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT="$caller_gateway_max_input_tokens_in_flight"; fi

  # Keep a fresh Community DevNet recognisable across its reproducible
  # baseline and upgrade rehearsals. An explicit deployment override remains
  # possible through .env for an isolated experiment.
  CHAIN_ID="${CHAIN_ID:-gonka-devnet-community}"
  BASE_DENOM=ngonka
  ACME_EMAIL="${ACME_EMAIL:-}"
  load_public_observability_hosts
  API_HOST=api.gonka-dev.net
  load_topology
  DATA_ROOT=/srv/dai
  GENESIS_INSTALL_PATH=/srv/dai/shared/genesis.json
  HF_CACHE_ROOT=/srv/dai/hf-cache
  mapfile -t genesis_addresses < <(getent ahostsv4 "$GENESIS_PUBLIC_HOST" | awk '{print $1}' | sort -u)
  (( ${#genesis_addresses[@]} == 1 )) || die "$GENESIS_PUBLIC_HOST must resolve to exactly one IPv4 address"
  MONITORING_CIDR="${genesis_addresses[0]}/32"
  mapfile -t edge_addresses < <(getent ahostsv4 "$PUBLIC_EDGE_HOST" | awk '{print $1}' | sort -u)
  (( ${#edge_addresses[@]} == 1 )) || die "$PUBLIC_EDGE_HOST must resolve to exactly one IPv4 address"
  PUBLIC_EDGE_CIDR="${edge_addresses[0]}/32"

  SECRETS="$STATE/secrets"
  IDENTITIES="$STATE/identities"
  GENERATED="$STATE/generated"
  GENESIS="$GDC_HOME/genesis"
  ACCOUNTS="$GDC_HOME/accounts"
  INVENTORY="$STATE/inventory.env"
  mkdir -p "$STATE" "$GDC_HOME"
  GDC_RUN_ID="${GDC_RUN_ID:-$(cat "$STATE/active-run-id" 2>/dev/null || true)}"
  if [[ -n "$GDC_RUN_ID" ]]; then
    GDC_RUN_LOG="${GDC_RUN_LOG:-$GDC_HOME/runs/$GDC_RUN_ID/run.log}"
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
  record_run_manifest "$phase"
}

# Keep phase verdicts tied to the invocation that produced them.  This is
# deliberately created before a phase mutates a remote host: a later PASS
# bundle may not be reused for a different operator data root or release
# profile merely because its directory name sorts last.
record_run_manifest() {
  local phase="$1" run_id manifest commit
  run_id="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}"
  manifest="$GDC_HOME/runs/$run_id/manifest.env"
  mkdir -p "$(dirname "$manifest")"
  if [[ -s "$manifest" ]]; then
    # Multiple phases may belong to one lifecycle run.  Never erase an
    # already bound Genesis lineage when recording a later phase.
    grep -qx "operator_data_home=$GDC_HOME" "$manifest" \
      || die "run $run_id belongs to another operator data home"
    grep -qx "profile_hash=$(profile_hash)" "$manifest" \
      || die "run $run_id belongs to another release/profile lineage"
    return 0
  fi
  commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'UNAVAILABLE')"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'phase=%s\n' "$phase"
    printf 'created_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'operator_data_home=%s\n' "$GDC_HOME"
    printf 'runbook_commit=%s\n' "$commit"
    printf 'operator_mode=runbook-managed\n'
    printf 'release_profile=%s\n' "$GDC_RELEASE_PROFILE"
    printf 'deployment_profile=%s\n' "$GDC_DEPLOYMENT_PROFILE"
    printf 'model_profile=%s\n' "$GDC_MODEL_PROFILE"
    printf 'profile_hash=%s\n' "$(profile_hash)"
  } >"$manifest"
}

bind_run_manifest_genesis() {
  local hash="$1" run_id manifest existing
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die 'run manifest requires a canonical Genesis SHA-256'
  run_id="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}"
  manifest="$GDC_HOME/runs/$run_id/manifest.env"
  [[ -s "$manifest" ]] || die "run manifest is absent for run $run_id"
  existing="$(awk -F= '$1 == "genesis_sha256" {print $2; exit}' "$manifest")"
  [[ -z "$existing" || "$existing" == "$hash" ]] \
    || die "run $run_id is already bound to another Genesis lineage"
  [[ -n "$existing" ]] || printf 'genesis_sha256=%s\n' "$hash" >>"$manifest"
}

assert_baseline_release() {
  [[ "$GDC_RELEASE_PROFILE" == v2026.07.23 ]] || die "baseline phases require v2026.07.23, got $GDC_RELEASE_PROFILE"
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
  local host="$1" report node
  while IFS= read -r report; do
    [[ -s "$report/models.json" && -s "$report/completion.json" && -s "$report/vram.csv" ]] || continue
    printf '%s\n' "$report"
    return 0
  done < <(
    for node in "${GDC_NODES[@]}"; do
      find "$(node_data_home "$node")/runs" -mindepth 2 -maxdepth 2 -type d \
        -path "*-ml-qualification/$host" -print 2>/dev/null
    done | LC_ALL=C sort -r
  )
  return 1
}

require() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" && "${!name}" != REPLACE_* ]] || die "set $name in the active role configuration"
  done
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
    inventory_value GDC_GENESIS_NODE "$GENESIS_NODE"
    inventory_value GDC_PUBLIC_EDGE_NODE "$PUBLIC_EDGE_NODE"
    inventory_value GDC_GATEWAY_NODE "$GATEWAY_NODE"
    inventory_value GENESIS_NODE "$GENESIS_NODE"
    inventory_value GENESIS_PUBLIC_HOST "$GENESIS_PUBLIC_HOST"
    inventory_value GENESIS_P2P_PORT "$(node_p2p_port "$GENESIS_NODE")"
    inventory_value PUBLIC_EDGE_HOST "$PUBLIC_EDGE_HOST"
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
  local bundle="$1" runs_before runs_after
  shift
  [[ -d "$bundle" && -s "$bundle/public-reset-state.png" ]] || return 1
  [[ "$(od -An -tx1 -N8 "$bundle/public-reset-state.png" | tr -d ' \n')" == 89504e470d0a1a0a ]] || return 1
  [[ -s "$bundle/verdict.md" ]] && grep -qx '# DevNet reset preservation: PASS' "$bundle/verdict.md" || return 1
  [[ -s "$bundle/pre-reset.env" ]] || return 1
  grep -Eq '^pre_reset_chain_id=[a-zA-Z0-9._-]+$' "$bundle/pre-reset.env" || return 1
  grep -Eq '^pre_reset_genesis_sha256=[0-9a-f]{64}$' "$bundle/pre-reset.env" || return 1
  if [[ -f "$bundle/runs.before.sha256" && -f "$bundle/runs.after.sha256" ]]; then
    runs_before="$bundle/runs.before.sha256"
    runs_after="$bundle/runs.after.sha256"
  else
    # Preserve audit compatibility with bundles produced before GDC_HOME was
    # flattened and the intermediate artifacts directory was removed.
    runs_before="$bundle/artifacts-runs.before.sha256"
    runs_after="$bundle/artifacts-runs.after.sha256"
  fi
  [[ -f "$runs_before" && -f "$runs_after" ]] || return 1
  cmp -s "$runs_before" "$runs_after" || return 1

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
./gdc.sh --release v2026.08.06 upgrade
The command permits a
resume only when every already changed node has the exact target profile
marker; a third or mixed release remains a hard failure.
EOF
}

ssh_ready() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
    "$1" true </dev/null >/dev/null 2>&1
}

node_data_home() {
  local node="$1"
  printf '%s/%s\n' "$GDC_DATA_ROOT" "$node"
}

node_joined_marker() {
  local node="$1"
  printf '%s/state/joined/%s\n' "$(node_data_home "$node")" "$node"
}

node_account_file() {
  local node="$1"
  printf '%s/accounts/%s-cold.json\n' "$(node_data_home "$node")" "$node"
}

node_identity_file() {
  local node="$1"
  printf '%s/state/identities/%s.json\n' "$(node_data_home "$node")" "$node"
}

join_state_file() {
  local node="$1"
  printf '%s/state/join-state/%s.env\n' "$(node_data_home "$node")" "$node"
}

# Persist the strongest observed join state, rather than collapsing all
# successful commands into the word "joined".  The file contains public
# identifiers only and is safe to attach to a sanitized operator receipt.
record_join_state() {
  local node="$1" state="$2" address="${3:-}" file
  file="$(join_state_file "$node")"
  mkdir -p "$(dirname "$file")"
  {
    printf 'node=%s\n' "$node"
    printf 'state=%s\n' "$state"
    printf 'observed_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'run_id=%s\n' "${GDC_RUN_ID:-manual}"
    printf 'address=%s\n' "$address"
  } >"$file"
}

# The runtime identifier is submitted to chain-facing DAPI configuration.  A
# topology position is local controller metadata, so it must never be used
# here: two independent JOIN operators can both call their target "index 1".
# A Bech32 participant address is globally unique for this chain and remains
# stable across a resumable deployment.
runtime_id_for_participant() {
  local address="$1"
  [[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] || die "invalid participant address for runtime identity: $address"
  printf 'qwen3-0.6b:%s\n' "$address"
}

runtime_identity_file() {
  local runtime_id="$1"
  printf '%s/state/runtime-identities/%s.env\n' "$GDC_DATA_ROOT" "$(printf '%s' "$runtime_id" | sha256sum | awk '{print $1}')"
}

# Detect a collision before touching a remote Host.  The chain is the final
# authority for cross-operator uniqueness, while this local guard prevents a
# controller from accidentally reusing one runtime identity for two aliases.
record_runtime_identity() {
  local node="$1" address="$2" runtime_id="$3" file existing_node existing_address
  file="$(runtime_identity_file "$runtime_id")"
  mkdir -p "$(dirname "$file")"
  if [[ -s "$file" ]]; then
    existing_node="$(awk -F= '$1 == "node" {print $2; exit}' "$file")"
    existing_address="$(awk -F= '$1 == "participant_address" {print $2; exit}' "$file")"
    [[ "$existing_node" == "$node" && "$existing_address" == "$address" ]] \
      || die "runtime ID collision: $runtime_id is already recorded for $existing_node/$existing_address"
    return 0
  fi
  {
    printf 'node=%s\n' "$node"
    printf 'participant_address=%s\n' "$address"
    printf 'runtime_id=%s\n' "$runtime_id"
    printf 'recorded_at=%s\n' "$(date -u +%FT%TZ)"
  } >"$file"
}

configured_node_indexes() {
  local index=0 node joined_marker
  for node in "${GDC_NODES[@]}"; do
    # Each Host owns its own state directory under GDC_DATA_ROOT.  Network
    # lifecycle phases run from the Genesis owner's GDC_HOME, so checking only
    # $STATE would silently omit independently joined validators.
    joined_marker="$(node_joined_marker "$node")"
    [[ -e "$joined_marker" ]] && printf '%s\n' "$index"
    index=$((index + 1))
  done
}

configured_nodes() {
  local node joined_marker
  for node in "${GDC_NODES[@]}"; do
    joined_marker="$(node_joined_marker "$node")"
    [[ -e "$joined_marker" ]] && printf '%s\n' "$node"
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
    grep -qx 'release_profile=v2026.07.23' "$environment" || continue
    grep -qx "chain_id=$CHAIN_ID" "$environment" || continue
    grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$environment" || continue
    grep -qx "profile_hash=$genesis_profile_hash" "$environment" || continue
    printf '%s\n' "$bundle"
    return 0
  done < <(find "$GDC_HOME/runs" -mindepth 2 -maxdepth 2 -name verdict.md -print 2>/dev/null | LC_ALL=C sort -r)
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

  step 'Require a current v2026.07.23 baseline PASS before the upgrade lifecycle'
  bundle="$(latest_baseline_pass_bundle || true)"
  [[ -n "$bundle" ]] || die 'no matching v2026.07.23 verification PASS; restore every intended participant and run ./gdc.sh --release v2026.07.23 verify'

  mapfile -t indexes < <(configured_node_indexes)
  (( ${#indexes[@]} > 0 )) || die 'no joined participants are recorded for the verified baseline'
  mapfile -t evidence_nodes < <(jq -er '.[].node' "$bundle/node-sync.json" | LC_ALL=C sort)
  ((${#evidence_nodes[@]} == ${#indexes[@]})) || die 'baseline PASS participant count differs from current joined state; run verify again'

  expected_addresses=()
  reference_height="$(ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:26657/status' | jq -er '.result.sync_info.latest_block_height | tonumber')"
  genesis_profile_hash="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$STATE/phase-profiles/genesis.env")"
  for node in "${GDC_NODES[@]}"; do
    [[ -e "$(node_joined_marker "$node")" ]] || continue
    grep -qx "$node" <(printf '%s\n' "${evidence_nodes[@]}") || die "$node is absent from the baseline PASS bundle; run verify again"
    address="$(jq -er .address "$(node_account_file "$node")")"
    expected_addresses+=("$address")
    marker="$(ssh "$node" "cat /srv/dai/deploy/$node/.gdc-release 2>/dev/null || true")"
    [[ "$marker" == "v2026.07.23 $genesis_profile_hash" ]] || die "$node does not have the verified v2026.07.23 deployment marker"
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
      | jq -er '.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1) | .address' \
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
