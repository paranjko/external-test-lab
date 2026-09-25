#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 create --observation FILE --spec FILE --operation new|restore --run-id ID --output FILE | validate [--allow-expired] FILE" >&2; }
die() { printf 'join_profile_invalid: %s\n' "$1" >&2; exit 1; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

validate() {
  local file="$1" allow_expired="${2:-false}" expected_id actual_id operation identity_mode valid_until_epoch now_epoch
  jq -e --argjson allow_legacy "$allow_expired" '
    type == "object" and (keys | sort) == ["created_at","decision","kind","observation","operation","profile_id","run_id","schema_version","spec","valid_until"] and
    .schema_version == 1 and .kind == "gdc-host-join-profile" and
    (.run_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.operation | IN("new","restore")) and .decision == "ready_full" and
    (.profile_id | test("^[a-f0-9]{64}$")) and
    (.observation | type == "object" and (keys | sort) == ["network_state_id","sha256"] and (.sha256 | test("^[a-f0-9]{64}$")) and (.network_state_id | test("^[a-f0-9]{64}$"))) and
    (.spec | type == "object" and (keys | sort) == ["activation_policy","components","deployment","identity","network","seeds","state_acquisition","target"]) and
    (.spec.target.node_name | test("^[a-z0-9][a-z0-9_-]*$")) and .spec.target.platform == "linux-amd64" and
    (($allow_legacy and (.spec.target | has("accelerator") | not)) or
    (.spec.target.accelerator | type == "object" and
      ((keys | sort) == ["compose_variant","qualification_backend","schema_version","vendor"] and
       .schema_version == 1 and .vendor == "nvidia" and .compose_variant == "nvidia" and .qualification_backend == "cuda" or
       .schema_version == 1 and .vendor == "amd" and .architecture == "gfx1201" and .pci_device_id == "0x7550" and .compose_variant == "amd" and .qualification_backend == "rocm" and
       (.profile_sha256 | test("^[a-f0-9]{64}$")) and
       (.host_provisioning | type == "object" and (keys | sort) == ["installer_package_version","installer_sha256","installer_url","ubuntu_version_id","usecase"] and
        .ubuntu_version_id == "24.04" and (.installer_url | test("^https://repo\\.radeon\\.com/")) and
        (.installer_sha256 | test("^[a-f0-9]{64}$")) and
        (.installer_package_version | test("^[0-9][A-Za-z0-9.+:~-]*$")) and .usecase == "graphics,rocm") and
       (((keys | sort) == ["architecture","compose_variant","host_provisioning","pci_device_id","profile_sha256","qualification_backend","readiness","schema_version","vendor"] and .readiness == "provisioning") or
        (.readiness == "ready" and .devices.kfd == "/dev/kfd" and (.devices.render | test("^/dev/dri/renderD[0-9]+$")) and
         (.group_ids.kfd | type == "number" and floor == . and . >= 0) and (.group_ids.render | type == "number" and floor == . and . >= 0) and
         (.mlnode_image | test("@sha256:[a-f0-9]{64}$")) and
         (((keys | sort) == ["architecture","compose_variant","devices","group_ids","host_provisioning","installed_runtime","mlnode_image","pci_device_id","profile_sha256","qualification_backend","readiness","schema_version","vendor"] and
          (.installed_runtime | type == "object" and (keys | sort) == ["admission_route","kernel_release","os_id","packages","requires_mlnode_qualification","ubuntu_version_id"] and
          (.admission_route | IN("profile_provisioned","experimental_preinstalled")) and .requires_mlnode_qualification == true and .os_id == "ubuntu" and
          (.ubuntu_version_id | test("^[0-9]{2}\\.04$")) and (.kernel_release | test("^[A-Za-z0-9._+-]+$")) and
          (.packages | type == "object" and (keys | sort) == ["amdgpu-install","amdrocm","rocm-core"] and
           ([.amdrocm,.["amdgpu-install"],.["rocm-core"]] | all(
             type == "object" and (keys | sort) == ["status","version"] and
             ((.status == "absent" and .version == "absent") or (.status == "install ok installed" and (.version | test("^[0-9][A-Za-z0-9.+:~-]*$"))))
           )))) or
          ($allow_legacy and (keys | sort) == ["architecture","compose_variant","devices","group_ids","host_provisioning","mlnode_image","pci_device_id","profile_sha256","qualification_backend","readiness","schema_version","vendor"])))))))) and
    .spec.deployment.data_layout == "gdc-data-layout/v2" and .spec.identity.stable_identity_layout == "gdc-identity-layout/v2" and
    (.spec.network.bootstrap_url | test("^https://")) and
    (.spec.seeds.usable | type == "array" and length >= 1) and (.spec.seeds.unavailable | type == "array") and
    (.spec.deployment.host_envelope | type == "object" and
      (keys | sort) == ["caddy_image","cadvisor_image","dashboard_port","edge_api_compose_profile","edge_api_image","edge_api_service_name","explorer_image","grafana_image","host_stack","join_effective_epochs","join_effective_timeout_seconds","mapping_source","mlnode_context_length","mlnode_dtype","mlnode_gpu_memory_utilization","mlnode_image","mlnode_max_num_seqs","mlnode_proxy_image","mlnode_tensor_parallel_size","model_id","model_revision","node_exporter_image","postgres_image","proxy_image","tmkms_image","versiond_image"] and
      ([.tmkms_image,.postgres_image,.edge_api_image,.versiond_image,.proxy_image,.explorer_image,.mlnode_image,.mlnode_proxy_image,.caddy_image,.grafana_image,.node_exporter_image,.cadvisor_image][] | test("^[A-Za-z0-9./:_-]+@sha256:[a-f0-9]{64}$")) and
      (.host_stack | type == "object" and (keys | sort) == ["api_image","commit","compose_sha256","repository"] and .repository == "gonka-ai/gonka" and (.commit | test("^[a-f0-9]{40}$")) and (.compose_sha256 | test("^[a-f0-9]{64}$")) and (.api_image | test("^[A-Za-z0-9./:_-]+@sha256:[a-f0-9]{64}$"))) and
      (.dashboard_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
      (.join_effective_epochs | type == "number" and floor == . and . > 0) and
      (.join_effective_timeout_seconds | type == "number" and floor == . and . > 0) and
      (.edge_api_compose_profile | type == "string" and length > 0) and
      (.edge_api_service_name | type == "string" and length > 0) and
      (.model_id | type == "string" and length > 0) and
      (.model_revision | test("^[a-f0-9]{40}$")) and
      (.mlnode_context_length | type == "number" and floor == . and . > 0) and
      (.mlnode_max_num_seqs | type == "number" and floor == . and . > 0) and
      (.mlnode_dtype | type == "string" and length > 0) and
      (.mlnode_tensor_parallel_size | type == "number" and floor == . and . > 0) and
      (.mlnode_gpu_memory_utilization | type == "string" and test("^0\\.[0-9]+$|^1(\\.0+)?$")) and
      (.mapping_source | type == "object" and (keys | sort) == ["definition_sha256","id","kind"] and
        (.kind | IN("qualified_catalog","release_lock_component","official_artifact","official_oci_runtime","dynamic_build")) and
        (.id | type == "string" and length > 0) and
        (.definition_sha256 | test("^[a-f0-9]{64}$")))
    ) and
    (.spec.state_acquisition.mode | IN("pending","native_p2p_state_sync")) and
    (.spec.state_acquisition.providers | type == "array") and
    (.spec.state_acquisition | (has("pex") | not) or (.pex | type == "boolean")) and
    (.spec.state_acquisition | (has("trust_authority") | not) or
      (.trust_authority | type == "object" and (keys | sort) == ["kind","rpc_url"] and .kind == "operator_source" and
        (.rpc_url | test("^https?://[A-Za-z0-9.-]+(:[0-9]+)?/chain-rpc$")))) and
    ((.spec.state_acquisition.mode == "pending" and (.spec.state_acquisition.providers | length == 0) and .spec.state_acquisition.minimum_providers == 0) or
     (.spec.state_acquisition.mode == "native_p2p_state_sync" and (.spec.state_acquisition.providers | length >= 2) and .spec.state_acquisition.minimum_providers >= 2)) and
    .spec.activation_policy.application_required_for_complete == true and .spec.activation_policy.signer_allowed_in_profile == false and
    (.spec.components.core | (.observed.commit | test("^[a-f0-9]{40}$")) and (.expected_runtime.commit | test("^[a-f0-9]{40}$")) and (.installation.image.digest | test("^sha256:[a-f0-9]{64}$")) and (.installation.binary.sha256 | test("^[a-f0-9]{64}$")))
    and (.spec.components.dapi | (.observed.commit | test("^[a-f0-9]{40}$")) and (.expected_runtime.commit | test("^[a-f0-9]{40}$")) and (.installation.image.digest | test("^sha256:[a-f0-9]{64}$")) and (.installation.binary.url | test("^https://github.com/")) and (.installation.binary.sha256 | test("^[a-f0-9]{64}$")))
  ' "$file" >/dev/null || die 'document has an invalid closed v1 shape'
  expected_id="$(jq -cS .spec "$file" | sha256sum | awk '{print $1}')"
  actual_id="$(jq -r .profile_id "$file")"
  [[ "$expected_id" == "$actual_id" ]] || die 'profile_id does not bind the canonical executable spec'
  operation="$(jq -r .operation "$file")"; identity_mode="$(jq -r .spec.identity.mode "$file")"
  [[ "$operation" == new && "$identity_mode" == generate || "$operation" == restore && "$identity_mode" == restore ]] \
    || die 'operation and identity mode disagree'
  valid_until_epoch="$(date -u -d "$(jq -r .valid_until "$file")" +%s 2>/dev/null)" \
    || die 'valid_until is not a parseable UTC timestamp'
  now_epoch="$(date -u +%s)"
  [[ "$allow_expired" == true || "$valid_until_epoch" -gt "$now_epoch" ]] \
    || die 'profile has expired; observe the network and create a new profile'
  if [[ "$operation" == restore ]]; then jq -e '.spec.identity.restore_archive_sha256 | test("^[a-f0-9]{64}$")' "$file" >/dev/null || die 'restore profile lacks archive digest'; fi
}

case "${1:-}" in
  validate)
    allow_expired=false
    if [[ "${2:-}" == --allow-expired ]]; then
      allow_expired=true
      shift
    fi
    [[ $# -eq 2 && -r "$2" ]] || { usage; exit 2; }
    validate "$2" "$allow_expired"; printf 'PASS valid Join Profile file=%s profile_id=%s\n' "$2" "$(jq -r .profile_id "$2")"
    ;;
  create)
    shift
    observation=''; spec=''; operation=''; run_id=''; output=''
    while (($#)); do case "$1" in
      --observation) observation="${2:-}"; shift 2 ;;
      --spec) spec="${2:-}"; shift 2 ;;
      --operation) operation="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --output) output="${2:-}"; shift 2 ;;
      *) usage; exit 2 ;;
    esac; done
    [[ -r "$observation" && -r "$spec" && "$operation" =~ ^(new|restore)$ && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && -n "$output" ]] || { usage; exit 2; }
    jq -e '.schema_version == 1 and .kind == "gdc-network-observation" and .result == {state:"ready",reason:"none"} and (.network_state_id | test("^[a-f0-9]{64}$"))' "$observation" >/dev/null || die 'observation is not ready'
    jq -e --arg op "$operation" --slurpfile observation "$observation" '
      type == "object" and
      .network.chain_id and .network.genesis_sha256 and .network.bootstrap_sha256 and .network.bootstrap_url and
      .components.core.observed == $observation[0].runtime.core and .components.dapi.observed == $observation[0].runtime.dapi and
      (if $observation[0].policy.mode == "operator_source" then
        .state_acquisition.trust_authority == {kind:"operator_source",rpc_url:$observation[0].policy.source_rpc}
       else (.state_acquisition | has("trust_authority") | not) end) and
      (.seeds.usable | type == "array" and length >= 1) and (.seeds.unavailable | type == "array") and
      .identity.mode == (if $op == "new" then "generate" else "restore" end)
    ' "$spec" >/dev/null || die 'spec is not bound exactly to the observation and operation'
    profile_id="$(jq -cS . "$spec" | sha256sum | awk '{print $1}')"
    observation_sha="$(sha256_file "$observation")"; state_id="$(jq -r .network_state_id "$observation")"
    created="$(date -u +%FT%TZ)"; valid_until="$(date -u -d '+600 seconds' +%FT%TZ)"
    mkdir -p "$(dirname "$output")"; temp="$(mktemp "$(dirname "$output")/.join-profile.XXXXXX")"
    jq -cn --arg run_id "$run_id" --arg created "$created" --arg valid "$valid_until" --arg op "$operation" --arg sha "$observation_sha" --arg state "$state_id" --arg profile "$profile_id" --argjson spec "$(jq -cS . "$spec")" \
      '{schema_version:1,kind:"gdc-host-join-profile",run_id:$run_id,created_at:$created,valid_until:$valid,operation:$op,observation:{sha256:$sha,network_state_id:$state},profile_id:$profile,spec:$spec,decision:"ready_full"}' | jq -cS . >"$temp"
    chmod 0600 "$temp"; validate "$temp"; mv -f "$temp" "$output"
    printf 'PASS created Join Profile profile_id=%s observation_sha256=%s file=%s\n' "$profile_id" "$observation_sha" "$output"
    ;;
  *) usage; exit 2 ;;
esac
