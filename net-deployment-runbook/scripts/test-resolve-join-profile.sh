#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVE="$ROOT/scripts/resolve-join-profile.sh"
COMPONENTS="$ROOT/scripts/resolve-join-components.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
headers=''
while (($#)); do
  case "$1" in
    -D) headers="$2"; shift 2 ;;
    -o|-H|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *'raw.githubusercontent.com/gonka-ai/gonka/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/deploy/join/docker-compose.yml')
    printf 'services:\n  node:\n    image: ghcr.io/product-science/inferenced:0.2.15\n  api:\n    image: ghcr.io/product-science/api:0.2.15-post3\n'
    ;;
  *'/releases/tags/release%2Fv0.2.15')
    printf '%s\n' '{"tag_name":"release/v0.2.15","assets":[{"name":"inferenced-linux-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15/inferenced-linux-amd64.zip","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}'
    ;;
  *'/releases/tags/release%2Fv0.2.15-post3')
    printf '%s\n' '{"tag_name":"release/v0.2.15-post3","assets":[{"name":"decentralized-api-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15-post3/decentralized-api-amd64.zip","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}'
    ;;
  *'/git/matching-refs/tags/release/v0.2.15-post3')
    printf '%s\n' '[{"ref":"refs/tags/release/v0.2.15-post3","object":{"type":"commit","sha":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}}]'
    ;;
  *'/git/matching-refs/tags/release/v0.2.15')
    printf '%s\n' '[{"ref":"refs/tags/release/v0.2.15","object":{"type":"commit","sha":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}]'
    ;;
  *'ghcr.io/token?'*) printf '%s\n' '{"token":"fixture-token"}' ;;
  *'ghcr.io/v2/'*'/manifests/'*)
    [[ -n "$headers" ]] || exit 2
    printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:3333333333333333333333333333333333333333333333333333333333333333\r\n' >"$headers"
    ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$tmp/bin/curl"

cat >"$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == *host-stack-compose.yml ]]; then
  printf '%s  %s\n' d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94 "$1"
else
  /usr/bin/sha256sum "$@"
fi
EOF
chmod +x "$tmp/bin/sha256sum"

