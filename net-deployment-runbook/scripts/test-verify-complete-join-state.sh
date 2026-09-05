#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
deploy="$tmp/deploy"
mkdir -p "$tmp/bin" "$deploy"

core_commit=4d687ed6782bcea3931d2d9135bf322f84e190ab
dapi_commit=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0
dapi_image="example/dapi:0.2.15-post3@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
core_image="example/core:0.2.15@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

jq -n \
  --arg core_commit "$core_commit" --arg dapi_commit "$dapi_commit" \
  --arg dapi_image "$dapi_image" --arg core_image "$core_image" \
  --arg now "$(date -u +%FT%TZ)" '
  {
    network:{chain_id:"gonka-fixture",genesis_sha256:("d" * 64),bootstrap_sha256:("e" * 64),bootstrap_url:"https://example.test/bootstrap.json"},
    target:{node_name:"node-a",public_host:"node-a.example.test",public_p2p_address:"tcp://node-a.example.test:5000",platform:"linux-amd64"},
    deployment:{gdc_source_commit:("f" * 40),data_layout:"gdc-data-layout/v2",host_envelope:{
      tmkms_image:("example/tmkms@sha256:" + ("a" * 64)),postgres_image:("example/postgres@sha256:" + ("b" * 64)),
      edge_api_image:("example/edge@sha256:" + ("c" * 64)),versiond_image:("example/versiond@sha256:" + ("d" * 64)),
      proxy_image:("example/proxy@sha256:" + ("e" * 64)),explorer_image:("example/explorer@sha256:" + ("f" * 64)),
      mlnode_image:("example/mlnode@sha256:" + ("1" * 64)),mlnode_proxy_image:("example/mlnode-proxy@sha256:" + ("2" * 64)),
      caddy_image:("example/caddy@sha256:" + ("5" * 64)),grafana_image:("example/grafana@sha256:" + ("6" * 64)),
      node_exporter_image:("example/node-exporter@sha256:" + ("7" * 64)),cadvisor_image:("example/cadvisor@sha256:" + ("8" * 64)),
      host_stack:{repository:"gonka-ai/gonka",commit:("1" * 40),compose_sha256:("9" * 64),api_image:("example/api@sha256:" + ("9" * 64))},
      dashboard_port:5173,edge_api_compose_profile:"edge",edge_api_service_name:"edge-api",model_id:"fixture",model_revision:("3" * 40),
      mlnode_context_length:32768,mlnode_max_num_seqs:8,mlnode_gpu_memory_utilization:"0.9",mlnode_dtype:"auto",mlnode_tensor_parallel_size:1,
      join_effective_epochs:4,join_effective_timeout_seconds:7200,
      mapping_source:{kind:"qualified_catalog",id:"fixture",definition_sha256:("4" * 64)}}},
    components:{
      core:{observed:{version:"0.2.15",commit:$core_commit},expected_runtime:{version:"0.2.15",commit:$core_commit},installation:{mode:"image_plus_cosmovisor",image:{repository:"example/core:0.2.15",digest:("sha256:" + ("a" * 64))},binary:{url:"https://example.test/core.zip",sha256:("b" * 64)}},mapping_source:{kind:"qualified_catalog",id:"fixture",definition_sha256:("c" * 64)}},
      dapi:{observed:{version:"0.2.15-post3",commit:$dapi_commit},expected_runtime:{version:"0.2.15-post3",commit:$dapi_commit},installation:{mode:"qualified_image",image:{repository:"example/dapi:0.2.15-post3",digest:("sha256:" + ("d" * 64))},binary:{url:"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15-post3/decentralized-api-amd64.zip",sha256:("e" * 64)}},mapping_source:{kind:"qualified_catalog",id:"fixture",definition_sha256:("f" * 64)}}},
    seeds:{usable:[{seed_index:0,status:"usable",reason:"none"}],unavailable:[]},state_acquisition:{mode:"pending",providers:[],minimum_providers:0},
    identity:{mode:"generate",stable_identity_layout:"gdc-identity-layout/v2"},activation_policy:{application_required_for_complete:true,signer_allowed_in_profile:false,old_signer_fence_required:false}
  }' >"$tmp/spec.json"
profile_id="$(jq -cS . "$tmp/spec.json" | sha256sum | awk '{print $1}')"
jq -n --arg profile "$profile_id" --arg now "$(date -u +%FT%TZ)" --slurpfile spec "$tmp/spec.json" \
  '{schema_version:1,kind:"gdc-host-join-profile",run_id:"fixture-run",created_at:$now,valid_until:(now + 600 | todateiso8601),operation:"new",observation:{sha256:("a" * 64),network_state_id:("b" * 64)},profile_id:$profile,spec:$spec[0],decision:"ready_full"}' \
  >"$tmp/profile.json"
chmod 600 "$tmp/profile.json"
profile_sha256="$(sha256sum "$tmp/profile.json" | awk '{print $1}')"

