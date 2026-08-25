#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-lifecycle-audit"
mkdir -p "$RUN"
install_evidence_exit_trap 'DevNet lifecycle'
record_phase_profile lifecycle-audit

require_pass_bundle() {
  local pattern="$1" heading="$2" evidence_name="${3:-verdict.md}" found
  found="$(find "$GDC_HOME/runs" -mindepth 2 -maxdepth 2 -path "$pattern" -name "$evidence_name" -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r candidate; do grep -qx "$heading" "$candidate" && printf '%s\n' "$candidate"; done | tail -n1)"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

printf '# Gonka DevNet lifecycle audit\n\n' >"$RUN/report.md"
missing=()
capture_canonical_genesis "https://$GENESIS_PUBLIC_HOST/chain-rpc/genesis" "$RUN/live-genesis.json"
live_genesis_sha256="$(genesis_sha256 "$RUN/live-genesis.json")"

reset_bundle=""
while IFS= read -r candidate; do
  reset_hosts=()
  [[ -s "$candidate/reset-hosts.txt" ]] || continue
  mapfile -t reset_nodes <"$candidate/reset-hosts.txt"
  for host in "${reset_nodes[@]}"; do
    reset_hosts+=("$host")
    ml_host="$(node_ml_host "$host" || true)"
    [[ -z "$ml_host" ]] || reset_hosts+=("$ml_host")
  done
  if reset_evidence_bundle_is_valid "$candidate" "${reset_hosts[@]}"; then
    reset_bundle="$candidate"
  fi
done < <(find "$GDC_HOME/reset-manifests" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort)
if [[ -n "$reset_bundle" ]]; then
  printf -- '- reset preservation and public offline evidence: PASS (%s)\n' "$reset_bundle" >>"$RUN/report.md"
else
  missing+=("reset preservation and public offline evidence")
  printf -- '- reset preservation and public offline evidence: MISSING\n' >>"$RUN/report.md"
fi

for item in \
  'P0 reduced topology|*/*|# DevNet verification: PASS' \
  'gateway continuity|*-gateway-continuity/*|# Gateway continuity: PASS' \
  'settlement evidence|*-escrow-*/*|# Chain-accounted inference: PASS' \
  'v4 HA|*-ha-v4/*|# DevShard v4 HA: PASS' \
  'Sepolia bridge observer|*-bridge-observer-verify-*/*|# Sepolia bridge observer: PASS' \
  'public Grafana|*-public-grafana/*|# Public Grafana: PASS'; do
  IFS='|' read -r label pattern heading <<<"$item"
  if [[ "$label" == 'P0 reduced topology' || "$label" == 'gateway continuity' ]]; then
    if found="$(require_pass_bundle "$pattern" "$heading")"; then
      context_file="$(dirname "$found")/context.env"
      [[ "$label" == 'P0 reduced topology' ]] && context_file="$(dirname "$found")/environment.txt"
      if [[ ! -s "$context_file" ]] \
        || ! grep -qx 'release_profile=v2026.07.23' "$context_file" \
        || ! grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$context_file" \
        || ! grep -qx "chain_id=$CHAIN_ID" "$context_file" \
        || ! grep -qx "genesis_sha256=$live_genesis_sha256" "$context_file"; then
        missing+=("$label PASS bundle for the current v2026.07.23 Genesis and model")
        printf -- '- %s: STALE OR WRONG GENESIS/PROFILE (%s)\n' "$label" "$found" >>"$RUN/report.md"
      else
        printf -- '- %s: PASS (%s)\n' "$label" "$found" >>"$RUN/report.md"
      fi
    else
      missing+=("$label PASS bundle")
      printf -- '- %s: MISSING\n' "$label" >>"$RUN/report.md"
    fi
    continue
  fi
  # A generic pair of settlements is insufficient: the public v4 and
  # compatibility v3 flows each need their own finalization record.
  if [[ "$label" == 'settlement evidence' ]]; then
    mapfile -t settled < <(find "$GDC_HOME/runs" -mindepth 2 -maxdepth 2 -path "$pattern" -name verdict.md -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r candidate; do grep -qx "$heading" "$candidate" && printf '%s\n' "$candidate"; done)
    versions=()
    for candidate in "${settled[@]}"; do
      context_file="$(dirname "$candidate")/context.env"
      [[ -s "$context_file" ]] || continue
      grep -qx 'release_profile=v2026.08.06' "$context_file" || continue
      grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$context_file" || continue
      grep -qx "chain_id=$CHAIN_ID" "$context_file" || continue
      grep -qx "genesis_sha256=$live_genesis_sha256" "$context_file" || continue
      version="$(awk -F= '$1 == "devshard_version" {print $2; exit}' "$context_file")"
      [[ "$version" == v3 || "$version" == v4 ]] || continue
      versions+=("$version:$candidate")
    done
    for required_version in v3 v4; do
      if ! printf '%s\n' "${versions[@]}" | grep -q "^${required_version}:"; then
        missing+=("${required_version} chain-accounted settlement PASS bundle")
      fi
    done
    printf -- '- settlement bundles: %s\n' "${#versions[@]}" >>"$RUN/report.md"
    printf '%s\n' "${versions[@]}" >>"$RUN/report.md"
    continue
  fi
  evidence_name=verdict.md
  [[ "$label" == 'public Grafana' ]] && evidence_name=finalize.md
  if found="$(require_pass_bundle "$pattern" "$heading" "$evidence_name")"; then
    if [[ "$label" == 'v4 HA' || "$label" == 'Sepolia bridge observer' ]]; then
      context_file="$(dirname "$found")/context.env"
      if [[ ! -s "$context_file" ]] \
        || ! grep -qx 'release_profile=v2026.08.06' "$context_file" \
        || ! grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$context_file" \
        || ! grep -qx "chain_id=$CHAIN_ID" "$context_file" \
        || ! grep -qx "genesis_sha256=$live_genesis_sha256" "$context_file" \
        || { [[ "$label" == 'v4 HA' ]] && ! grep -qx 'devshard_version=v4' "$context_file"; }; then
        missing+=("$label PASS bundle for the current Genesis, v2026.08.06 and current model")
        printf -- '- %s: STALE OR WRONG GENESIS/PROFILE (%s)\n' "$label" "$found" >>"$RUN/report.md"
        continue
      fi
    fi
    printf -- '- %s: PASS (%s)\n' "$label" "$found" >>"$RUN/report.md"
  else
    missing+=("$label PASS bundle")
    printf -- '- %s: MISSING\n' "$label" >>"$RUN/report.md"
  fi
done

step 'Capture live upgrade and topology gates'
ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:26657/status' >"$RUN/chain-status.json"
proposal_id="${GDC_UPGRADE_PROPOSAL_ID:-}"
if [[ -z "$proposal_id" ]]; then
  ssh "$GENESIS_NODE" 'curl -fsS "http://127.0.0.1:1317/cosmos/gov/v1/proposals?pagination.limit=100&reverse=true"' >"$RUN/proposals.json"
  proposal_id="$(jq -r '
    [.proposals[]
     | select(any(.messages[]?; .["@type"] == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade" and .plan.name == "v0.2.15"))
     | .id] | if length == 0 then "" else max_by(tonumber) end
  ' "$RUN/proposals.json")"
fi
height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/chain-status.json")"
if [[ -n "$proposal_id" && ! "$proposal_id" =~ ^[1-9][0-9]*$ ]]; then
  die 'GDC_UPGRADE_PROPOSAL_ID must be a positive integer'
elif [[ -z "$proposal_id" ]]; then
  missing+=("submitted v0.2.15 software-upgrade proposal")
  printf -- '- upgrade proposal: MISSING; current height: %s\n' "$height" >>"$RUN/report.md"
else
  ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/upgrade-proposal.json"
  ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/cosmos/upgrade/v1beta1/current_plan' >"$RUN/current-plan.json"
  jq -e '.proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/upgrade-proposal.json" >/dev/null || missing+=("passed v0.2.15 proposal #$proposal_id")
  plan_height="$(jq -er '
    [.. | objects | select(."@type"? == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade") | .plan? | select(.name == "v0.2.15") | .height | tonumber][0]
  ' "$RUN/upgrade-proposal.json")"
  live_plan_height="$(jq -r '.plan.height? // empty' "$RUN/current-plan.json")"
  if [[ -n "$live_plan_height" ]]; then
    [[ "$live_plan_height" == "$plan_height" ]] || missing+=("live upgrade plan differs from proposal #$proposal_id")
  fi
  printf -- '- upgrade proposal #%s: %s; current height: %s; plan height: %s\n' "$proposal_id" "$(jq -r '.proposal.status' "$RUN/upgrade-proposal.json")" "$height" "$plan_height" >>"$RUN/report.md"
  if [[ "$height" -lt "$plan_height" ]]; then
    systemctl --user is-active --quiet "gdc-upgrade-proposal-$proposal_id.service" || missing+=("active state-based upgrade worker")
    printf -- '- upgrade: SCHEDULED; post-upgrade evidence required\n' >>"$RUN/report.md"
  else
    printf -- '- upgrade: activation reached; post-upgrade evidence required\n' >>"$RUN/report.md"
  fi
fi
if upgrade_bundle="$(require_pass_bundle '*-upgrade/*' '# DevNet upgrade: PASS')"; then
  grep -qx 'release_profile=v2026.08.06' "$(dirname "$upgrade_bundle")/target-profile.env" \
    || missing+=("upgrade PASS bundle has the wrong target profile")
  upgrade_dir="$(dirname "$upgrade_bundle")"
  if [[ ! -s "$upgrade_dir/state-comparison.json" ]] \
    && { [[ ! -s "$upgrade_dir/participant-comparison.json" ]] || [[ ! -s "$upgrade_dir/power-comparison.json" ]]; }; then
    missing+=("upgrade PASS bundle lacks state comparison")
  fi
  printf -- '- upgrade evidence: PASS (%s)\n' "$upgrade_bundle" >>"$RUN/report.md"
else
  missing+=("post-upgrade PASS evidence")
fi
if [[ -z "${GDC_SEPOLIA_CONTRACT:-}" || -z "${GDC_SEPOLIA_BEACON_STATE_URL:-}" ]]; then
  missing+=("authorized Sepolia contract and beacon endpoint")
  printf -- '- bridge: BLOCKED (authorized contract/beacon endpoint absent)\n' >>"$RUN/report.md"
else
  if bridge_register_bundle="$(require_pass_bundle '*-bridge-register-sepolia/*' '# Sepolia bridge governance registration: PASS')"; then
    register_dir="$(dirname "$bridge_register_bundle")"
    grep -qx "$(printf '%s\n' "$GDC_SEPOLIA_CONTRACT")" "$register_dir/contract-address.txt" \
      || missing+=("bridge registration bundle targets a different contract")
    printf -- '- bridge governance: PASS (%s)\n' "$bridge_register_bundle" >>"$RUN/report.md"
  else
    missing+=("passed Sepolia bridge governance registration")
    printf -- '- bridge governance: BLOCKED (no passed registration bundle)\n' >>"$RUN/report.md"
  fi
  if bridge_runtime_bundle="$(require_pass_bundle '*-bridge-observer-verify-*/*' '# Sepolia bridge observer: PASS')"; then
    runtime_dir="$(dirname "$bridge_runtime_bundle")"
    jq -e '.chainId == "sepolia" and (.blockNumber | tonumber) > 0' "$runtime_dir/latest-block.json" >/dev/null 2>&1 \
      || missing+=("bridge observer bundle lacks a finalized Sepolia block cursor")
    printf -- '- bridge observer: PASS (%s)\n' "$bridge_runtime_bundle" >>"$RUN/report.md"
  else
    missing+=("Sepolia bridge observer verification PASS")
    printf -- '- bridge observer: BLOCKED (no finalized-block PASS bundle)\n' >>"$RUN/report.md"
  fi
fi

if (( ${#missing[@]} == 0 )); then
  cat >"$RUN/verdict.md" <<EOF
# DevNet lifecycle: PASS

All required evidence bundles and live lifecycle gates passed. See report.md.
EOF
  printf 'PASS lifecycle audit: %s\n' "$RUN"
  exit 0
fi
{
  printf '# DevNet lifecycle: INCOMPLETE\n\n'
  printf 'The following requirements are not yet proven:\n'
  for item in "${missing[@]}"; do printf -- '- %s\n' "$item"; done
} >"$RUN/verdict.md"
printf 'INCOMPLETE lifecycle audit: %s\n' "$RUN"
exit 3
