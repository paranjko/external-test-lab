#!/usr/bin/env bash
# Compile a declaration, not a network observation. No registry/tag lookup or
# software-majority vote is involved; chain trust remains a separate preflight.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf 'bootstrap_software_unsupported: %s\n' "$1" >&2; exit 1; }
[[ $# -ge 3 ]] || die 'expected observation|components INPUT OUTPUT [URL RUN_ID SOURCE_RPC]'
mode=$1 input=$2 output=$3
case "$mode" in
  observation)
    [[ $# -eq 6 ]] || die 'observation requires URL, run ID and optional source RPC'
    url=$4 run_id=$5 source_rpc=$6
    "$ROOT/scripts/network-bootstrap.sh" verify "$input" >/dev/null
    jq -e -f "$ROOT/scripts/bootstrap-join-software.jq" "$input" >/dev/null || die 'this GDC does not support the declared recipe, platform, component set or runtime artifacts'
    if [[ -n "$source_rpc" ]]; then
      jq -e --arg rpc "$source_rpc" '[.seeds[] | select((.rpc | rtrimstr("/")) == $rpc)] | length == 1' "$input" >/dev/null || die 'operator source must identify one Bootstrap seed'
    fi
    fingerprint="$(jq -cS '{chain_id,genesis,software}' "$input" | sha256sum | awk '{print $1}')"
    mkdir -p "$(dirname "$output")"
    temporary="$(mktemp "$(dirname "$output")/.bootstrap-software.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    jq -cS --arg url "$url" --arg run "$run_id" --arg source "$source_rpc" \
      --arg sha "$(sha256sum "$input" | awk '{print $1}')" --arg fingerprint "$fingerprint" \
      --arg now "$(date -u +%FT%TZ)" --arg expiry "$(date -u -d '+600 seconds' +%FT%TZ)" '
      {schema_version:1,kind:"gdc-network-observation",run_id:$run,observed_at:$now,expires_at:$expiry,
       network_state_id:$fingerprint,bootstrap:{url:$url,document_sha256:$sha,chain_id:.chain_id,genesis_sha256:.genesis.sha256},
       policy:({policy_id:"bootstrap-software/v1",mode:"bootstrap_software",software_authority:"bootstrap"} +
         (if $source != "" then {mode:"operator_source",source_rpc:$source} else {} end)),
       seeds:[],runtime_api_origins:[],software:.software,
       runtime:{core:(.software.components.node | {version:(.version | ltrimstr("v")),commit}),
                dapi:(.software.components.api | {version:(.version | ltrimstr("v")),commit})},
       result:{state:"ready",reason:"none"}}
    ' "$input" >"$temporary"
    chmod 0600 "$temporary"; mv "$temporary" "$output"
    printf 'PASS selected JOIN software from Bootstrap declaration receipt=%s\n' "$output"
    ;;
  components)
    jq -e -f "$ROOT/scripts/bootstrap-join-software.jq" "$input" >/dev/null || die 'unsupported retained software declaration'
    mkdir -p "$(dirname "$output")"
    temporary="$(mktemp "$(dirname "$output")/.bootstrap-components.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    jq -cS '
      . as $o | .software as $s | $s.components as $c |
      {kind:"official_artifact",id:"bootstrap-software/v1",definition_sha256:$o.bootstrap.document_sha256} as $origin |
      def component($runtime; $declared; $binary):
        {observed:$runtime,expected_runtime:$runtime,
         installation:{mode:"image_plus_cosmovisor",image:($declared.image | capture("^(?<repository>.+)@(?<digest>sha256:[a-f0-9]{64})$")),
           binary:($binary | {url,sha256}),runtime_upgrade:$declared.upgrade},mapping_source:$origin};
      {core:component($o.runtime.core;$c.node;$s.operator_cli.artifact),
       dapi:component($o.runtime.dapi;$c.api;$c.api.upgrade.artifact),software:$s,
       host_envelope:{tmkms_image:$c.tmkms.image,postgres_image:$c["payload-postgres"].image,
        edge_api_image:$c["edge-api"].image,versiond_image:$c.versiond.image,proxy_image:$c.proxy.image,
        explorer_image:$c.explorer.image,mlnode_image:$c.mlnode.image,mlnode_proxy_image:$c["inference-proxy"].image,
        caddy_image:$c.caddy.image,grafana_image:$c.grafana.image,node_exporter_image:$c["node-exporter"].image,cadvisor_image:$c.cadvisor.image,
        host_stack:{repository:"gonka-ai/gonka",commit:$s.deployment.commit,
          compose_sha256:([$s.deployment.compose_files[] | select(.path == "deploy/join/docker-compose.yml")][0].sha256),api_image:$c.api.image},
        dashboard_port:5173,edge_api_compose_profile:"edge-api",edge_api_service_name:"edge-api",
        model_id:$s.model.id,model_revision:$s.model.revision,mlnode_context_length:$s.model.context_length,
        mlnode_max_num_seqs:$s.model.max_num_seqs,mlnode_gpu_memory_utilization:($s.model.gpu_memory_utilization|tostring),
        mlnode_dtype:$s.model.dtype,mlnode_tensor_parallel_size:$s.model.tensor_parallel_size,
        join_effective_epochs:2,join_effective_timeout_seconds:7200,mapping_source:$origin}}
    ' "$input" >"$temporary"
    chmod 0600 "$temporary"; mv "$temporary" "$output"
    printf 'PASS compiled pinned Bootstrap components output=%s\n' "$output"
    ;;
  *) die 'unknown mode' ;;
esac
