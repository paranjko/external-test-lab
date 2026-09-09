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
jq '.seeds[0].status = "unavailable" | .seeds[0].reason = "timeout" | .seeds[1].status = "usable" | .seeds[1].reason = "none"' "$tmp/observation.json" >"$tmp/observation-reordered.json"
"$RESOLVE" --observation "$tmp/observation-reordered.json" --components "$tmp/components.json" --node-name gdc-node9 --public-host node9.example.test --operation new --run-id another-run --output "$tmp/reordered.json"
[[ "$(jq -r .profile_id "$tmp/new.json")" == "$(jq -r .profile_id "$tmp/reordered.json")" ]] || {
  echo 'transient seed diagnostics changed semantic profile ID' >&2
  exit 1
}
printf 'fixture archive\n' >"$tmp/archive.tar"
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