jq -n '{schema_version:1,kind:"gdc-network-observation",network_state_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",bootstrap:{url:"https://gonka-dev.net/gonka-devnet-community/bootstrap.json",document_sha256:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",chain_id:"gonka-devnet-community",genesis_sha256:"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},seeds:[{seed_index:0,status:"usable",reason:"none"},{seed_index:1,status:"unavailable",reason:"versions_endpoint"}],runtime_api_origins:[{seed_index:0}],runtime:{core:{version:"0.2.15",commit:"4d687ed6782bcea3931d2d9135bf322f84e190ab"},dapi:{version:"0.2.15-post3",commit:"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}},result:{state:"ready",reason:"none"}}' >"$tmp/observation.json"
PATH="$tmp/bin:$PATH" "$COMPONENTS" --observation "$tmp/observation.json" --output "$tmp/components.json"
"$RESOLVE" --observation "$tmp/observation.json" --components "$tmp/components.json" --node-name gdc-node9 --public-host node9.example.test --operation new --run-id fixture-run --output "$tmp/new.json"
"$ROOT/scripts/join-profile.sh" validate "$tmp/new.json"
jq -e '.spec.network.bootstrap_url == "https://gonka-dev.net/gonka-devnet-community/bootstrap.json" and .spec.seeds == {usable:[{selection_policy:"net-info-software-majority/v1"}],unavailable:[]} and .spec.deployment.host_envelope.host_stack == {repository:"gonka-ai/gonka",commit:"ce33c851282b8f4c0f63d78d46ddd4d8bb248207",compose_sha256:"d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94",api_image:"ghcr.io/product-science/api:0.2.15-post3@sha256:3333333333333333333333333333333333333333333333333333333333333333"} and .spec.state_acquisition == {mode:"pending",providers:[],minimum_providers:0} and .spec.identity.mode == "generate"' "$tmp/new.json" >/dev/null
printf 'fixture archive\n' >"$tmp/archive.tar"
cat >"$tmp/amd-inspection.env" <<'EOF'
vendor=amd
pci_device_id=0x7550
os_id=ubuntu
os_version_id=26.04
kernel_release=7.0.0-31-generic
amdrocm_status=install ok installed
amdrocm_version=7.14.0~pre3-29052710811
rocm_core_status=absent
rocm_core_version=absent
amdgpu_install_status=install ok installed
amdgpu_install_version=31.40.1.26130000-2383377.26.04
readiness=ready
architecture=gfx1201
render_node=renderD129
kfd_group_id=44
render_group_id=109
EOF
"$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/amd-inspection.env" --output "$tmp/amd-receipt.json"
"$RESOLVE" --observation "$tmp/observation.json" --components "$tmp/components.json" --accelerator-receipt "$tmp/amd-receipt.json" --node-name gdc-node8 --public-host node8.example.test --operation new --run-id amd-fixture --output "$tmp/amd.json"
"$ROOT/scripts/join-profile.sh" validate "$tmp/amd.json"
jq -e '.spec.target.accelerator.vendor == "amd" and .spec.target.accelerator.architecture == "gfx1201" and .spec.target.accelerator.devices.render == "/dev/dri/renderD129" and .spec.target.accelerator.group_ids == {kfd:44,render:109}' "$tmp/amd.json" >/dev/null
retained_home="$tmp/retained/node8"
mkdir -p "$retained_home/state" "$retained_home/runs/retained/join-node8"
printf 'retained\n' >"$retained_home/state/active-run-id"
install -m 0600 "$tmp/amd.json" "$retained_home/runs/retained/join-node8/join-profile.v1.json"
retained_sha="$(sha256sum "$retained_home/runs/retained/join-node8/join-profile.v1.json" | awk '{print $1}')"
printf 'profile_kind=generated_join\njoin_profile_sha256=%s\n' "$retained_sha" >"$retained_home/runs/retained/manifest.env"
chmod 0600 "$retained_home/runs/retained/manifest.env"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *' -G '* ]] && printf 'hostname 192.0.2.8\n'
EOF
chmod +x "$tmp/bin/ssh"
cat >"$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.8 STREAM fixture\n'
EOF
chmod +x "$tmp/bin/getent"
cat >"$tmp/retained-role.env" <<'EOF'
GDC_NODE_ALIASES=node8
GDC_NODE_PUBLIC_HOSTS=node8=192.0.2.8
GDC_NODE_P2P_PORTS=node8=5000
GDC_NODE_ML_HOSTS=
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_JOIN_ROLE_INPUT=true
GDC_JOIN_NETWORK_HOST=node8
EOF
retained_runtime="$(PATH="$tmp/bin:$PATH" GDC_HOME="$retained_home" GDC_DATA_ROOT="$tmp/retained" GDC_ENV="$tmp/retained-role.env" bash -c '. "$1"; load_retained_join_profile_for_node node8; load_project; printf "%s|%s" "$ACCELERATOR_QUALIFICATION_BACKEND" "$MLNODE_GENERIC_IMAGE"' _ "$ROOT/scripts/lib.sh")"
[[ "$retained_runtime" == "rocm|$(jq -r '.spec.target.accelerator.mlnode_image' "$tmp/amd.json")" ]] || { echo "separate process lost retained AMD qualification binding: $retained_runtime" >&2; exit 1; }
amd_runtime="$(bash -c '. "$0"; load_join_profile "$1"; printf "%s|%s|%s|%s|%s" "$ACCELERATOR_VENDOR" "$ACCELERATOR_QUALIFICATION_BACKEND" "$MLNODE_GENERIC_IMAGE" "$AMD_RENDER_DEVICE" "$AMD_RENDER_GROUP_ID"' "$ROOT/scripts/profile.sh" "$tmp/amd.json")"
[[ "$amd_runtime" == amd\|rocm\|ghcr.io/paranjko/gdc-mlnode:*@sha256:*\|/dev/dri/renderD129\|109 ]] || {
  echo "AMD Join Profile did not render its receipt-bound runtime: $amd_runtime" >&2; exit 1;
}
cat >"$tmp/amd-provisioning.env" <<'EOF'
vendor=amd
pci_device_id=0x7550
os_id=ubuntu
os_version_id=24.04
kernel_release=6.8.0-79-generic
amdrocm_status=absent
amdrocm_version=absent
rocm_core_status=absent
rocm_core_version=absent
amdgpu_install_status=absent
amdgpu_install_version=absent
readiness=provisioning
EOF
"$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/amd-provisioning.env" --output "$tmp/amd-provisioning-receipt.json"
"$RESOLVE" --observation "$tmp/observation.json" --components "$tmp/components.json" --accelerator-receipt "$tmp/amd-provisioning-receipt.json" --node-name gdc-node8 --public-host node8.example.test --operation new --run-id amd-provisioning --output "$tmp/amd-provisioning.json"
"$ROOT/scripts/join-profile.sh" validate "$tmp/amd-provisioning.json"
amd_provisioning_runtime="$(bash -c '. "$0"; load_join_profile "$1"; printf "%s|%s|%s|%s" "$ACCELERATOR_VENDOR" "$ACCELERATOR_ARCHITECTURE" "$ACCELERATOR_READINESS" "$MLNODE_GENERIC_IMAGE"' "$ROOT/scripts/profile.sh" "$tmp/amd-provisioning.json")"
[[ "$amd_provisioning_runtime" == amd\|gfx1201\|provisioning\|ghcr.io/gonka-ai/mlnode:* ]] || {
  echo "AMD provisioning profile did not retain a non-renderable host contract: $amd_provisioning_runtime" >&2; exit 1;
}
jq '.seeds[0].status = "unavailable" | .seeds[0].reason = "timeout" | .seeds[1].status = "usable" | .seeds[1].reason = "none"' "$tmp/observation.json" >"$tmp/observation-reordered.json"
"$RESOLVE" --observation "$tmp/observation-reordered.json" --components "$tmp/components.json" --node-name gdc-node9 --public-host node9.example.test --operation new --run-id another-run --output "$tmp/reordered.json"
[[ "$(jq -r .profile_id "$tmp/new.json")" == "$(jq -r .profile_id "$tmp/reordered.json")" ]] || {
  echo 'transient seed diagnostics changed semantic profile ID' >&2
  exit 1
}
"$RESOLVE" --observation "$tmp/observation.json" --components "$tmp/components.json" --node-name gdc-node9 --public-host node9.example.test --operation restore --restore-archive "$tmp/archive.tar" --run-id fixture-run --output "$tmp/restore.json"
"$ROOT/scripts/join-profile.sh" validate "$tmp/restore.json"
jq -e '.spec.identity.mode == "restore" and (.spec.identity.restore_archive_sha256 | test("^[a-f0-9]{64}$")) and .spec.activation_policy.old_signer_fence_required == true' "$tmp/restore.json" >/dev/null
jq '.runtime.dapi.version = "9.9.9"' "$tmp/observation.json" >"$tmp/mismatch.json"
if "$RESOLVE" --observation "$tmp/mismatch.json" --components "$tmp/components.json" --node-name gdc-node9 --public-host node9.example.test --operation new --run-id fixture-run --output "$tmp/rejected.json" >"$tmp/rejected.out" 2>"$tmp/rejected.err"; then
  echo 'mismatched selected runtime unexpectedly formed a Join Profile' >&2
  exit 1
