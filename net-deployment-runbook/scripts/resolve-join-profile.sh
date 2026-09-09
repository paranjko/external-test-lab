#!/bin/sh
# Compile the immutable local JOIN profile before lineage/state-sync preflight.
set -eu

usage() { echo "Usage: $0 --observation FILE --components FILE --node-name NAME --public-host HOST [--p2p-port PORT] --operation new|restore [--restore-archive FILE] --run-id ID --output FILE" >&2; }
die() { printf 'join_profile_resolution_%s: %s\n' "$1" "$2" >&2; exit 1; }

observation=''; components=''; node_name=''; public_host=''; p2p_port=5000
operation=''; restore_archive=''; run_id=''; output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --observation) [ "$#" -ge 2 ] || { usage; exit 2; }; observation="$2"; shift 2 ;;
    --components) [ "$#" -ge 2 ] || { usage; exit 2; }; components="$2"; shift 2 ;;
    --node-name) [ "$#" -ge 2 ] || { usage; exit 2; }; node_name="$2"; shift 2 ;;
    --public-host) [ "$#" -ge 2 ] || { usage; exit 2; }; public_host="$2"; shift 2 ;;
    --p2p-port) [ "$#" -ge 2 ] || { usage; exit 2; }; p2p_port="$2"; shift 2 ;;
    --operation) [ "$#" -ge 2 ] || { usage; exit 2; }; operation="$2"; shift 2 ;;
    --restore-archive) [ "$#" -ge 2 ] || { usage; exit 2; }; restore_archive="$2"; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || { usage; exit 2; }; run_id="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage; exit 2; }; output="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -r "$observation" ] && [ -r "$components" ] && [ -n "$output" ] || { usage; exit 2; }
printf '%s\n' "$node_name" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' || die input 'node name or public Host is invalid'
printf '%s\n' "$public_host" | grep -Eq '^[A-Za-z0-9.-]+$' || die input 'node name or public Host is invalid'
printf '%s\n' "$p2p_port" | grep -Eq '^[1-9][0-9]{0,4}$' && [ "$p2p_port" -le 65535 ] || die input 'P2P port is invalid'
case "$operation" in new|restore) ;; *) usage; exit 2 ;; esac
printf '%s\n' "$run_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' || { usage; exit 2; }
if [ "$operation" = restore ]; then [ -r "$restore_archive" ] || die input 'restore archive does not match operation'; else [ -z "$restore_archive" ] || die input 'restore archive does not match operation'; fi

ROOT="$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"
gdc_require_jq || exit $?
jq -e '.schema_version == 1 and .kind == "gdc-network-observation" and .result == {state:"ready",reason:"none"} and (.runtime_api_origins | type == "array" and length == 1)' "$observation" >/dev/null || die observation 'network observation is not ready'
jq -e 'type == "object" and (keys | sort) == ["core","dapi","host_envelope"] and (.core.mapping_source.kind == "official_artifact") and (.dapi.mapping_source.kind == "official_artifact") and (.core.installation.binary.sha256 | test("^[a-f0-9]{64}$")) and (.dapi.installation.binary.url | test("^https://github.com/")) and (.dapi.installation.binary.sha256 | test("^[a-f0-9]{64}$"))' "$components" >/dev/null || die component 'exact component resolution is invalid'
[ "$(jq -cS .runtime.core "$observation")" = "$(jq -cS .core.observed "$components")" ] && [ "$(jq -cS .runtime.dapi "$observation")" = "$(jq -cS .dapi.observed "$components")" ] || die component 'component resolution does not bind the selected runtime tuple'

identity='{"mode":"generate","stable_identity_layout":"gdc-identity-layout/v2"}'
fence=false
if [ "$operation" = restore ]; then
  identity="$(jq -cn --arg sha "$(gdc_sha256 "$restore_archive")" '{mode:"restore",stable_identity_layout:"gdc-identity-layout/v2",restore_archive_sha256:$sha}')"
  fence=true
fi
spec_tmp="$(mktemp "$(dirname "$output")/.join-profile-spec.XXXXXX")"
trap 'rm -f "$spec_tmp"' EXIT HUP INT TERM
# Seed reachability, catching_up and endpoint errors are observations, not
# executable profile semantics. Keep only a stable policy marker here; the
# complete bounded diagnostics remain in the receipt-bound observation.
jq -cn \
  --arg chain "$(jq -r .bootstrap.chain_id "$observation")" \
  --arg genesis "$(jq -r .bootstrap.genesis_sha256 "$observation")" \
  --arg bootstrap "$(jq -r .bootstrap.document_sha256 "$observation")" \
  --arg bootstrap_url "$(jq -r .bootstrap.url "$observation")" \
  --arg node "$node_name" --arg host "$public_host" --argjson port "$p2p_port" \
  --arg commit "$(git -C "$ROOT" rev-parse HEAD)" \
  --argjson core "$(jq -c .core "$components")" --argjson dapi "$(jq -c .dapi "$components")" \
  --argjson host_envelope "$(jq -c .host_envelope "$components")" \
  --argjson usable '[{"selection_policy":"net-info-software-majority/v1"}]' \
  --argjson unavailable '[]' \
  --argjson identity "$identity" --argjson fence "$fence" \
  '{network:{chain_id:$chain,genesis_sha256:$genesis,bootstrap_sha256:$bootstrap,bootstrap_url:$bootstrap_url},seeds:{usable:$usable,unavailable:$unavailable},target:{node_name:$node,public_host:$host,public_p2p_address:("tcp://" + $host + ":" + ($port|tostring)),platform:"linux-amd64"},deployment:{gdc_source_commit:$commit,data_layout:"gdc-data-layout/v2",host_envelope:$host_envelope},components:{core:$core,dapi:$dapi},state_acquisition:{mode:"pending",providers:[],minimum_providers:0},identity:$identity,activation_policy:{application_required_for_complete:true,signer_allowed_in_profile:false,old_signer_fence_required:$fence}}' | jq -cS . >"$spec_tmp"
"$ROOT/scripts/join-profile.sh" create --observation "$observation" --spec "$spec_tmp" --operation "$operation" --run-id "$run_id" --output "$output"