mkdir -p "$deploy"
printf 'GDC_PROFILE_KIND=generated_join\nDAPI_IMAGE=%s\nINFERENCED_IMAGE=%s\n' "$dapi_image" "$core_image" >"$deploy/.env"
printf 'services: {}\n' >"$deploy/compose.yaml"
printf '%s\n' "$profile_sha256" >"$deploy/.gdc-join-profile"
cp "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy/verify-canonical-join-state.sh"
chmod 0755 "$deploy/verify-canonical-join-state.sh"
jq -n '{identity_fingerprints:{p2p_node_id:"0123456789abcdef0123456789abcdef01234567"}}' >"$tmp/receipt.json"
chmod 600 "$tmp/receipt.json"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -T ]] && shift
node="$1"; shift
command="$1"
command="${command//\/srv\/dai\/deploy\/$node/$GDC_TEST_DEPLOY}"
bash -c "$command"
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
case "$args" in
  *'ps -q node') printf '%s\n' 0123456789ab ;;
  *'ps -q api') printf '%s\n' abcdef012345 ;;
  *'ps -aq tmkms') printf '%s\n' fedcba987654 ;;
  *'inspect --format {{.State.Running}} fedcba987654') printf '%s\n' true ;;
  *'inspect --format {{.Image}} 0123456789ab') printf '%s\n' sha256:coreimage ;;
  *'inspect --format {{.Image}} abcdef012345') printf '%s\n' sha256:dapiimage ;;
  *'image inspect --format {{.Id}} example/core:0.2.15@sha256:'*) printf '%s\n' sha256:coreimage ;;
  *'image inspect --format {{.Id}} example/dapi:0.2.15-post3@sha256:'*) printf '%s\n' sha256:dapiimage ;;
  *'exec 0123456789ab readlink -f /proc/1/exe') printf '%s\n' /root/.inference/cosmovisor/current/bin/inferenced ;;
  *'exec 0123456789ab /root/.inference/cosmovisor/current/bin/inferenced version --long') printf '%s\n' "version: 0.2.15" "commit: 4d687ed6782bcea3931d2d9135bf322f84e190ab" ;;
  *'exec abcdef012345 readlink -f /proc/1/exe') printf '%s\n' /root/.dapi/cosmovisor/current/bin/decentralized-api ;;
  *) echo "unexpected docker invocation: $args" >&2; exit 2 ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
version="${GDC_TEST_DAPI_VERSION:-0.2.15-post3}"
commit="${GDC_TEST_DAPI_COMMIT:-5dbb53ddf3ddc42655fc04dc39d96003169bdbb0}"
case "$url" in
  */status) printf '%s\n' '{"result":{"node_info":{"network":"gonka-fixture","id":"0123456789abcdef0123456789abcdef01234567"},"sync_info":{"catching_up":false,"latest_block_height":"5000"}}}' ;;
  */abci_info) printf '%s\n' '{"result":{"response":{"version":"0.2.15"}}}' ;;
  */v1/versions) printf '{"api_version":{"version":"%s","commit":"%s"}}\n' "$version" "$commit" ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/docker" "$tmp/bin/curl"

PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" \
  "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/profile.json" "$tmp/receipt.json" >"$tmp/pass.out"
grep -Fq 'bound to generated profile' "$tmp/pass.out"

# A retained completed JOIN remains readable after the pre-mutation profile TTL
# expires because this verifier checks immutable identity and hash bindings.
jq '.valid_until = "2000-01-01T00:00:00Z"' "$tmp/profile.json" >"$tmp/expired-profile.json"
chmod 600 "$tmp/expired-profile.json"
expired_profile_sha256="$(sha256sum "$tmp/expired-profile.json" | awk '{print $1}')"
printf '%s\n' "$expired_profile_sha256" >"$deploy/.gdc-join-profile"
PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" \
  "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/expired-profile.json" "$tmp/receipt.json" >"$tmp/expired.out"
grep -Fq 'bound to generated profile' "$tmp/expired.out"
printf '%s\n' "$profile_sha256" >"$deploy/.gdc-join-profile"

printf '%s\n' wrong >"$deploy/.gdc-join-profile"
if PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" \
  "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/profile.json" "$tmp/receipt.json" >"$tmp/marker.out" 2>"$tmp/marker.err"; then
  echo 'stale generated profile marker unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'completed_join_profile_mismatch:' "$tmp/marker.err"
printf '%s\n' "$profile_sha256" >"$deploy/.gdc-join-profile"

sed -i 's#^DAPI_IMAGE=.*#DAPI_IMAGE=example/dapi:wrong@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee#' "$deploy/.env"
if PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" \
  "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/profile.json" "$tmp/receipt.json" >"$tmp/image.out" 2>"$tmp/image.err"; then
  echo 'stale DAPI image unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'completed_dapi_image_mismatch:' "$tmp/image.err"
sed -i "s#^DAPI_IMAGE=.*#DAPI_IMAGE=$dapi_image#" "$deploy/.env"

if PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" GDC_TEST_DAPI_VERSION=0.2.15-post5 \
  "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/profile.json" "$tmp/receipt.json" >"$tmp/version.out" 2>"$tmp/version.err"; then
  echo 'mismatched DAPI runtime version unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'canonical_dapi_version_mismatch:' "$tmp/version.err"

if PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" GDC_TEST_DAPI_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/profile.json" "$tmp/receipt.json" >"$tmp/commit.out" 2>"$tmp/commit.err"; then
  echo 'mismatched DAPI runtime commit unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'canonical_dapi_commit_mismatch:' "$tmp/commit.err"

printf 'PASS repeated JOIN no-op binds generated profile, exact DAPI image and canonical runtime readback\n'
