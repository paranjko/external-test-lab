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
# A repeated COMPLETE must keep the original succeeded receipt: node start
# relies on that result to authorize a later signer restart.
grep -Fq 'Keep the successful completion receipt intact' "$ROOT/gdc.sh"
grep -Fq 'verify-complete-join-state.sh" "$join_alias" "$previous_join_run/join-profile.v1.json"' "$ROOT/gdc.sh"

# A fresh lifecycle process recovers the profile bound to its active JOIN run
# before it loads any launcher-default release profile.
lifecycle_home="$tmp/lifecycle-home"
mkdir -p "$lifecycle_home/state" "$lifecycle_home/runs/previous/join-node-a"
printf 'previous\n' >"$lifecycle_home/state/active-run-id"
install -m 0600 "$profile" "$lifecycle_home/runs/previous/join-node-a/join-profile.v1.json"
lifecycle_sha="$(sha256sum "$lifecycle_home/runs/previous/join-node-a/join-profile.v1.json" | awk '{print $1}')"
printf 'schema_version=2\nrun_id=previous\noperator_data_home=%s\nprofile_kind=generated_join\njoin_profile_sha256=%s\n' "$lifecycle_home" "$lifecycle_sha" >"$lifecycle_home/runs/previous/manifest.env"
chmod 600 "$lifecycle_home/runs/previous/manifest.env"
(
  export GDC_HOME="$lifecycle_home"
  source "$ROOT/scripts/lib.sh"
  load_retained_join_profile_for_node node-a
  [[ "$GDC_JOIN_PROFILE" == "$lifecycle_home/runs/previous/join-node-a/join-profile.v1.json" ]]
)
jq '.target.public_host = "different.example.test" | .target.public_p2p_address = "tcp://different.example.test:5000"' "$spec" >"$tmp/different-spec.json"
"$ROOT/scripts/join-profile.sh" create --observation "$observation" --spec "$tmp/different-spec.json" --operation new --run-id different --output "$tmp/different.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$run" --current-profile "$tmp/different.json")"
jq -e '.classification == "profile_changed"' <<<"$result" >/dev/null
jq 'del(.previous_receipt_sha256,.recorded_at,.sequence) | .state = "PERMISSIONS_RECONCILED" | .signer_ever_started = false' "$run/receipts/0001-complete.json" >"$tmp/partial.json"
rm -f "$run/receipts/0001-complete.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$run/receipts" --input "$tmp/partial.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$run" --current-profile "$profile")"
jq -e '.classification == "manual_recovery_required"' <<<"$result" >/dev/null

# A terminal preflight refusal with no lifecycle receipts is retryable: no
# remote identity, deployment or signer has been changed.
retry="$tmp/preflight-retry"
mkdir -p "$retry"
install -m 0600 "$profile" "$retry/join-profile.v1.json"
jq -cn --arg sha "$(sha256sum "$retry/join-profile.v1.json" | awk '{print $1}')" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"refused",phase:"profile",category:"lineage",reason:"join_preflight_failed",exit_code:1,mutation:"none",signer_state:"absent",resume:"new_profile",join_profile_sha256:$sha,evidence:[]}' \
  >"$tmp/retry-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$retry/join-result.v1.json" --input "$tmp/retry-result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$retry" --current-profile "$profile")"
jq -e '.classification == "preflight_retry_allowed"' <<<"$result" >/dev/null

# Driver installation deliberately stops before identity creation. Its typed
# terminal result permits an ordinary fresh JOIN after reboot, rather than a
# reset or an unsafe resume through a partial lifecycle run.
reboot_retry="$tmp/reboot-retry"
mkdir -p "$reboot_retry/receipts"
install -m 0600 "$profile" "$reboot_retry/join-profile.v1.json"
reboot_sha="$(sha256sum "$reboot_retry/join-profile.v1.json" | awk '{print $1}')"
jq -cn --arg profile "$reboot_sha" --arg observation "$observation_sha" \
  '{schema_version:2,kind:"gdc-host-join-receipt",run_id:"reboot",operation:"new",node_name:"node-a",state:"TARGET_CLASSIFIED",join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:"reboot",identity_fingerprints:{participant_address:"",consensus_pubkey:"",p2p_node_id:"",warm_address:""},signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' \
  >"$tmp/reboot-receipt.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$reboot_retry/receipts" --input "$tmp/reboot-receipt.json" >/dev/null
jq -cn --arg sha "$reboot_sha" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"failed",phase:"staging",category:"host",reason:"host_prepare_reboot_required",exit_code:194,mutation:"staging_only",signer_state:"disabled",resume:"new_profile",join_profile_sha256:$sha,evidence:[]}' \
  >"$tmp/reboot-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$reboot_retry/join-result.v1.json" --input "$tmp/reboot-result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$reboot_retry" --current-profile "$profile")"
jq -e '.classification == "preparation_retry_allowed" and .reason == "host_prepare_reboot_required"' <<<"$result" >/dev/null

# A non-reboot preparation failure is also before identity/deployment/signer
# mutation. Its typed result must permit a fresh JOIN, and the conservative
# result written by older launchers must remain recoverable for operators.
prepare_failure="$tmp/prepare-failure"
mkdir -p "$prepare_failure/receipts"
install -m 0600 "$profile" "$prepare_failure/join-profile.v1.json"
prepare_failure_sha="$(sha256sum "$prepare_failure/join-profile.v1.json" | awk '{print $1}')"
jq -cn --arg profile "$prepare_failure_sha" --arg observation "$observation_sha" \
  '{schema_version:2,kind:"gdc-host-join-receipt",run_id:"prepare-failure",operation:"new",node_name:"node-a",state:"TARGET_CLASSIFIED",join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:"prepare-failure",identity_fingerprints:{participant_address:"",consensus_pubkey:"",p2p_node_id:"",warm_address:""},signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' \
  >"$tmp/prepare-failure-receipt.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$prepare_failure/receipts" --input "$tmp/prepare-failure-receipt.json" >/dev/null
