#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
profile="$tmp/profile.json"
spec="$tmp/spec.json"
observation="$tmp/observation.json"
run="$tmp/previous"

cat >"$observation" <<'EOF'
{"schema_version":1,"kind":"gdc-network-observation","network_state_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","runtime":{"core":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"dapi":{"version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}},"result":{"state":"ready","reason":"none"},"runtime_api_origins":["https://node0.example.test"]}
EOF
cat >"$spec" <<'EOF'
{"network":{"chain_id":"gonka-fixture","genesis_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","bootstrap_sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","bootstrap_url":"https://example.test/bootstrap.json"},"seeds":{"usable":[{"status":"usable"}],"unavailable":[]},"target":{"node_name":"node-a","public_host":"node-a.example.test","public_p2p_address":"tcp://node-a.example.test:5000","platform":"linux-amd64"},"deployment":{"gdc_source_commit":"ffffffffffffffffffffffffffffffffffffffff","data_layout":"gdc-data-layout/v2","host_envelope":{"tmkms_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","postgres_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","edge_api_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","versiond_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proxy_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","explorer_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mlnode_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mlnode_proxy_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","caddy_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","grafana_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","node_exporter_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","cadvisor_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","dashboard_port":3000,"edge_api_compose_profile":"disabled","edge_api_service_name":"edge-api","model_id":"fixture","model_revision":"0123456789abcdef0123456789abcdef01234567","mlnode_context_length":1,"mlnode_max_num_seqs":1,"mlnode_dtype":"float16","mlnode_tensor_parallel_size":1,"mlnode_gpu_memory_utilization":"1.0","join_effective_epochs":1,"join_effective_timeout_seconds":1,"host_stack":{"repository":"gonka-ai/gonka","commit":"0123456789abcdef0123456789abcdef01234567","compose_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","api_image":"x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"mapping_source":{"kind":"official_artifact","id":"fixture","definition_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}},"components":{"core":{"observed":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"expected_runtime":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"installation":{"image":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"binary":{"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}},"dapi":{"observed":{"version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"},"expected_runtime":{"version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"},"installation":{"image":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}},"state_acquisition":{"mode":"pending","providers":[],"minimum_providers":0},"identity":{"mode":"generate","stable_identity_layout":"gdc-identity-layout/v2"},"activation_policy":{"application_required_for_complete":true,"signer_allowed_in_profile":false,"old_signer_fence_required":false}}
EOF
spec_fixed="$tmp/spec-fixed.json"
jq '.components.dapi.installation.binary = {url:"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15-post3/decentralized-api-amd64.zip",sha256:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' "$spec" >"$spec_fixed"
mv "$spec_fixed" "$spec"
"$ROOT/scripts/join-profile.sh" create --observation "$observation" --spec "$spec" --operation new --run-id current --output "$profile" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$run" --current-profile "$profile")"
jq -e '.classification == "no_prior_run"' <<<"$result" >/dev/null
mkdir -p "$run/receipts"
install -m 0600 "$profile" "$run/join-profile.v1.json"
sha="$(sha256sum "$run/join-profile.v1.json" | awk '{print $1}')"
observation_sha="$(sha256sum "$observation" | awk '{print $1}')"
receipt="$tmp/receipt.json"
jq -cn --arg profile "$sha" --arg observation "$observation_sha" '
  {schema_version:2,kind:"gdc-host-join-receipt",run_id:"previous",operation:"new",node_name:"node-a",state:"COMPLETE",join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:"previous",identity_fingerprints:{participant_address:"gonka1fixture",consensus_pubkey:"fixture",p2p_node_id:"0123456789abcdef0123456789abcdef01234567",warm_address:"gonka1fixturewarm"},signer_ever_started:true,tmkms_state:{height:1,round:0,step:0,block_id:""},evidence:[],outcome:"succeeded",resume_policy:"resume_same_run"}
' >"$receipt"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$run/receipts" --input "$receipt" >/dev/null
jq -cn --arg sha "$sha" '{schema_version:1,kind:"gdc-host-join-result",outcome:"succeeded",phase:"acceptance",category:"internal",reason:"join_complete",exit_code:0,mutation:"signer_may_be_on",signer_state:"enabled",resume:"resume_same_run",join_profile_sha256:$sha,evidence:[]}' >"$tmp/result.json"
"$ROOT/scripts/record-join-result.sh" --output "$run/join-result.v1.json" --input "$tmp/result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$run" --current-profile "$profile")"
jq -e '.classification == "completed_matched"' <<<"$result" >/dev/null
"$ROOT/scripts/verify-completed-join-signer-state.sh" --node node-a --run-dir "$run" >/dev/null
jq '.target.public_host = "different.example.test" | .target.public_p2p_address = "tcp://different.example.test:5000"' "$spec" >"$tmp/different-spec.json"
"$ROOT/scripts/join-profile.sh" create --observation "$observation" --spec "$tmp/different-spec.json" --operation new --run-id different --output "$tmp/different.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$run" --current-profile "$tmp/different.json")"
jq -e '.classification == "profile_changed"' <<<"$result" >/dev/null
jq 'del(.previous_receipt_sha256,.recorded_at,.sequence) | .state = "PERMISSIONS_RECONCILED" | .signer_ever_started = false' "$run/receipts/0001-complete.json" >"$tmp/partial.json"
rm -f "$run/receipts/0001-complete.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$run/receipts" --input "$tmp/partial.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$run" --current-profile "$profile")"
jq -e '.classification == "manual_recovery_required"' <<<"$result" >/dev/null
printf 'PASS completed JOIN re-entry is no-op-only and partial runs require receipt-bound resume\n'
