#!/bin/sh
# Verify retained, immutable inputs before any future mutating resume path.
set -eu

usage() { echo "Usage: $0 --run-dir DIR --run-id ID --node-name NAME --public-host HOST" >&2; }
run_dir=''; run_id=''; node_name=''; public_host=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir) [ "$#" -ge 2 ] || { usage; exit 2; }; run_dir="$2"; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || { usage; exit 2; }; run_id="$2"; shift 2 ;;
    --node-name) [ "$#" -ge 2 ] || { usage; exit 2; }; node_name="$2"; shift 2 ;;
    --public-host) [ "$#" -ge 2 ] || { usage; exit 2; }; public_host="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -d "$run_dir" ] || { usage; exit 2; }
printf '%s\n' "$run_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' || { usage; exit 2; }
printf '%s\n' "$node_name" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,62}$' || { usage; exit 2; }
printf '%s\n' "$public_host" | grep -Eq '^[A-Za-z0-9.-]+$' || { usage; exit 2; }

ROOT="$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"
gdc_require_jq || exit $?
profile="$run_dir/join-profile.v1.json"
observation="$run_dir/network-observation.v1.json"
receipts="$run_dir/receipts"
for file in "$profile" "$observation"; do
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(gdc_file_mode "$file")" = 600 ] \
    || { echo "resume input is missing, linked, or not 0600: ${file##*/}" >&2; exit 1; }
done
# Freshness is enforced immediately before the first mutation.  A retained
# profile is immutable and receipt-bound to this exact run, so expiry cannot
# make a correctly running state-sync or acceptance phase unresumable.
"$ROOT/scripts/join-profile.sh" validate --allow-expired "$profile" >/dev/null
profile_sha256="$(gdc_sha256 "$profile")"
observation_sha256="$(gdc_sha256 "$observation")"
jq -e --arg run_id "$run_id" --arg node "$node_name" --arg host "$public_host" --arg sha "$observation_sha256" '
  .run_id == $run_id and .spec.target.node_name == $node and .spec.target.public_host == $host and .observation.sha256 == $sha
' "$profile" >/dev/null || { echo 'resume profile does not bind the requested run, Host, and observation' >&2; exit 1; }
jq -e '.schema_version == 1 and .kind == "gdc-network-observation" and .result == {state:"ready",reason:"none"}' "$observation" >/dev/null \
  || { echo 'retained network observation is invalid' >&2; exit 1; }
chain="$($ROOT/scripts/verify-join-receipt-chain.sh --receipt-dir "$receipts")"
head="$(gdc_latest_join_receipt_name "$receipts")" || { echo 'resume receipt names are unsafe' >&2; exit 1; }
jq -e --arg run_id "$run_id" --arg node "$node_name" --arg profile "$profile_sha256" --arg observation "$observation_sha256" '
  .run_id == $run_id and .node_name == $node and .join_profile_sha256 == $profile and .network_observation_sha256 == $observation
' "$receipts/$head" >/dev/null || { echo 'resume receipt does not bind retained profile and observation' >&2; exit 1; }
if [ "$(printf '%s\n' "$chain" | jq -r .last_state)" = COMPLETE ]; then
  result="$run_dir/join-result.v1.json"
  [ -f "$result" ] && [ ! -L "$result" ] && [ "$(gdc_file_mode "$result")" = 600 ] \
    || { echo 'COMPLETE resume is missing its successful terminal result' >&2; exit 1; }
  jq -e --arg profile "$profile_sha256" '
    type == "object" and .schema_version == 1 and .kind == "gdc-host-join-result"
    and .outcome == "succeeded" and .phase == "acceptance" and .category == "internal"
    and .reason == "join_complete" and .exit_code == 0
    and .mutation == "signer_may_be_on" and .signer_state == "enabled"
    and .resume == "not_applicable" and .join_profile_sha256 == $profile
  ' "$result" >/dev/null || { echo 'COMPLETE resume terminal result is invalid or not bound to its profile' >&2; exit 1; }
fi
jq -cn --arg profile_sha256 "$profile_sha256" --arg observation_sha256 "$observation_sha256" --argjson receipt_chain "$chain" \
  '{resume_input_state:"verified",join_profile_sha256:$profile_sha256,network_observation_sha256:$observation_sha256,receipt_chain:$receipt_chain}'
