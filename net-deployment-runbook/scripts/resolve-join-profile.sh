#!/usr/bin/env bash
# Compile the immutable local JOIN profile before lineage/state-sync preflight.
set -Eeuo pipefail

usage() { echo "Usage: $0 --observation FILE --components FILE --node-name NAME --public-host HOST [--p2p-port PORT] --operation new|restore [--restore-archive FILE] --run-id ID --output FILE" >&2; }
die() { printf 'join_profile_resolution_%s: %s\n' "$1" "$2" >&2; exit 1; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

observation=''; components=''; node_name=''; public_host=''; p2p_port=5000
operation=''; restore_archive=''; run_id=''; output=''
while (($#)); do
  case "$1" in
    --observation) observation="${2:-}"; shift 2 ;;
    --components) components="${2:-}"; shift 2 ;;
    --node-name) node_name="${2:-}"; shift 2 ;;
    --public-host) public_host="${2:-}"; shift 2 ;;
    --p2p-port) p2p_port="${2:-}"; shift 2 ;;
    --operation) operation="${2:-}"; shift 2 ;;
    --restore-archive) restore_archive="${2:-}"; shift 2 ;;
    --run-id) run_id="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$observation" && -r "$components" && -n "$output" ]] || { usage; exit 2; }
[[ "$node_name" =~ ^[a-z0-9][a-z0-9_-]*$ && "$public_host" =~ ^[A-Za-z0-9.-]+$ ]] || die input 'node name or public Host is invalid'
[[ "$p2p_port" =~ ^[1-9][0-9]{0,4}$ && "$p2p_port" -le 65535 ]] || die input 'P2P port is invalid'
[[ "$operation" =~ ^(new|restore)$ && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { usage; exit 2; }
[[ "$operation" == restore && -r "$restore_archive" || "$operation" == new && -z "$restore_archive" ]] || die input 'restore archive does not match operation'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || die dependency 'jq is required'
jq -e '.schema_version == 1 and .kind == "gdc-network-observation" and .result == {state:"ready",reason:"none"} and (.runtime_api_origins | type == "array" and length == 1)' "$observation" >/dev/null || die observation 'network observation is not ready'
jq -e 'type == "object" and (keys | sort) == ["core","dapi","host_envelope"] and (.core.mapping_source.kind == "official_artifact") and (.dapi.mapping_source.kind == "official_artifact") and (.core.installation.binary.sha256 | test("^[a-f0-9]{64}$")) and (.dapi.installation.binary.url | test("^https://github.com/")) and (.dapi.installation.binary.sha256 | test("^[a-f0-9]{64}$"))' "$components" >/dev/null || die component 'exact component resolution is invalid'
[[ "$(jq -cS .runtime.core "$observation")" == "$(jq -cS .core.observed "$components")" && "$(jq -cS .runtime.dapi "$observation")" == "$(jq -cS .dapi.observed "$components")" ]] || die component 'component resolution does not bind the selected runtime tuple'

identity='{"mode":"generate","stable_identity_layout":"gdc-identity-layout/v2"}'
if [[ "$operation" == restore ]]; then
  identity="$(jq -cn --arg sha "$(sha256_file "$restore_archive")" '{mode:"restore",stable_identity_layout:"gdc-identity-layout/v2",restore_archive_sha256:$sha}')"
fi
spec_tmp="$(mktemp "$(dirname "$output")/.join-profile-spec.XXXXXX")"
trap 'rm -f -- "$spec_tmp"' EXIT
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
  --argjson identity "$identity" --argjson fence "$([[ "$operation" == restore ]] && echo true || echo false)" \
  '{network:{chain_id:$chain,genesis_sha256:$genesis,bootstrap_sha256:$bootstrap,bootstrap_url:$bootstrap_url},seeds:{usable:$usable,unavailable:$unavailable},target:{node_name:$node,public_host:$host,public_p2p_address:("tcp://" + $host + ":" + ($port|tostring)),platform:"linux-amd64"},deployment:{gdc_source_commit:$commit,data_layout:"gdc-data-layout/v2",host_envelope:$host_envelope},components:{core:$core,dapi:$dapi},state_acquisition:{mode:"pending",providers:[],minimum_providers:0},identity:$identity,activation_policy:{application_required_for_complete:true,signer_allowed_in_profile:false,old_signer_fence_required:$fence}}' | jq -cS . >"$spec_tmp"
"$ROOT/scripts/join-profile.sh" create --observation "$observation" --spec "$spec_tmp" --operation "$operation" --run-id "$run_id" --output "$output"
