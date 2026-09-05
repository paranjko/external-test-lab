#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/scripts/resolve-join-components.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
headers=''
while (($#)); do
  case "$1" in
    -D) headers="$2"; shift 2 ;;
    -o|-H|--connect-timeout|--max-time|--retry|--retry-delay) shift 2 ;;
    --retry-all-errors) shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *'raw.githubusercontent.com/gonka-ai/gonka/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/deploy/join/docker-compose.yml')
    node_tag=0.2.15
    [[ "${MODE:-good}" != host_stack_core_conflict ]] || node_tag=9.9.9
    printf 'services:\n  node:\n    image: ghcr.io/product-science/inferenced:%s\n  api:\n    image: ghcr.io/product-science/api:0.2.15-post3\n' "$node_tag"
    ;;
  *'/releases/tags/release%2Fv0.2.15')
    printf '%s\n' '{"tag_name":"release/v0.2.15","assets":[{"name":"inferenced-linux-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15/inferenced-linux-amd64.zip","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}'
    ;;
  *'/repos/gonka-ai/gonka/releases/tags/release%2Fv0.2.15-post5')
    exit 22
    ;;
  *'/repos/product-science/race-releases/releases/tags/release%2Fv0.2.15-post5')
    printf '%s\n' '{"tag_name":"release/v0.2.15-post5","assets":[{"name":"decentralized-api-amd64.zip","browser_download_url":"https://github.com/product-science/race-releases/releases/download/release/v0.2.15-post5/decentralized-api-amd64.zip","digest":"sha256:4444444444444444444444444444444444444444444444444444444444444444"}]}'
    ;;
  *'/releases/tags/release%2Fv0.2.16')
    [[ "${MODE:-good}" != missing_dapi_release ]] || exit 22
    printf '%s\n' '{"tag_name":"release/v0.2.16","assets":[{"name":"decentralized-api-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.16/decentralized-api-amd64.zip","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}'
    ;;
  *'/git/matching-refs/tags/release/v0.2.15')
    printf '%s\n' '[{"ref":"refs/tags/release/v0.2.15","object":{"type":"commit","sha":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}]'
    ;;
  *'/git/matching-refs/tags/release/v0.2.16')
    commit=18506d42c510e0cafe6acd748bcd8d83036cba40
    [[ "${MODE:-good}" != dapi_tag_conflict ]] || commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf '[{"ref":"refs/tags/release/v0.2.16","object":{"type":"commit","sha":"%s"}}]\n' "$commit"
    ;;
  *'/git/matching-refs/tags/release/v0.2.15-post5')
    commit=6009b539a36b83169835ebbf1dcbbbe1b7eb1ec7
    [[ "${MODE:-good}" != dapi_tag_conflict ]] || commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf '[{"ref":"refs/tags/release/v0.2.15-post5","object":{"type":"commit","sha":"%s"}}]\n' "$commit"
    ;;
  *'ghcr.io/token?'*) printf '%s\n' '{"token":"fixture-token"}' ;;
  *'ghcr.io/v2/'*'/manifests/'*)
    [[ -n "$headers" ]] || exit 2
    [[ "${MODE:-good}" != missing_dapi_image || "$url" != *'product-science/api/manifests/'* ]] || exit 22
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
  if [[ "${MODE:-good}" == host_stack_digest_conflict ]]; then
    printf '%s  %s\n' "$(printf '0%.0s' {1..64})" "$1"
  else
    printf '%s  %s\n' d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94 "$1"
  fi
else
  /usr/bin/sha256sum "$@"
fi
EOF
chmod +x "$tmp/bin/sha256sum"

