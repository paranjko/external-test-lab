#!/usr/bin/env bash
set -Eeuo pipefail

kit_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

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

write_env() {
  local file="$1"
  shift
  install -d -m 0700 "$(dirname "$file")"
  umask 077
  printf '%s\n' "$@" >"$file"
}

# Variables initialized here are consumed by scripts that source this library.
# shellcheck disable=SC2034
load_project() {
  ROOT="$(kit_root)"
  ENV_FILE="${GDC_ENV:-$ROOT/.env}"
  [[ -s "$ENV_FILE" ]] || die "create $ROOT/.env from .env.example"
  # A shell invocation is the explicit per-rehearsal override.  Do not let an
  # empty example value in .env silently re-include an intentionally skipped
  # host (for example: GDC_SKIP_HOSTS='gdc-node2 gdc-node3' ./gdc.sh prepare).
  local caller_skip_hosts=''
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
  if [[ -z "${GDC_RESOLVED_IMAGE_LOCK:-}" && -r "$ROOT/state/resolved-images/${GDC_RELEASE_PROFILE:-testnet-0.2.14}.lock" ]]; then
    export GDC_RESOLVED_IMAGE_LOCK="$ROOT/state/resolved-images/${GDC_RELEASE_PROFILE:-testnet-0.2.14}.lock"
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
  DATA_ROOT=/srv/dai
  GENESIS_INSTALL_PATH=/srv/dai/shared/genesis.json
  HF_CACHE_ROOT=/srv/dai/hf-cache
  NODE0_PUBLIC_HOST=node0.gonka-dev.net
  NODE1_PUBLIC_HOST=node1.gonka-dev.net
  NODE2_PUBLIC_HOST=node2.gonka-dev.net
  NODE3_PUBLIC_HOST=node3.gonka-dev.net
  NODE4_PUBLIC_HOST=node4.gonka-dev.net
  NODE0_P2P_PORT=5000 NODE1_P2P_PORT=5000 NODE2_P2P_PORT=5000
  NODE3_P2P_PORT=5000 NODE4_P2P_PORT=5000
  NODE0_GPU_PROFILE=a5000-24g
  NODE1_GPU_PROFILE=t4-16g
  NODE2_GPU_PROFILE=4090-24g
  NODE3_GPU_PROFILE=3090-24g
  NODE4_GPU_PROFILE=blackwell-16g
  GRAFANA_PUBLIC_DASHBOARD_UID=gdc-overview
  # Public-dashboard URLs are intentionally capability links, not credentials.
  # Keep this stable so re-running ops monitoring repairs the same share.
  GRAFANA_PUBLIC_DASHBOARD_SHARE_UID=5fd40e12-5334-4d32-aea2-dcfe85afb3f2
  GRAFANA_PUBLIC_DASHBOARD_TOKEN=321a0d961e7f4b4ea6da843777c032eb

  mapfile -t node0_addresses < <(getent ahostsv4 "$NODE0_PUBLIC_HOST" | awk '{print $1}' | sort -u)
  (( ${#node0_addresses[@]} == 1 )) || die "$NODE0_PUBLIC_HOST must resolve to exactly one IPv4 address"
  MONITORING_CIDR="${node0_addresses[0]}/32"
  mapfile -t node4_edge_addresses < <(getent ahostsv4 "$NODE4_PUBLIC_HOST" | awk '{print $1}' | sort -u)
  (( ${#node4_edge_addresses[@]} == 1 )) || die "$NODE4_PUBLIC_HOST must resolve to exactly one IPv4 address"
  METER_EDGE_CIDR="${node4_edge_addresses[0]}/32"

  # The node4 Network Node and its Blackwell ML host are different machines.
  # Resolve the latter from the operator's SSH inventory, never from the
  # node4 public DNS name: port 5000 on node4 is Tendermint P2P, not MLNode.
  NODE4_ML_ENDPOINT="${GDC_NODE4_ML_ENDPOINT:-$(ssh -G gdc-node4-ml 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')}"
  [[ -n "$NODE4_ML_ENDPOINT" ]] || die 'cannot determine gdc-node4-ml endpoint from SSH configuration'
  [[ "$NODE4_ML_ENDPOINT" != "$NODE4_PUBLIC_HOST" ]] || die 'gdc-node4-ml endpoint must differ from node4 public host'
  NODE4_ML_MONITOR_HOST="$NODE4_ML_ENDPOINT"

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
    die "no successful ML qualification for $host; run ./gdc.sh qualify-ml before creating its chain participant"
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
    die "${warn}; run ./gdc.sh qualify-ml before creating its chain participant"
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
  cat >"$INVENTORY" <<EOF
CHAIN_ID=$CHAIN_ID
BASE_DENOM=$BASE_DENOM
BASE_DOMAIN=$BASE_DOMAIN
SITE_HOST=$SITE_HOST
API_HOST=$API_HOST
GRAFANA_HOST=$GRAFANA_HOST
ACME_EMAIL=$ACME_EMAIL
MONITORING_CIDR=$MONITORING_CIDR
METER_EDGE_CIDR=$METER_EDGE_CIDR
NODE0_PUBLIC_HOST=$NODE0_PUBLIC_HOST
NODE0_P2P_PORT=5000
NODE0_GPU_PROFILE=$NODE0_GPU_PROFILE
NODE1_PUBLIC_HOST=$NODE1_PUBLIC_HOST
NODE1_P2P_PORT=5000
NODE1_GPU_PROFILE=$NODE1_GPU_PROFILE
NODE2_PUBLIC_HOST=$NODE2_PUBLIC_HOST
NODE2_P2P_PORT=5000
NODE2_GPU_PROFILE=$NODE2_GPU_PROFILE
NODE3_PUBLIC_HOST=$NODE3_PUBLIC_HOST
NODE3_P2P_PORT=5000
NODE3_GPU_PROFILE=$NODE3_GPU_PROFILE
NODE4_PUBLIC_HOST=$NODE4_PUBLIC_HOST
NODE4_P2P_PORT=5000
NODE4_GPU_PROFILE=$NODE4_GPU_PROFILE
NODE4_ML_ENDPOINT=$NODE4_ML_ENDPOINT
NODE4_ML_MONITOR_HOST=$NODE4_ML_MONITOR_HOST
GRAFANA_PUBLIC_DASHBOARD_UID=$GRAFANA_PUBLIC_DASHBOARD_UID
GRAFANA_PUBLIC_DASHBOARD_SHARE_UID=$GRAFANA_PUBLIC_DASHBOARD_SHARE_UID
GRAFANA_PUBLIC_DASHBOARD_TOKEN=$GRAFANA_PUBLIC_DASHBOARD_TOKEN
TELEGRAM_BOT_URL=$TELEGRAM_BOT_URL
DATA_ROOT=$DATA_ROOT
GENESIS_INSTALL_PATH=$GENESIS_INSTALL_PATH
HF_CACHE_ROOT=$HF_CACHE_ROOT
EOF
}

node_name() {
  [[ "${1:-}" =~ ^(node[1-4]|gdc-node[1-4])$ ]] || die "expected node1, gdc-node1, node2, gdc-node2, node3, gdc-node3, node4, or gdc-node4"
  [[ "$1" == gdc-* ]] && printf '%s\n' "$1" || printf 'gdc-%s\n' "$1"
}

node_url() {
  local index="${1#gdc-node}" variable="NODE${1#gdc-node}_PUBLIC_HOST"
  [[ "$index" =~ ^[0-4]$ ]] || die "invalid node: $1"
  printf 'https://%s\n' "${!variable}"
}

ssh_ready() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
    "$1" true </dev/null >/dev/null 2>&1
}

configured_node_indexes() {
  local i
  for i in 0 1 2 3 4; do
    [[ -e "$STATE/joined/gdc-node$i" ]] && printf '%s\n' "$i"
  done
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
