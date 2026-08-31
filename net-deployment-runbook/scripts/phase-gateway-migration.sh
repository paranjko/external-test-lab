#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
load_project

[[ $# -eq 3 ]] || die 'expected gateway migrate preflight|verify|drain SOURCE_VERSION TARGET_VERSION'
action="$1"
source_version="$2"
target_version="$3"
[[ "$action" =~ ^(preflight|verify|drain)$ ]] || die 'gateway migration action must be preflight, verify or drain'
[[ "$source_version" =~ ^v[345]$ && "$target_version" =~ ^v[345]$ && "$source_version" != "$target_version" ]] \
  || die 'gateway migration requires two different supported DevShard versions'

protocol_contract="$(selected_gateway_protocol_contract)" \
  || die 'selected profile has no verified DevShard protocol contract'
[[ " $protocol_contract " == *" $target_version "* ]] \
  || die "selected profile does not support target protocol $target_version"

protocol_artifact() {
  local version="$1" field="$2"
  case "$version:$field" in
    v3:url) printf '%s\n' "$DEVSHARD_V3_URL" ;;
    v3:sha256) printf '%s\n' "$DEVSHARD_V3_SHA256" ;;
    v4:url) printf '%s\n' "$DEVSHARD_V4_URL" ;;
    v4:sha256) printf '%s\n' "$DEVSHARD_V4_SHA256" ;;
    v5:url) printf '%s\n' "$DEVSHARD_V5_URL" ;;
    v5:sha256) printf '%s\n' "$DEVSHARD_V5_SHA256" ;;
    *) return 2 ;;
  esac
}

target_url="$(protocol_artifact "$target_version" url)"
target_sha256="$(protocol_artifact "$target_version" sha256)"
[[ "$target_url" =~ ^https:// && "$target_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || die "selected profile has incomplete $target_version artifact identity"

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}-gateway-migration-$source_version-$target_version-$action"
mkdir -p "$RUN"
install_evidence_exit_trap 'DevShard gateway migration observation'
record_phase_profile "gateway-migration-$action"

params="$RUN/chain-params.json"
"$ROOT/scripts/inferenced.sh" query inference params \
  --node "${GDC_CHAIN_RPC_URL:-https://${PUBLIC_EDGE_HOST}/chain-rpc/}" \
  --chain-id "$CHAIN_ID" --output json >"$params"
source_identity="$(jq -er --arg version "$source_version" '
  (.params // .).devshard_escrow_params.approved_versions
  | map(select(.name == $version))
  | select(length == 1)
  | .[0]
  | select((.binary | test("^https://")) and (.sha256 | test("^[0-9a-f]{64}$")))
  | [.binary, .sha256]
  | @tsv
' "$params")" || die "chain has no unique approved $source_version artifact identity"
IFS=$'\t' read -r source_url source_sha256 <<<"$source_identity"
"$ROOT/scripts/verify-approved-devshard-version.sh" \
  "$params" "$source_version" "$source_url" "$source_sha256"
"$ROOT/scripts/verify-approved-devshard-version.sh" \
  "$params" "$target_version" "$target_url" "$target_sha256"

remote="/tmp/gdc-gateway-migration-$$"
scp -q "$ROOT/04-ops/capture-gateway-migration-state.sh" "$GATEWAY_NODE:$remote"
smoke=false
[[ "$action" == preflight ]] || smoke=true
if ! ssh -T "$GATEWAY_NODE" \
  "set -Eeuo pipefail; chmod 0700 '$remote'; GDC_GATEWAY_MIGRATION_SMOKE=$smoke '$remote' '$source_version' '$target_version' '${GDC_GATEWAY_MIGRATION_TARGET_PORT:-18085}' '$CHAIN_ID' '$MODEL_ID'; rm -f '$remote'" \
  >"$RUN/snapshot.json"; then
  ssh "$GATEWAY_NODE" "rm -f '$remote'" >/dev/null 2>&1 || true
  die "could not capture sanitized gateway migration state from $GATEWAY_NODE"
fi

"$ROOT/scripts/classify-gateway-migration.sh" \
  "$action" "$RUN/snapshot.json" \
  "$source_url" "$source_sha256" "$target_url" "$target_sha256" \
  "$CHAIN_ID" "$MODEL_ID" "$RUN"