jq -n '{schema_version:1,kind:"gdc-network-observation",runtime:{core:{version:"0.2.15",commit:"4d687ed6782bcea3931d2d9135bf322f84e190ab"},dapi:{version:"0.2.16",commit:"18506d42c510e0cafe6acd748bcd8d83036cba40"}},result:{state:"ready",reason:"none"}}' >"$tmp/observation.json"
PATH="$tmp/bin:$PATH" "$TOOL" --observation "$tmp/observation.json" --output "$tmp/components.json"
jq -e '
  .core.mapping_source.kind == "official_artifact" and
  .core.mapping_source.id == "github-release/gonka-ai/gonka/release/v0.2.15/inferenced-linux-amd64.zip" and
  .dapi.mapping_source.kind == "official_artifact" and
  .dapi.mapping_source.id == "github-release/gonka-ai/gonka/release/v0.2.16/decentralized-api-amd64.zip" and
  .dapi.installation.binary.sha256 == "2222222222222222222222222222222222222222222222222222222222222222" and
  .dapi.installation.image.repository == "ghcr.io/product-science/api:0.2.15-post3" and
  .dapi.observed.version == "0.2.16" and
  .host_envelope.mapping_source.kind == "official_artifact" and
  .host_envelope.host_stack.repository == "gonka-ai/gonka" and
  .host_envelope.host_stack.commit == "ce33c851282b8f4c0f63d78d46ddd4d8bb248207"
' "$tmp/components.json" >/dev/null
if grep -q 'profiles/releases' "$TOOL"; then
  echo 'JOIN resolver still reads the local release-profile catalogue' >&2
  exit 1
fi

jq -n '{schema_version:1,kind:"gdc-network-observation",runtime:{core:{version:"0.2.15",commit:"4d687ed6782bcea3931d2d9135bf322f84e190ab"},dapi:{version:"0.2.15-post5",commit:"6009b539a36b83169835ebbf1dcbbbe1b7eb1ec7"}},result:{state:"ready",reason:"none"}}' >"$tmp/post5-observation.json"
PATH="$tmp/bin:$PATH" "$TOOL" --observation "$tmp/post5-observation.json" --output "$tmp/post5-components.json"
jq -e '
  .dapi.mapping_source.kind == "official_artifact" and
  .dapi.mapping_source.id == "github-release/product-science/race-releases/release/v0.2.15-post5/decentralized-api-amd64.zip" and
  .dapi.installation.binary.sha256 == "4444444444444444444444444444444444444444444444444444444444444444" and
  .dapi.installation.image.repository == "ghcr.io/product-science/api:0.2.15-post3" and
  .host_envelope.host_stack.api_image == "ghcr.io/product-science/api:0.2.15-post3@sha256:3333333333333333333333333333333333333333333333333333333333333333" and
  .dapi.observed.version == "0.2.15-post5"
' "$tmp/post5-components.json" >/dev/null

if MODE=missing_dapi_release PATH="$tmp/bin:$PATH" "$TOOL" --observation "$tmp/observation.json" --output "$tmp/no-dapi-release.json" >"$tmp/no-dapi-release.out" 2>"$tmp/no-dapi-release.err"; then
  echo 'missing observed DAPI release unexpectedly resolved through a base image' >&2
  exit 1
fi
grep -Fq 'runtime_artifact_unavailable: official release metadata is unavailable for dapi release/v0.2.16' "$tmp/no-dapi-release.err"

if MODE=host_stack_digest_conflict PATH="$tmp/bin:$PATH" "$TOOL" --observation "$tmp/post5-observation.json" --output "$tmp/host-digest.json" >"$tmp/host-digest.out" 2>"$tmp/host-digest.err"; then
  echo 'tampered Host-stack digest unexpectedly resolved' >&2
  exit 1
fi
grep -Fq 'runtime_artifact_unavailable: official Host-stack Compose does not match the pinned template digest' "$tmp/host-digest.err"

if MODE=host_stack_core_conflict PATH="$tmp/bin:$PATH" "$TOOL" --observation "$tmp/post5-observation.json" --output "$tmp/host-core.json" >"$tmp/host-core.out" 2>"$tmp/host-core.err"; then
  echo 'incompatible Host-stack Core tag unexpectedly resolved' >&2
  exit 1
fi
grep -Fq 'runtime_artifact_unavailable: official Host-stack Core tag 9.9.9 disagrees with observed Core 0.2.15' "$tmp/host-core.err"
printf 'PASS official artifact resolver preserves observed runtime without a local release lock\n'
