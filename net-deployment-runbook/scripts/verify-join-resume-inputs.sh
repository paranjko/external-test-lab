#!/usr/bin/env bash
# Verify retained, immutable inputs before any future mutating resume path.
set -Eeuo pipefail

usage() { echo "Usage: $0 --run-dir DIR --run-id ID --node-name NAME --public-host HOST" >&2; }
run_dir=''; run_id=''; node_name=''; public_host=''
while (($#)); do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --run-id) run_id="${2:-}"; shift 2 ;;
    --node-name) node_name="${2:-}"; shift 2 ;;
    --public-host) public_host="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -d "$run_dir" && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$node_name" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$public_host" =~ ^[A-Za-z0-9.-]+$ ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
profile="$run_dir/join-profile.v1.json"
observation="$run_dir/network-observation.v1.json"
receipts="$run_dir/receipts"
for file in "$profile" "$observation"; do
  [[ -f "$file" && ! -L "$file" && "$(stat -c %a "$file")" == 600 ]] \
    || { echo "resume input is missing, linked, or not 0600: ${file##*/}" >&2; exit 1; }
done
# Freshness is enforced immediately before the first mutation.  A retained
# profile is immutable and receipt-bound to this exact run, so expiry cannot
# make a correctly running state-sync or acceptance phase unresumable.
"$ROOT/scripts/join-profile.sh" validate --allow-expired "$profile" >/dev/null
profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
observation_sha256="$(sha256sum "$observation" | awk '{print $1}')"
jq -e --arg run_id "$run_id" --arg node "$node_name" --arg host "$public_host" --arg sha "$observation_sha256" '
  .run_id == $run_id and .spec.target.node_name == $node and .spec.target.public_host == $host and .observation.sha256 == $sha
' "$profile" >/dev/null || { echo 'resume profile does not bind the requested run, Host, and observation' >&2; exit 1; }
jq -e '.schema_version == 1 and .kind == "gdc-network-observation" and .result == {state:"ready",reason:"none"}' "$observation" >/dev/null \
  || { echo 'retained network observation is invalid' >&2; exit 1; }
chain="$($ROOT/scripts/verify-join-receipt-chain.sh --receipt-dir "$receipts")"
head="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
jq -e --arg run_id "$run_id" --arg node "$node_name" --arg profile "$profile_sha256" --arg observation "$observation_sha256" '
  .run_id == $run_id and .node_name == $node and .join_profile_sha256 == $profile and .network_observation_sha256 == $observation
' "$receipts/$head" >/dev/null || { echo 'resume receipt does not bind retained profile and observation' >&2; exit 1; }
jq -cn --arg profile_sha256 "$profile_sha256" --arg observation_sha256 "$observation_sha256" --argjson receipt_chain "$chain" \
  '{resume_input_state:"verified",join_profile_sha256:$profile_sha256,network_observation_sha256:$observation_sha256,receipt_chain:$receipt_chain}'
