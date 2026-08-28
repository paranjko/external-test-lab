#!/usr/bin/env bash
set -Eeuo pipefail

kit_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

init_gdc_paths() {
  ROOT="${ROOT:-$(kit_root)}"
  local configured_home="${GDC_HOME:-$HOME/.gdc-data}"
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

is_safe_integer() {
  local value="$1" maximum=9223372036854775807 index value_digit maximum_digit
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  (( ${#value} < ${#maximum} )) && return 0
  (( ${#value} == ${#maximum} )) || return 1
  for ((index = 0; index < ${#maximum}; index++)); do
    value_digit="${value:index:1}"
    maximum_digit="${maximum:index:1}"
    (( value_digit < maximum_digit )) && return 0
    (( value_digit > maximum_digit )) && return 1
  done
  return 0
}

runbook_revision() {
  git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'UNAVAILABLE'
}

gdc_launcher_sha256() {
  sha256sum "$ROOT/gdc.sh" | awk '{print $1}'
}

release_profile_lock_sha256() {
  local release_profile="${GDC_RELEASE_PROFILE:-v2026.07.23}" lock_file
  lock_file="$ROOT/profiles/releases/$release_profile.lock"
  [[ -s "$lock_file" ]] || die "unknown release profile: $release_profile"
  sha256sum "$lock_file" | awk '{print $1}'
}

run_manifest_path() {
  local run_id="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}"
  printf '%s/runs/%s/manifest.env\n' "$GDC_HOME" "$run_id"
}

# Public observers do not load an operator role file, but they still need the
# same immutable invocation envelope as mutation phases. This helper also
# makes direct script execution fail closed instead of creating unbound output.
ensure_run_manifest() {
  local phase="$1" run_id manifest commit launcher_sha256 release_profile release_hash existing existing_fingerprint
  [[ -n "$phase" ]] || die 'run manifest requires a phase name'
  run_id="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}"
  export GDC_RUN_ID="$run_id"
  manifest="$(run_manifest_path)"
  release_profile="${GDC_RELEASE_PROFILE:-v2026.07.23}"
  release_hash="$(release_profile_lock_sha256)"
  mkdir -p "$(dirname "$manifest")"
  if [[ -s "$manifest" ]]; then
    grep -qx "run_id=$run_id" "$manifest" || die "run manifest belongs to another run ID"
    grep -qx "operator_data_home=$GDC_HOME" "$manifest" || die "run manifest belongs to another operator data home"
    if [[ -n "${GDC_NETWORK_FINGERPRINT:-}" ]]; then
      existing_fingerprint="$(awk -F= '$1 == "network_fingerprint" {print $2; exit}' "$manifest")"
      [[ -n "$existing_fingerprint" && "$existing_fingerprint" == "$GDC_NETWORK_FINGERPRINT" ]] \
        || die 'run_resume_mismatch: retained run does not match the currently observed network software fingerprint'
    fi
    grep -qx "release_profile=$release_profile" "$manifest" || die "run manifest belongs to another release profile"
    existing="$(awk -F= '$1 == "release_profile_sha256" {print $2; exit}' "$manifest")"
    if [[ -n "$existing" ]]; then
      [[ "$existing" == "$release_hash" ]] || die 'run manifest has a different release profile hash'
    else
      printf 'release_profile_sha256=%s\n' "$release_hash" >>"$manifest"
    fi
    return 0
  fi
  commit="$(runbook_revision)"
  launcher_sha256="$(gdc_launcher_sha256)"
  {
    printf 'schema_version=2\n'
    printf 'run_id=%s\n' "$run_id"
    printf 'phase=%s\n' "$phase"
    printf 'created_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'operator_data_home=%s\n' "$GDC_HOME"
    printf 'runbook_commit=%s\n' "$commit"
    printf 'gdc_launcher_sha256=%s\n' "$launcher_sha256"
    printf 'release_profile=%s\n' "$release_profile"
    printf 'release_profile_sha256=%s\n' "$release_hash"
    [[ -z "${GDC_NETWORK_FINGERPRINT:-}" ]] || printf 'network_fingerprint=%s\n' "$GDC_NETWORK_FINGERPRINT"
    [[ -z "${GDC_NETWORK_CHAIN_ID:-}" ]] || printf 'network_chain_id=%s\n' "$GDC_NETWORK_CHAIN_ID"
    [[ -z "${GDC_NETWORK_GENESIS_SHA256:-}" ]] || printf 'network_genesis_sha256=%s\n' "$GDC_NETWORK_GENESIS_SHA256"
    [[ -z "${GDC_JOIN_RECOVERY_FROM_RUN_ID:-}" ]] || printf 'recovery_of_run_id=%s\n' "$GDC_JOIN_RECOVERY_FROM_RUN_ID"
    [[ -z "${GDC_INVOCATION_COMMAND:-}" ]] || printf 'invocation_command=%q\n' "$GDC_INVOCATION_COMMAND"
    [[ -z "${GDC_INVOCATION_CWD:-}" ]] || printf 'invocation_cwd=%q\n' "$GDC_INVOCATION_CWD"
    printf 'lineage_scope=pre-genesis\n'
  } >"$manifest"
}

write_phase_lineage() {
  local bundle="$1" chain_id="$2" hash="$3" manifest lineage release_hash profile_hash commit
  [[ -d "$bundle" ]] || die "phase bundle directory is absent: $bundle"
  [[ "$chain_id" =~ ^[A-Za-z0-9._-]+$ ]] || die 'phase lineage requires a chain ID'
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die 'phase lineage requires a Genesis SHA-256'
  ensure_run_manifest "${EVIDENCE_PHASE_NAME:-observer}"
  bind_run_manifest_genesis "$hash" "$chain_id"
  manifest="$(run_manifest_path)"
  require_run_manifest_lineage "$manifest" "$hash" "$chain_id"
  lineage="$bundle/lineage.env"
  release_hash="$(awk -F= '$1 == "release_profile_sha256" {print $2; exit}' "$manifest")"
  profile_hash="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$manifest")"
  commit="$(awk -F= '$1 == "runbook_commit" {print $2; exit}' "$manifest")"
  if [[ -s "$lineage" ]]; then
    grep -qx "run_id=$GDC_RUN_ID" "$lineage" \
      && grep -qx "chain_id=$chain_id" "$lineage" \
      && grep -qx "genesis_sha256=$hash" "$lineage" \
      && grep -qx "release_profile_sha256=$release_hash" "$lineage" \
      || die 'phase bundle lineage is stale or mismatched'
    return 0
  fi
  {
    printf 'schema_version=1\n'
    printf 'run_id=%s\n' "$GDC_RUN_ID"
    printf 'chain_id=%s\n' "$chain_id"
    printf 'genesis_sha256=%s\n' "$hash"
    printf 'release_profile=%s\n' "${GDC_RELEASE_PROFILE:-v2026.07.23}"
    printf 'release_profile_sha256=%s\n' "$release_hash"
    [[ -z "$profile_hash" ]] || printf 'profile_hash=%s\n' "$profile_hash"
    printf 'runbook_commit=%s\n' "$commit"
  } >"$lineage"
  return 0
}

# GDC_HOME is the operator's data root. Commands that act on a particular
# Network Node select a child directory named after that operator-provided SSH
# alias. This keeps private keys, imported Genesis material and evidence from
# independent Hosts out of one shared state directory.
init_gdc_data_root() {
  # GDC_HOME is the only operator-controlled state location. Keep the shared
  # parent for per-Host directories as an internal derived value; accepting a
  # second environment override would make a JOIN appear to use one home while
  # writing private state into another.
  # Capture it once before selecting a per-Host GDC_HOME. A command operating
  # on more than one Host must keep every Host directly below that original
  # operator root, rather than nesting later aliases below the preceding one.
  if [[ -z "${GDC_INTERNAL_DATA_ROOT:-}" ]]; then
    GDC_INTERNAL_DATA_ROOT="$GDC_HOME"
  fi
  GDC_DATA_ROOT="$GDC_INTERNAL_DATA_ROOT"
  if [[ "$GDC_DATA_ROOT" != /* ]]; then
    GDC_DATA_ROOT="$PWD/$GDC_DATA_ROOT"
  fi
  GDC_DATA_ROOT="$(realpath -m -- "$GDC_DATA_ROOT")"
  [[ "$GDC_DATA_ROOT" != / ]] || die 'error: GDC_DATA_ROOT must not be /'
  GDC_INTERNAL_DATA_ROOT="$GDC_DATA_ROOT"
  export GDC_INTERNAL_DATA_ROOT GDC_DATA_ROOT
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
    "$ROOT/scripts/phase-diagnostic-adapter.sh" "$RUN/diagnostic-envelope.v1.json" "${EVIDENCE_PHASE_NAME:-phase}" "$rc"
    export GDC_DIAGNOSTIC_ENVELOPE="$RUN/diagnostic-envelope.v1.json"
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
  local node host ml_alias
  for node in "${GDC_NODES[@]}"; do
    [[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid SSH alias in GDC_NODE_ALIASES: $node"
    [[ -z "${seen[$node]:-}" ]] || die "duplicate SSH alias in GDC_NODE_ALIASES: $node"
    seen[$node]=1
  done
  for node in "${GDC_NODES[@]}"; do
    host="$(node_public_host "$node")"
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid public host for $node: $host"
    ml_alias="$(node_ml_host "$node" || true)"
    if [[ -n "$ml_alias" ]]; then
      [[ "$ml_alias" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid ML SSH alias for $node: $ml_alias"
      [[ -z "${seen[$ml_alias]:-}" ]] || die "ML SSH alias must differ from a validator alias: $ml_alias"
      [[ -z "${ml_seen[$ml_alias]:-}" ]] || die "network GPU SSH alias is mapped more than once: $ml_alias"
      ml_seen[$ml_alias]=1
    fi
  done
  if [[ "${GDC_JOIN_ROLE_INPUT:-false}" == true ]]; then
    [[ -n "${GDC_JOIN_NETWORK_HOST:-}" ]] || die 'JOIN role input lacks a network seed host'
    GENESIS_NODE=''
    PUBLIC_EDGE_NODE=''
    GATEWAY_NODE=''
    TELEGRAM_BOT_HOST=''
    GENESIS_PUBLIC_HOST="$GDC_JOIN_NETWORK_HOST"
    PUBLIC_EDGE_HOST="$GDC_JOIN_NETWORK_HOST"
    return 0
  fi
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
    "GDC_PUBLIC_EDGE_NODE=$PUBLIC_EDGE_NODE" \
    "GDC_GATEWAY_NODE=$GATEWAY_NODE" \
    "GDC_TELEGRAM_BOT_HOST=$TELEGRAM_BOT_HOST" \
    "GDC_GENESIS_GUARDIAN_ENABLED=${GDC_GENESIS_GUARDIAN_ENABLED:-false}"
}

curl_exit_status() {
  case "${1:-125}" in
    0) printf 'ok' ;;
    5) printf 'proxy_resolution_failed' ;;
    6) printf 'dns_resolution_failed' ;;
    7) printf 'connection_failed' ;;
    28) printf 'timeout' ;;
    35) printf 'tls_handshake_failed' ;;
    47) printf 'redirect_limit_exceeded' ;;
    52) printf 'empty_response' ;;
    56) printf 'receive_failed' ;;
    137) printf 'process_killed' ;;
    *) printf 'curl_error' ;;
  esac
}

capture_canonical_genesis() {
  local endpoint="$1" output="$2" raw stderr http_status rc detail
  raw="$(mktemp)"
  stderr="$(mktemp)"
  if http_status="$(curl -sS --max-time 15 -o "$raw" -w '%{http_code}' "$endpoint" 2>"$stderr")"; then rc=0; else rc=$?; fi
  if (( rc != 0 )) || [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    detail="$(tr '\n' ' ' <"$stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    printf 'WAIT  canonical Genesis unavailable url=%s http_status=%s curl_exit=%s curl_status=%s%s\n' \
      "$endpoint" "${http_status:-0}" "$rc" "$(curl_exit_status "$rc")" "${detail:+ detail=$detail}" >&2
    rm -f "$stderr"
    rm -f "$raw"
    return 1
  fi
  rm -f "$stderr"
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
  if [[ ! -s "$ENV_FILE" && -z "${GDC_ENV:-}" && -s "$STATE/active-role-config" ]]; then
    ENV_FILE="$(<"$STATE/active-role-config")"
  fi
  if [[ ! -s "$ENV_FILE" && -z "${GDC_ENV:-}" && -n "${GDC_DATA_ROOT:-}" && "$GDC_HOME" != "$GDC_DATA_ROOT" && -s "$GDC_DATA_ROOT/.env" ]]; then
    ENV_FILE="$GDC_DATA_ROOT/.env"
  fi
  [[ -s "$ENV_FILE" ]] || die 'no role input is available; GENESIS and JOIN create it automatically, while OPS requires .env'
  local caller_genesis_node='' caller_public_edge_node='' caller_gateway_node='' caller_telegram_bot_host='' caller_guardian_enabled='' caller_gateway_max_concurrent_requests='' caller_gateway_max_input_tokens_in_flight='' resolved_profile_key runtime_topology runtime_genesis_node runtime_public_edge_node runtime_gateway_node runtime_telegram_bot_host runtime_guardian_enabled runtime_home
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
  # Runtime topology belongs only to the network that created it. A fresh
  # Genesis role input is authoritative for its new deployment and must not
  # inherit public-role assignments from a removed network.
  runtime_topology="$STATE/runtime-topology.env"
  if [[ "${GDC_GENESIS_ROLE_INPUT:-false}" != true && -s "$runtime_topology" ]]; then
    runtime_genesis_node="$(awk -F= '$1 == "GDC_GENESIS_NODE" { print $2; exit }' "$runtime_topology")"
    runtime_public_edge_node="$(awk -F= '$1 == "GDC_PUBLIC_EDGE_NODE" { print $2; exit }' "$runtime_topology")"
    runtime_gateway_node="$(awk -F= '$1 == "GDC_GATEWAY_NODE" { print $2; exit }' "$runtime_topology")"
    runtime_telegram_bot_host="$(awk -F= '$1 == "GDC_TELEGRAM_BOT_HOST" { print $2; exit }' "$runtime_topology")"
    runtime_guardian_enabled="$(awk -F= '$1 == "GDC_GENESIS_GUARDIAN_ENABLED" { print $2; exit }' "$runtime_topology")"
    [[ -n "$runtime_genesis_node" ]] && GDC_GENESIS_NODE="$runtime_genesis_node"
    [[ -n "$runtime_public_edge_node" ]] && GDC_PUBLIC_EDGE_NODE="$runtime_public_edge_node"
    [[ -n "$runtime_gateway_node" ]] && GDC_GATEWAY_NODE="$runtime_gateway_node"
    [[ -n "$runtime_telegram_bot_host" ]] && GDC_TELEGRAM_BOT_HOST="$runtime_telegram_bot_host"
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
  local phase="$1" run_id manifest commit existing_profile
  ensure_run_manifest "$phase"
  run_id="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}"
  manifest="$GDC_HOME/runs/$run_id/manifest.env"
  mkdir -p "$(dirname "$manifest")"
  if [[ -s "$manifest" ]]; then
    # Multiple phases may belong to one lifecycle run.  Never erase an
    # already bound Genesis lineage when recording a later phase.
    grep -qx "operator_data_home=$GDC_HOME" "$manifest" \
      || die "run $run_id belongs to another operator data home"
    existing_profile="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$manifest")"
    if [[ -n "$existing_profile" ]]; then
      [[ "$existing_profile" == "$(profile_hash)" ]] \
        || die "run $run_id belongs to another release/profile lineage"
    else
      printf 'profile_hash=%s\n' "$(profile_hash)" >>"$manifest"
      printf 'deployment_profile=%s\n' "$GDC_DEPLOYMENT_PROFILE" >>"$manifest"
      printf 'model_profile=%s\n' "$GDC_MODEL_PROFILE" >>"$manifest"
    fi
    return 0
  fi
  commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'UNAVAILABLE')"
  {
    printf 'schema_version=2\n'
    printf 'run_id=%s\n' "$run_id"
    printf 'phase=%s\n' "$phase"
    printf 'created_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'operator_data_home=%s\n' "$GDC_HOME"
    printf 'runbook_commit=%s\n' "$commit"
    printf 'operator_mode=%s\n' "${GDC_OPERATOR_ROLE:-runbook-managed}"
    printf 'release_profile=%s\n' "$GDC_RELEASE_PROFILE"
    printf 'deployment_profile=%s\n' "$GDC_DEPLOYMENT_PROFILE"
    printf 'model_profile=%s\n' "$GDC_MODEL_PROFILE"
    printf 'profile_hash=%s\n' "$(profile_hash)"
  } >"$manifest"
}

bind_run_manifest_genesis() {
  local hash="$1" chain_id="${2:-}" run_id manifest existing existing_chain
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die 'run manifest requires a canonical Genesis SHA-256'
  run_id="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}"
  manifest="$GDC_HOME/runs/$run_id/manifest.env"
  [[ -s "$manifest" ]] || die "run manifest is absent for run $run_id"
  existing="$(awk -F= '$1 == "genesis_sha256" {print $2; exit}' "$manifest")"
  [[ -z "$existing" || "$existing" == "$hash" ]] \
    || die "run $run_id is already bound to another Genesis lineage"
  if [[ -z "$existing" ]]; then
    printf 'genesis_sha256=%s\n' "$hash" >>"$manifest"
    printf 'lineage_scope=genesis-bound\n' >>"$manifest"
  fi
  if [[ -n "$chain_id" ]]; then
    [[ "$chain_id" =~ ^[A-Za-z0-9._-]+$ ]] || die 'run manifest requires a canonical chain ID'
    existing_chain="$(awk -F= '$1 == "chain_id" {print $2; exit}' "$manifest")"
    [[ -z "$existing_chain" || "$existing_chain" == "$chain_id" ]] \
      || die "run $run_id is already bound to another chain lineage"
    [[ -n "$existing_chain" ]] || printf 'chain_id=%s\n' "$chain_id" >>"$manifest"
  fi
}

require_run_manifest_lineage() {
  local manifest="$1" expected_hash="$2" expected_chain_id="$3"
  [[ -s "$manifest" ]] || die "missing immutable run manifest: $manifest"
  grep -qx "genesis_sha256=$expected_hash" "$manifest" \
    || die 'evidence belongs to a different Genesis lineage'
  if grep -q '^chain_id=' "$manifest"; then
    grep -qx "chain_id=$expected_chain_id" "$manifest" \
      || die 'evidence belongs to a different chain lineage'
  fi
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
  local host="$1" report node node_runs
  while IFS= read -r report; do
    [[ -s "$report/models.json" && -s "$report/completion.json" && -s "$report/vram.csv" ]] || continue
    printf '%s\n' "$report"
    return 0
  done < <(
    for node in "${GDC_NODES[@]}"; do
      node_runs="$(node_data_home "$node")/runs"
      [[ -d "$node_runs" ]] || continue
      find "$node_runs" -mindepth 2 -maxdepth 2 -type d \
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
  runs_before="$bundle/runs.before.sha256"
  runs_after="$bundle/runs.after.sha256"
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
./gdc.sh --release ${GDC_RELEASE_PROFILE:-v2026.08.06} upgrade
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

# Resolve the full canonical Host inventory into public participant identities.
# A coordinator may read only the public address field from a Host account file
# it owns. An independent Host is resolved from the captured public chain
# participant set. A current, sanitized JOIN receipt is an optional consistency
# check only; no keyring, mnemonic, validator key, recovery archive, or private
# operator directory is consulted.
resolve_expected_network_participants() {
  local output="$1" chain_id="$2" genesis_sha256="$3" topology="$4" chain_participants="$5"
  local node host account address local_address validator_key runtime_id source receipt_count
  local candidate_count receipt_address receipt_validator_key
  local tmp
  [[ "$chain_id" =~ ^[A-Za-z0-9._-]+$ ]] || die 'invalid chain ID for expected participant resolution'
  [[ "$genesis_sha256" =~ ^[0-9a-f]{64}$ ]] || die 'invalid Genesis hash for expected participant resolution'
  mkdir -p "$(dirname "$output")"
  tmp="${output}.tmp"
  jq -e '.participant | type == "array"' "$chain_participants" >/dev/null \
    || die 'captured public participant set is malformed'
  jq -e '
    [.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)
      | {address,validator_key,inference_url}]
    | all(.[]; (.address | type == "string" and test("^gonka1[0-9a-z]{20,90}$"))
        and (.validator_key | type == "string" and length > 0)
        and (.inference_url | type == "string" and test("^https://[A-Za-z0-9.-]+/?$")))
    and ([.[].address] | length) == ([.[].address] | unique | length)
    and ([.[].inference_url | sub("/$"; "")] | length) == ([.[].inference_url | sub("/$"; "")] | unique | length)
  ' "$chain_participants" >/dev/null || die 'ACTIVE public participant set has malformed or duplicate identities'
  jq -n --arg chain_id "$chain_id" --arg genesis_sha256 "$genesis_sha256" \
    '{schema_version:1,chain_id:$chain_id,genesis_sha256:$genesis_sha256,participants:[]}' >"$tmp"

  for node in "${GDC_NODES[@]}"; do
    host="$(node_public_host "$node")"
    account="$(node_account_file "$node")"
    local_address=''
    if [[ -e "$account" ]]; then
      [[ -f "$account" && ! -L "$account" ]] || die "public account record is not a regular file for $node"
      local_address="$(jq -er '.address | select(type == "string" and test("^gonka1[0-9a-z]{20,90}$"))' "$account")" \
        || die "public account record lacks a valid participant address for $node"
    fi

    if [[ -s "$topology" ]]; then
      jq -e --arg chain "$chain_id" --arg genesis "$genesis_sha256" '
        .schema_version == 1 and .chain_id == $chain and .genesis_sha256 == $genesis
        and (.participants | type == "array")
        and ([.participants[].address] | length) == ([.participants[].address] | unique | length)
        and ([.participants[].validator_key] | length) == ([.participants[].validator_key] | unique | length)
        and ([.participants[].runtime_id] | length) == ([.participants[].runtime_id] | unique | length)
        and ([.participants[].public_host] | length) == ([.participants[].public_host] | unique | length)
        and all(.participants[]; (.address | type == "string" and test("^gonka1[0-9a-z]{20,90}$"))
          and (.runtime_id == ("qwen3-0.6b:" + .address))
          and (.public_host | type == "string" and test("^[A-Za-z0-9.-]+$")))
      ' "$topology" >/dev/null || die 'current-lineage topology is stale, incomplete, or contains duplicate identities'
      receipt_count="$(jq --arg host "$host" '[.participants[] | select(.public_host == $host)] | length' "$topology")"
      (( receipt_count <= 1 )) || die "ambiguous current-lineage identity for $node"
      if (( receipt_count == 1 )); then
        receipt_address="$(jq -er --arg host "$host" '.participants[] | select(.public_host == $host) | .address' "$topology")"
        receipt_validator_key="$(jq -er --arg host "$host" '.participants[] | select(.public_host == $host) | .validator_key' "$topology")"
      else
        receipt_address=''
        receipt_validator_key=''
      fi
    else
      receipt_count=0
      receipt_address=''
      receipt_validator_key=''
    fi

    if [[ -n "$local_address" ]]; then
      candidate_count="$(jq --arg address "$local_address" --arg host "$host" '[.participant[] | select((.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1) and .address == $address and (.inference_url | sub("/$"; "")) == ("https://" + $host))] | length' "$chain_participants")"
      (( candidate_count == 1 )) || die "coordinator-owned public identity for $node is missing, inactive, ambiguous, or mapped to another host"
      address="$local_address"
      validator_key="$(jq -er --arg address "$address" '.participant[] | select(.address == $address) | .validator_key' "$chain_participants")"
      source='coordinator-owned-public-account'
    else
      candidate_count="$(jq --arg host "$host" '[.participant[] | select((.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1) and (.inference_url | sub("/$"; "")) == ("https://" + $host))] | length' "$chain_participants")"
      (( candidate_count == 1 )) || die "independent public identity for $node is missing, inactive, ambiguous, or mapped to another host"
      address="$(jq -er --arg host "$host" '.participant[] | select((.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1) and (.inference_url | sub("/$"; "")) == ("https://" + $host)) | .address' "$chain_participants")"
      validator_key="$(jq -er --arg host "$host" '.participant[] | select((.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1) and (.inference_url | sub("/$"; "")) == ("https://" + $host)) | .validator_key' "$chain_participants")"
      source='public-chain-participant'
    fi
    if (( receipt_count == 1 )); then
      [[ "$receipt_address" == "$address" && "$receipt_validator_key" == "$validator_key" ]] \
        || die "current-lineage receipt conflicts with public chain identity for $node"
    fi
    runtime_id="$(runtime_id_for_participant "$address")"
    jq --arg node "$node" --arg public_host "$host" --arg address "$address" --arg validator_key "$validator_key" --arg runtime_id "$runtime_id" --arg source "$source" \
      '.participants += [{node:$node,public_host:$public_host,address:$address,validator_key:$validator_key,runtime_id:$runtime_id,source:$source}]' "$tmp" >"${tmp}.next"
    mv "${tmp}.next" "$tmp"
  done

  jq -e '(.participants | length > 0)
    and ([.participants[].address] | length) == ([.participants[].address] | unique | length)
    and ([.participants[].validator_key] | length) == ([.participants[].validator_key] | unique | length)
    and ([.participants[].public_host] | length) == ([.participants[].public_host] | unique | length)' "$tmp" >/dev/null \
    || die 'expected participant identities are missing or duplicate'
  mv "$tmp" "$output"
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

release_profile_runtime_identity() {
  local profile="$1" root lock
  [[ "$profile" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "invalid release profile: $profile"
  root="$(profile_root)"
  lock="$root/profiles/releases/$profile.lock"
  [[ -r "$lock" ]] || die "unknown release profile: $profile"
  (
    unset GONKA_RELEASE GONKA_COMMIT
    # shellcheck disable=SC1090
    source "$lock"
    [[ "${GONKA_RELEASE:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] \
      || die "$profile has an invalid Gonka runtime version"
    [[ "${GONKA_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] \
      || die "$profile has an invalid Gonka runtime commit"
    printf '%s %s\n' "$GONKA_RELEASE" "$GONKA_COMMIT"
  )
}

candidate_runtime_identity_for_marker() {
  local marker="$1" source_profile="$2" expected_marker
  if [[ -z "$marker" ]]; then
    release_profile_runtime_identity "$source_profile"
    return
  fi
  expected_marker="$GDC_RELEASE_PROFILE $(profile_hash)"
  [[ "$marker" == "$expected_marker" ]] \
    || die "refusing to stack $GDC_RELEASE_PROFILE on an earlier candidate runtime marker: $marker"
  printf '%s %s\n' "$GONKA_RELEASE" "$GONKA_COMMIT"
}

require_host_upgrade_state_target() {
  local file="$1" node="$2" proposal_id="$3" plan_height="$4"
  local genesis_sha256="$5" chain_id="$6" expected_profile_hash
  [[ -s "$file" ]] || die "Host upgrade state is absent: $file"
  expected_profile_hash="$(profile_hash)"
  if ! {
    grep -qx "node=$node" "$file" \
      && grep -qx "proposal_id=$proposal_id" "$file" \
      && grep -qx "plan_height=$plan_height" "$file" \
      && grep -qx "genesis_sha256=$genesis_sha256" "$file" \
      && grep -qx "chain_id=$chain_id" "$file" \
      && grep -qx "release_profile=$GDC_RELEASE_PROFILE" "$file" \
      && grep -qx "profile_hash=$expected_profile_hash" "$file" \
      && grep -qx "inferenced_url=$INFERENCED_UPGRADE_URL" "$file" \
      && grep -qx "inferenced_sha256=$INFERENCED_UPGRADE_SHA256" "$file" \
      && grep -qx "dapi_url=$DAPI_UPGRADE_URL" "$file" \
      && grep -qx "dapi_sha256=$DAPI_UPGRADE_SHA256" "$file"
  }; then
    die 'prepared Host upgrade state is stale or targets another immutable profile'
  fi
}

upgrade_marker_name_for_scope() {
  case "$1" in
    full) printf '.gdc-release\n' ;;
    cosmovisor) printf '.gdc-binary-upgrade\n' ;;
    *) die "unknown upgrade marker scope: $1" ;;
  esac
}

classify_upgrade_runtime_marker() {
  local runtime_is_target="$1" marker="$2" expected_marker="$3" source_marker="${4:-}"
  if [[ "$runtime_is_target" == true ]]; then
    if [[ -z "$marker" || "$marker" == "$source_marker" ]]; then
      printf 'target-unmarked\n'
    elif [[ "$marker" == "$expected_marker" ]]; then
      printf 'target-marked\n'
    else
      die "target runtime has a marker for another immutable profile: $marker"
    fi
  else
    [[ -z "$marker" || "$marker" == "$source_marker" ]] \
      || die "source or unavailable runtime has a target marker: $marker"
    printf 'source-or-unavailable\n'
  fi
}

latest_baseline_pass_bundle() {
  local profile="${1:-v2026.07.23}" verdict bundle environment profile_hash genesis_profile_hash expected_profile_hash root
  genesis_profile_hash="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$STATE/phase-profiles/genesis.env" 2>/dev/null || true)"
  [[ -n "$genesis_profile_hash" ]] || return 1
  root="$(profile_root)"
  [[ -r "$root/profiles/releases/$profile.lock" && -r "$root/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" && -r "$root/profiles/models/$GDC_MODEL_PROFILE.lock" ]] || return 1
  expected_profile_hash="$(sha256sum "$root/profiles/releases/$profile.lock" \
    "$root/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" \
    "$root/profiles/models/$GDC_MODEL_PROFILE.lock" | awk '{print $1}' | sha256sum | awk '{print $1}')"
  [[ -n "$expected_profile_hash" ]] || return 1
  if [[ "$profile" == v2026.07.23 && "$expected_profile_hash" != "$genesis_profile_hash" ]]; then return 1; fi
  while IFS= read -r verdict; do
    grep -qx '# DevNet verification: PASS' "$verdict" || continue
    bundle="$(dirname "$verdict")"
    environment="$bundle/environment.txt"
    [[ -s "$environment" && -s "$bundle/node-sync.json" && -s "$bundle/participants.json" ]] || continue
    grep -qx "release_profile=$profile" "$environment" || continue
    grep -qx "chain_id=$CHAIN_ID" "$environment" || continue
    grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$environment" || continue
    profile_hash="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$environment")"
    [[ "$profile_hash" == "$expected_profile_hash" ]] || continue
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
  local profile="${1:-v2026.07.23}"
  local bundle index node address marker status node_height node_catching
  local reference_height lag baseline_profile_hash expected_profile_hash root
  local binary_marker node_versions source_release source_commit
  local expected_runtime_version expected_runtime_commit runtime_error
  local -a indexes expected_addresses live_addresses evidence_nodes

  step "Require a current $profile baseline PASS before the upgrade lifecycle"
  root="$(profile_root)"
  [[ -r "$root/profiles/releases/$profile.lock" && -r "$root/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" && -r "$root/profiles/models/$GDC_MODEL_PROFILE.lock" ]] \
    || die "unknown profile inputs for $profile ($GDC_DEPLOYMENT_PROFILE / $GDC_MODEL_PROFILE)"
  expected_profile_hash="$(sha256sum "$root/profiles/releases/$profile.lock" \
    "$root/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" \
    "$root/profiles/models/$GDC_MODEL_PROFILE.lock" | awk '{print $1}' | sha256sum | awk '{print $1}')"

  source_release="$(awk -F= '$1 == "GONKA_RELEASE" {gsub(/\"/, "", $2); print $2; exit}' "$root/profiles/releases/$profile.lock")"
  source_commit="$(awk -F= '$1 == "GONKA_COMMIT" {gsub(/\"/, "", $2); print $2; exit}' "$root/profiles/releases/$profile.lock")"
  [[ -n "$source_release" && -n "$source_commit" ]] || die "cannot read GONKA_RELEASE / GONKA_COMMIT from $profile.lock"

  bundle="$(latest_baseline_pass_bundle "$profile" || true)"
  [[ -n "$bundle" ]] || die "no matching $profile verification PASS; restore every intended participant and run ./gdc.sh --release $profile verify"

  mapfile -t indexes < <(configured_node_indexes)
  (( ${#indexes[@]} > 0 )) || die 'no joined participants are recorded for the verified baseline'
  mapfile -t evidence_nodes < <(jq -er '.[].node' "$bundle/node-sync.json" | LC_ALL=C sort)
  ((${#evidence_nodes[@]} == ${#indexes[@]})) || die 'baseline PASS participant count differs from current joined state; run verify again'

  expected_addresses=()
  reference_height="$(ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:26657/status' | jq -er '.result.sync_info.latest_block_height | tonumber')"
  baseline_profile_hash="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$bundle/environment.txt")"
  [[ "$baseline_profile_hash" == "$expected_profile_hash" ]] || die "baseline PASS profile hash ($baseline_profile_hash) does not match expected hash ($expected_profile_hash)"
  for node in "${GDC_NODES[@]}"; do
    [[ -e "$(node_joined_marker "$node")" ]] || continue
    grep -qx "$node" <(printf '%s\n' "${evidence_nodes[@]}") || die "$node is absent from the baseline PASS bundle; run verify again"
    address="$(jq -er .address "$(node_account_file "$node")")"
    expected_addresses+=("$address")
    marker="$(ssh "$node" "cat /srv/dai/deploy/$node/.gdc-release 2>/dev/null || true")"
    [[ "$marker" == "$profile $expected_profile_hash" ]] || die "$node does not have the verified $profile deployment marker"

    binary_marker="$(ssh "$node" "cat /srv/dai/deploy/$node/.gdc-binary-upgrade 2>/dev/null || true")"
    if [[ "${LAB_CANDIDATE:-false}" == true ]]; then
      read -r expected_runtime_version expected_runtime_commit \
        < <(candidate_runtime_identity_for_marker "$binary_marker" "$profile")
      if [[ -n "$binary_marker" ]]; then
        runtime_error="$node live runtime does not match its exact-target candidate marker"
      else
        runtime_error="$node live runtime does not match verified source baseline $profile ($source_release / $source_commit)"
      fi
    else
      [[ -z "$binary_marker" ]] \
        || die "$node has unexpected binary upgrade marker ($binary_marker); reset node before starting a different candidate"
      expected_runtime_version="$source_release"
      expected_runtime_commit="$source_commit"
      runtime_error="$node live runtime does not match verified source baseline $profile ($source_release / $source_commit)"
    fi

    node_versions="$(curl -fsS --connect-timeout 3 --max-time 8 "$(node_url "$node")/v1/versions" 2>/dev/null || true)"
    jq -e --arg version "$expected_runtime_version" --arg commit "$expected_runtime_commit" '
      (.node_version.version | ltrimstr("v")) == $version and .node_version.commit == $commit
    ' <<<"$node_versions" >/dev/null 2>&1 || die "$runtime_error"
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