jq -cn --arg sha "$prepare_failure_sha" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"failed",phase:"staging",category:"host",reason:"host_prepare_failed_before_identity",exit_code:1,mutation:"staging_only",signer_state:"disabled",resume:"new_profile",join_profile_sha256:$sha,evidence:[]}' \
  >"$tmp/prepare-failure-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$prepare_failure/join-result.v1.json" --input "$tmp/prepare-failure-result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$prepare_failure" --current-profile "$profile")"
jq -e '.classification == "preparation_retry_allowed" and .reason == "host_prepare_failed_before_identity"' <<<"$result" >/dev/null
jq -cn --arg sha "$prepare_failure_sha" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"failed",phase:"signer",category:"internal",reason:"join_phase_failed",exit_code:1,mutation:"signer_may_be_on",signer_state:"unknown",resume:"automatic_retry_forbidden",join_profile_sha256:$sha,evidence:[]}' \
  >"$tmp/prepare-failure-legacy-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$prepare_failure/join-result.v1.json" --input "$tmp/prepare-failure-legacy-result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$prepare_failure" --current-profile "$profile")"
jq -e '.classification == "preparation_retry_allowed" and .reason == "legacy_host_prepare_failed_before_identity"' <<<"$result" >/dev/null
rm -f "$reboot_retry/join-result.v1.json"
ln -s "$tmp/reboot-result.json" "$reboot_retry/join-result.v1.json"
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$reboot_retry" --current-profile "$profile")"
jq -e '.classification == "blocked" and .reason == "retained_input_missing_or_unsafe"' <<<"$result" >/dev/null
rm -f "$reboot_retry/join-result.v1.json"
install -m 0644 "$tmp/reboot-result.json" "$reboot_retry/join-result.v1.json"
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$reboot_retry" --current-profile "$profile")"
jq -e '.classification == "blocked" and .reason == "retained_input_missing_or_unsafe"' <<<"$result" >/dev/null
rm -f "$reboot_retry/join-result.v1.json"
cat >"$reboot_retry/verdict.md" <<'EOF'
# Host JOIN: INCONCLUSIVE

The phase stopped with exit code 194 before it could write its final verdict.
Inspect the run log and evidence in this directory. No PASS is implied.
EOF
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$reboot_retry" --current-profile "$profile")"
jq -e '.classification == "preparation_retry_allowed" and .reason == "legacy_host_prepare_reboot_required"' <<<"$result" >/dev/null
# A run that refused at classification recorded a REFUSED receipt and a
# terminal result with mutation=none: the next normal invocation classifies
# the Host afresh instead of demanding manual recovery.
refused="$tmp/refused"
mkdir -p "$refused/receipts"
install -m 0600 "$profile" "$refused/join-profile.v1.json"
refused_sha="$(sha256sum "$refused/join-profile.v1.json" | awk '{print $1}')"
[[ "$refused_sha" == "$sha" ]]
jq -c '.run_id = "refused" | .generation_id = "refused" | .state = "JOIN_PROFILE_READY" | .signer_ever_started = false' "$receipt" >"$tmp/refused-ready.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$refused/receipts" --input "$tmp/refused-ready.json" >/dev/null
jq -c '.state = "REFUSED" | .outcome = "refused" | .resume_policy = "new_profile"' "$tmp/refused-ready.json" >"$tmp/refused-stop.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$refused/receipts" --input "$tmp/refused-stop.json" >/dev/null
jq -cn --arg sha "$refused_sha" '{schema_version:1,kind:"gdc-host-join-result",outcome:"refused",phase:"identity",category:"identity",reason:"partial_identity",exit_code:1,mutation:"none",signer_state:"absent",resume:"manual_recovery",join_profile_sha256:$sha,evidence:[]}' >"$tmp/refused-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$refused/join-result.v1.json" --input "$tmp/refused-result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$refused" --current-profile "$profile")"
jq -e '.classification == "refused_before_mutation" and .reason == "refused_partial_identity"' <<<"$result" >/dev/null
# The launcher fallback for a phase that died without its own result claims
# signer_may_be_on: such a run keeps requiring manual recovery.
jq -cn --arg sha "$refused_sha" '{schema_version:1,kind:"gdc-host-join-result",outcome:"failed",phase:"signer",category:"internal",reason:"join_phase_failed",exit_code:1,mutation:"signer_may_be_on",signer_state:"unknown",resume:"automatic_retry_forbidden",join_profile_sha256:$sha,evidence:[]}' >"$tmp/fallback-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$refused/join-result.v1.json" --input "$tmp/fallback-result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$refused" --current-profile "$profile")"
jq -e '.classification == "manual_recovery_required"' <<<"$result" >/dev/null
# A refusal recorded after Host changes began is not a fresh start either:
# the receipt chain must end in REFUSED.
"$ROOT/scripts/record-join-result.sh" --output "$run/join-result.v1.json" --input "$tmp/refused-result.json" >/dev/null
result="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$run" --current-profile "$profile")"
jq -e '.classification == "manual_recovery_required"' <<<"$result" >/dev/null
grep -Fq 'refused_before_mutation)' "$ROOT/gdc.sh"
grep -Fq 'stopped before any Host change; classifying the Host afresh' "$ROOT/gdc.sh"
printf 'PASS completed JOIN re-entry is no-op-only, preflight and classification refusals restart, partial runs require receipt-bound resume\n'
