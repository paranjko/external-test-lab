#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-lifecycle-audit"
mkdir -p "$RUN"
record_phase_profile lifecycle-audit

require_pass_bundle() {
  local pattern="$1" heading="$2" evidence_name="${3:-verdict.md}" found
  found="$(find "$ROOT/artifacts/runs" -mindepth 2 -maxdepth 2 -path "$pattern" -name "$evidence_name" -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r candidate; do grep -qx "$heading" "$candidate" && printf '%s\n' "$candidate"; done | tail -n1)"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

printf '# Gonka DevNet lifecycle audit\n\n' >"$RUN/report.md"
missing=()
for item in \
  'P0 reduced topology|*/*|# DevNet verification: PASS' \
  'settlement evidence|*-escrow-*/*|# Chain-accounted inference: PASS' \
  'v4 HA|*-ha-v4/*|# DevShard v4 HA: PASS' \
  'public G-Meter|*-meter/*|# G-Meter: PASS' \
  'public Grafana|*-public-grafana/*|# Public Grafana: PASS'; do
  IFS='|' read -r label pattern heading <<<"$item"
  # A generic pair of settlements is insufficient: the public v4 and
  # compatibility v3 flows each need their own finalization record.
  if [[ "$label" == 'settlement evidence' ]]; then
    mapfile -t settled < <(find "$ROOT/artifacts/runs" -mindepth 2 -maxdepth 2 -path "$pattern" -name verdict.md -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r candidate; do grep -qx "$heading" "$candidate" && printf '%s\n' "$candidate"; done)
    versions=()
    for candidate in "${settled[@]}"; do
      version_file="$(dirname "$candidate")/finalize.json"
      [[ -f "$version_file" ]] || continue
      version="$(jq -r '.version // empty' "$version_file")"
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
  [[ "$label" == 'public G-Meter' || "$label" == 'public Grafana' ]] && evidence_name=finalize.md
  if found="$(require_pass_bundle "$pattern" "$heading" "$evidence_name")"; then
    printf -- '- %s: PASS (%s)\n' "$label" "$found" >>"$RUN/report.md"
  else
    missing+=("$label PASS bundle")
    printf -- '- %s: MISSING\n' "$label" >>"$RUN/report.md"
  fi
done

step 'Capture live upgrade and topology gates'
ssh gdc-node0 'curl -fsS http://127.0.0.1:26657/status' >"$RUN/chain-status.json"
proposal_id="${GDC_UPGRADE_PROPOSAL_ID:-}"
if [[ -z "$proposal_id" ]]; then
  ssh gdc-node0 'curl -fsS "http://127.0.0.1:1317/cosmos/gov/v1/proposals?pagination.limit=100&reverse=true"' >"$RUN/proposals.json"
  proposal_id="$(jq -er '
    [.proposals[]
     | select(any(.messages[]?; .["@type"] == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade" and .plan.name == "v0.2.15"))
     | .id] | max_by(tonumber)
  ' "$RUN/proposals.json")"
fi
[[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || die 'GDC_UPGRADE_PROPOSAL_ID must be a positive integer'
ssh gdc-node0 "curl -fsS http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal_id" >"$RUN/upgrade-proposal.json"
ssh gdc-node0 'curl -fsS http://127.0.0.1:1317/cosmos/upgrade/v1beta1/current_plan' >"$RUN/current-plan.json"
height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/chain-status.json")"
jq -e '.proposal.status == "PROPOSAL_STATUS_PASSED"' "$RUN/upgrade-proposal.json" >/dev/null || missing+=("passed v0.2.15 proposal #$proposal_id")
plan_height="$(jq -er '
  [.. | objects | select(."@type"? == "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade") | .plan? | select(.name == "v0.2.15") | .height | tonumber][0]
' "$RUN/upgrade-proposal.json")"
live_plan_height="$(jq -r '.plan.height? // empty' "$RUN/current-plan.json")"
if [[ -n "$live_plan_height" ]]; then
  [[ "$live_plan_height" == "$plan_height" ]] || missing+=("live upgrade plan differs from proposal #$proposal_id")
fi
printf -- '- upgrade proposal #%s: %s; current height: %s; plan height: %s\n' "$proposal_id" "$(jq -r '.proposal.status' "$RUN/upgrade-proposal.json")" "$height" "$plan_height" >>"$RUN/report.md"
if upgrade_bundle="$(require_pass_bundle '*-upgrade/*' '# DevNet upgrade: PASS')"; then
  grep -qx 'release_profile=testnet-0.2.15' "$(dirname "$upgrade_bundle")/target-profile.env" \
    || missing+=("upgrade PASS bundle has the wrong target profile")
  test -s "$(dirname "$upgrade_bundle")/state-comparison.json" \
    || missing+=("upgrade PASS bundle lacks state comparison")
  printf -- '- upgrade evidence: PASS (%s)\n' "$upgrade_bundle" >>"$RUN/report.md"
else
  missing+=("post-upgrade PASS evidence")
fi
if [[ "$height" -lt "$plan_height" ]]; then
  systemctl --user is-active --quiet "gdc-upgrade-proposal-$proposal_id.service" || missing+=("active state-based upgrade worker")
  printf -- '- upgrade: SCHEDULED; post-upgrade evidence required\n' >>"$RUN/report.md"
else
  printf -- '- upgrade: activation reached; post-upgrade evidence required\n' >>"$RUN/report.md"
fi

if host_is_skipped gdc-node3; then
  missing+=("node3 requalification, join, and five-participant baseline")
  printf -- '- node3: SKIP (temporary operator decision)\n' >>"$RUN/report.md"
fi
if [[ -z "${GDC_SEPOLIA_CONTRACT:-}" || -z "${GDC_SEPOLIA_BEACON_STATE_URL:-}" ]]; then
  missing+=("authorized Sepolia contract and beacon endpoint")
  printf -- '- bridge: BLOCKED (authorized contract/beacon endpoint absent)\n' >>"$RUN/report.md"
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