fi
grep -Fq 'join_profile_resolution_component:' "$tmp/rejected.err"
printf 'PASS Join Profile binds selected seed tuple and target before lineage preflight\n'

# A portable runtime replaces both chain images or neither.
load_join_profile_with() {
  env -u GDC_PORTABLE_CORE_IMAGE -u GDC_PORTABLE_DAPI_IMAGE "$@" bash -c '
    set -Eeuo pipefail
    . "$0"
    load_join_profile "$1"
    printf "%s %s\n" "$INFERENCED_IMAGE" "$DAPI_IMAGE"
  ' "$ROOT/scripts/profile.sh" "$tmp/new.json"
}
portable_core="local/gonka-inferenced@sha256:$(printf '%064d' 0 | tr 0 a)"
portable_dapi="local/gonka-api@sha256:$(printf '%064d' 0 | tr 0 b)"
if load_join_profile_with GDC_PORTABLE_DAPI_IMAGE="$portable_dapi" >"$tmp/half.out" 2>"$tmp/half.err"; then
  echo 'a portable DAPI image was accepted without a portable Core image' >&2
  exit 1
fi
grep -Fq 'must be declared together' "$tmp/half.err"
if load_join_profile_with GDC_PORTABLE_CORE_IMAGE="$portable_core" >"$tmp/half.out" 2>"$tmp/half.err"; then
  echo 'a portable Core image was accepted without a portable DAPI image' >&2
  exit 1
fi
grep -Fq 'must be declared together' "$tmp/half.err"
observed="$(load_join_profile_with GDC_PORTABLE_CORE_IMAGE="$portable_core" GDC_PORTABLE_DAPI_IMAGE="$portable_dapi" 2>/dev/null)"
[[ "$observed" == "$portable_core $portable_dapi" ]] || {
  echo "both portable images must replace the profile images, got: $observed" >&2
  exit 1
}
printf 'PASS portable runtime is declared for both chain images or neither\n'
