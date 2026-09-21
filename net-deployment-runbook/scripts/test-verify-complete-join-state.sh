#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
deploy="$tmp/deploy"
mkdir -p "$tmp/bin" "$deploy"
# PORTABLE-RUNTIME.md tells the operator to export these; the fixture decides
# per case whether a portable runtime is declared.
unset GDC_PORTABLE_CORE_IMAGE GDC_PORTABLE_DAPI_IMAGE

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
    target:{node_name:"node-a",public_host:"node-a.example.test",public_p2p_address:"tcp://node-a.example.test:5000",platform:"linux-amd64",accelerator:{schema_version:1,vendor:"nvidia",compose_variant:"nvidia",qualification_backend:"cuda"}},
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
printf 'GDC_PROFILE_KIND=generated_join\nDAPI_IMAGE=%s\nDAPI_UPGRADE_SHA256=%s\nINFERENCED_IMAGE=%s\n' "$dapi_image" "$(printf 'e%.0s' {1..64})" "$core_image" >"$deploy/.env"
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
  *'image inspect --format {{.Id}} local/portable-dapi@sha256:'*) printf '%s\n' sha256:dapiimage ;;
  *'exec 0123456789ab readlink -f /proc/1/exe') printf '%s\n' /root/.inference/cosmovisor/current/bin/inferenced ;;
  *'exec 0123456789ab /root/.inference/cosmovisor/current/bin/inferenced version') printf '%s\n' '0.2.15' ;;
  *'exec 0123456789ab /root/.inference/cosmovisor/current/bin/inferenced version --long') printf '%s\n' "version: 0.2.15" "commit: 4d687ed6782bcea3931d2d9135bf322f84e190ab" ;;
  *'exec abcdef012345 readlink -f /proc/1/exe') printf '%s\n' /root/.dapi/cosmovisor/current/bin/decentralized-api ;;
  *'exec abcdef012345 cat /root/.dapi/gdc-join-dapi-runtime.env')
    [[ "${GDC_TEST_DAPI_RECEIPT:-present}" == present ]] || { echo 'cat: no such file' >&2; exit 1; }
    printf '%s\n' "DAPI_VERSION=${GDC_TEST_DAPI_VERSION:-0.2.15-post3}" "DAPI_COMMIT=${GDC_TEST_DAPI_COMMIT:-5dbb53ddf3ddc42655fc04dc39d96003169bdbb0}" 'DAPI_ARCHIVE_SHA256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' 'DAPI_BINARY_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' ;;
  *'exec abcdef012345 sha256sum /root/.dapi/cosmovisor/current/bin/decentralized-api') printf '%s\n' 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  /root/.dapi/cosmovisor/current/bin/decentralized-api' ;;
  *) echo "unexpected docker invocation: $args" >&2; exit 2 ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  */status) printf '%s\n' '{"result":{"node_info":{"network":"gonka-fixture","id":"0123456789abcdef0123456789abcdef01234567"},"sync_info":{"catching_up":false,"latest_block_height":"5000"}}}' ;;
  */abci_info) printf '%s\n' '{"result":{"response":{"version":"0.2.15"}}}' ;;
  */v1/versions) printf '{"api_version":{"version":"%s","commit":"%s"},"node_version":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}\n' "${GDC_TEST_API_BUILD_VERSION:-}" "${GDC_TEST_API_BUILD_COMMIT:-}" ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/docker" "$tmp/bin/curl"
[[ "$("$tmp/bin/docker" exec 0123456789ab /root/.inference/cosmovisor/current/bin/inferenced version)" == 0.2.15 ]]

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
grep -Fq 'canonical_dapi_receipt_mismatch:' "$tmp/version.err"

if PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" GDC_TEST_DAPI_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/profile.json" "$tmp/receipt.json" >"$tmp/commit.out" 2>"$tmp/commit.err"; then
  echo 'mismatched DAPI runtime commit unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'canonical_dapi_receipt_mismatch:' "$tmp/commit.err"

# A completed portable Host: the rendered deployment names the operator-built
# DAPI and no archive. The readback accepts it only under the same declaration
# that rendered it, and still takes version and commit from the running DAPI.
portable_image="local/portable-dapi@sha256:$(printf '9%.0s' {1..64})"
printf 'GDC_PROFILE_KIND=generated_join\nDAPI_IMAGE=%s\nDAPI_UPGRADE_URL=\nDAPI_UPGRADE_SHA256=\nINFERENCED_IMAGE=%s\n' "$portable_image" "$core_image" >"$deploy/.env"
portable_readback() {
  PATH="$tmp/bin:$PATH" GDC_TEST_DEPLOY="$deploy" GDC_TEST_DAPI_RECEIPT=absent \
    GDC_TEST_API_BUILD_VERSION=0.2.15-post3 GDC_TEST_API_BUILD_COMMIT="$dapi_commit" \
    "$ROOT/scripts/verify-complete-join-state.sh" node-a "$tmp/profile.json" "$tmp/receipt.json"
}
GDC_PORTABLE_DAPI_IMAGE="$portable_image" portable_readback >"$tmp/portable.out"
grep -Fq "bound to generated profile=$profile_sha256 dapi_image=$portable_image" "$tmp/portable.out"
grep -Fq 'dapi_source=image' "$tmp/portable.out"
if portable_readback >"$tmp/undeclared.out" 2>"$tmp/undeclared.err"; then
  echo 'portable deployment unexpectedly accepted without its declaration' >&2; exit 1
fi
grep -Fq 'completed_dapi_image_mismatch:' "$tmp/undeclared.err"
# The declaration decides the mode in both directions: a portable declaration
# does not cover a deployment that names an archive, and without a declaration
# an emptied archive digest cannot select the image path of the verifier.
sed -i "s#^DAPI_UPGRADE_SHA256=.*#DAPI_UPGRADE_SHA256=$(printf 'e%.0s' {1..64})#" "$deploy/.env"
if GDC_PORTABLE_DAPI_IMAGE="$portable_image" portable_readback >"$tmp/declared-archive.out" 2>"$tmp/declared-archive.err"; then
  echo 'portable declaration unexpectedly covered a deployment that names an archive' >&2; exit 1
fi
grep -Fq 'completed_dapi_archive_mismatch:' "$tmp/declared-archive.err"
printf 'GDC_PROFILE_KIND=generated_join\nDAPI_IMAGE=%s\nDAPI_UPGRADE_URL=\nDAPI_UPGRADE_SHA256=\nINFERENCED_IMAGE=%s\n' "$dapi_image" "$core_image" >"$deploy/.env"
if portable_readback >"$tmp/emptied.out" 2>"$tmp/emptied.err"; then
  echo 'undeclared deployment with an emptied archive digest unexpectedly verified' >&2; exit 1
fi
grep -Fq 'completed_dapi_archive_mismatch:' "$tmp/emptied.err"
printf 'GDC_PROFILE_KIND=generated_join\nDAPI_IMAGE=%s\nDAPI_UPGRADE_URL=\nDAPI_UPGRADE_SHA256=\nINFERENCED_IMAGE=%s\n' "$portable_image" "$core_image" >"$deploy/.env"
if GDC_PORTABLE_DAPI_IMAGE='local/portable-dapi:latest' portable_readback >"$tmp/tagged.out" 2>"$tmp/tagged.err"; then
  echo 'a tag-only portable declaration unexpectedly bound the readback' >&2; exit 1
fi
grep -Fq 'completed JOIN readback has invalid retained identity or profile' "$tmp/tagged.err"

printf 'PASS repeated JOIN no-op binds generated profile, exact or declared portable DAPI image and canonical runtime readback\n'
