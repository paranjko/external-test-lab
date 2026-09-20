#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
deploy="$tmp/deploy"
mkdir -p "$tmp/bin" "$tmp/deploy"
printf '%s\n' \
  'INFERENCED_IMAGE=ghcr.io/product-science/inferenced:0.2.15@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'DAPI_IMAGE=ghcr.io/product-science/api:0.2.15-post3@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'DAPI_UPGRADE_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' >"$tmp/deploy/.env"
printf '%s\n' 'services: {}' >"$tmp/deploy/compose.yaml"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
case "$args" in
  *'compose '*'ps -q node') printf '%s\n' 0123456789ab ;;
  *'compose '*'ps -q api') printf '%s\n' abcdef012345 ;;
  *'compose '*'ps -aq tmkms') [[ "${GDC_TEST_TMKMS_RUNNING:-false}" == true ]] && printf '%s\n' fedcba987654 || true ;;
  *'image inspect '*inferenced:*) printf '%s\n' sha256:feedface ;;
  *'inspect --format {{.Image}} 0123456789ab') printf '%s\n' sha256:feedface ;;
  *'inspect --format {{.Image}} abcdef012345') printf '%s\n' "${GDC_TEST_API_CONTAINER_IMAGE_ID:-sha256:apiimage}" ;;
  *'image inspect '*api:0.2.15-post3*) printf '%s\n' sha256:apiimage ;;
  *'inspect --format {{.State.Running}} fedcba987654') [[ "${GDC_TEST_TMKMS_RUNNING:-false}" == true ]] && printf '%s\n' true || printf '%s\n' false ;;
  *'exec 0123456789ab readlink -f /proc/1/exe') printf '%s\n' /usr/bin/cosmovisor ;;
  *'exec 0123456789ab command '*) echo 'command: executable not found' >&2; exit 127 ;;
  *'exec 0123456789ab sh -c command -v inferenced')
    [[ $# -eq 5 && "$5" == 'command -v inferenced' ]] || exit 2
    printf '%s\n' /usr/bin/inferenced ;;
  *'exec 0123456789ab /usr/bin/inferenced version') printf '%s\n' '0.2.15' ;;
  *'exec 0123456789ab /usr/bin/inferenced version --long') printf '%s\n' 'version: 0.2.15' 'commit: 4d687ed6782bcea3931d2d9135bf322f84e190ab' ;;
  *'exec abcdef012345 readlink -f /proc/1/exe') printf '%s\n' /root/.dapi/cosmovisor/current/bin/decentralized-api ;;
  *'exec abcdef012345 cat /root/.dapi/gdc-join-dapi-runtime.env')
    [[ "${GDC_TEST_DAPI_RECEIPT:-present}" == present ]] || { echo 'cat: no such file' >&2; exit 1; }
    printf '%s\n' 'DAPI_VERSION=0.2.15-post3' 'DAPI_COMMIT=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0' 'DAPI_ARCHIVE_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' "DAPI_BINARY_SHA256=${GDC_TEST_DAPI_BINARY_SHA256:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}" ;;
  *'exec abcdef012345 sha256sum /root/.dapi/cosmovisor/current/bin/decentralized-api') printf '%s\n' "${GDC_TEST_DAPI_ACTUAL_BINARY_SHA256:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}  /root/.dapi/cosmovisor/current/bin/decentralized-api" ;;
  *) echo "unexpected docker invocation: $args" >&2; exit 2 ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
if [[ "${GDC_TEST_CATCHING_UP:-false}" == true ]]; then catching=true; else catching=false; fi
case "$url" in
  */status) printf '%s\n' "{\"result\":{\"node_info\":{\"network\":\"gonka-devnet-community\",\"id\":\"0123456789abcdef0123456789abcdef01234567\",\"version\":\"0.38.19\"},\"sync_info\":{\"catching_up\":$catching,\"latest_block_height\":\"5000\"}}}" ;;
  */abci_info) printf '%s\n' '{"result":{"response":{"version":"0.2.15"}}}' ;;
  */v1/versions) printf '{"api_version":{"version":"%s","commit":"%s"},"node_version":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}\n' "${GDC_TEST_DAPI_VERSION:-}" "${GDC_TEST_DAPI_COMMIT:-}" ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker" "$tmp/bin/curl"
[[ "$("$tmp/bin/docker" exec 0123456789ab /usr/bin/inferenced version)" == 0.2.15 ]]
if "$tmp/bin/docker" exec 0123456789ab command -v inferenced >"$tmp/builtin.out" 2>"$tmp/builtin.err"; then
  echo 'Docker mock unexpectedly accepted a direct shell builtin' >&2; exit 1
fi
grep -Fq 'command: executable not found' "$tmp/builtin.err"
PATH="$tmp/bin:$PATH" "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/pass.out"
grep -Fq 'PASS canonical runtime verified signer=stopped' "$tmp/pass.out"
if PATH="$tmp/bin:$PATH" GDC_TEST_TMKMS_RUNNING=true "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/tmkms.out" 2>"$tmp/tmkms.err"; then
  echo 'running TMKMS unexpectedly verified canonical signerless Core' >&2; exit 1
fi
grep -Fq 'canonical_signer_running:' "$tmp/tmkms.err"
PATH="$tmp/bin:$PATH" GDC_TEST_TMKMS_RUNNING=true "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 running >"$tmp/running.out"
grep -Fq 'PASS canonical runtime verified signer=running' "$tmp/running.out"
if PATH="$tmp/bin:$PATH" "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 running >"$tmp/missing-signer.out" 2>"$tmp/missing-signer.err"; then
  echo 'missing TMKMS unexpectedly verified completed validator state' >&2; exit 1
fi
grep -Fq 'canonical_signer_unavailable:' "$tmp/missing-signer.err"
if PATH="$tmp/bin:$PATH" GDC_TEST_CATCHING_UP=true "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/sync.out" 2>"$tmp/sync.err"; then
  echo 'catching-up Core unexpectedly verified canonical state' >&2; exit 1
fi
grep -Fq 'canonical_core_not_synced:' "$tmp/sync.err"
if PATH="$tmp/bin:$PATH" GDC_TEST_DAPI_ACTUAL_BINARY_SHA256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/dapi.out" 2>"$tmp/dapi.err"; then
  echo 'mismatched running DAPI binary unexpectedly verified canonical state' >&2; exit 1
fi
grep -Fq 'canonical_dapi_binary_mismatch:' "$tmp/dapi.err"
# The profile records a release-tag source commit while the official
# digest-qualified image may carry the commit that built that release.  The
# image digest is the exact runtime identity, so source provenance mismatch
# must not reject a healthy restored Host.
PATH="$tmp/bin:$PATH" "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/core-provenance.out"
grep -Fq 'PASS canonical runtime verified signer=stopped' "$tmp/core-provenance.out"
grep -Fq 'dapi_source=archive' "$tmp/pass.out"

# Operator-built portable DAPI: the profile clears the archive inputs, so there
# is no digest and no receipt. The image binding stays, version and commit come
# from the running DAPI.
portable="$tmp/portable"
mkdir -p "$portable"
printf '%s\n' \
  'INFERENCED_IMAGE=local/gonka-inferenced:0.2.15-portable@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'DAPI_IMAGE=local/gonka-api:0.2.15-post3-portable@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'DAPI_UPGRADE_URL=' 'DAPI_UPGRADE_SHA256=' 'DAPI_EXPECTED_VERSION=' 'DAPI_EXPECTED_COMMIT=' >"$portable/.env"
printf '%s\n' 'services: {}' >"$portable/compose.yaml"
verify_portable() {
  PATH="$tmp/bin:$PATH" GDC_TEST_DAPI_RECEIPT=absent "$ROOT/02-node/verify-canonical-join-state.sh" "$portable" gonka-devnet-community \
    0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0
}
for reported in 0.2.15-post3 v0.2.15-post3; do
  GDC_TEST_DAPI_VERSION="$reported" GDC_TEST_DAPI_COMMIT=5DBB53DDF3DDC42655FC04DC39D96003169BDBB0 verify_portable >"$tmp/portable.out"
  grep -Fq 'dapi=0.2.15-post3 dapi_commit=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0' "$tmp/portable.out"
  grep -Fq 'dapi_source=image' "$tmp/portable.out"
done
if GDC_TEST_DAPI_VERSION=0.2.15-post3 GDC_TEST_DAPI_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa verify_portable >"$tmp/portable-commit.out" 2>"$tmp/portable-commit.err"; then
  echo 'portable DAPI built from another commit unexpectedly verified' >&2; exit 1
fi
grep -Fq 'canonical_dapi_runtime_mismatch:' "$tmp/portable-commit.err"
# With no archive the image binding is the whole artifact identity: a running
# API container started from another image must not verify, whatever it reports.
if GDC_TEST_API_CONTAINER_IMAGE_ID=sha256:otherimage GDC_TEST_DAPI_VERSION=0.2.15-post3 GDC_TEST_DAPI_COMMIT=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 verify_portable >"$tmp/portable-image.out" 2>"$tmp/portable-image.err"; then
  echo 'portable DAPI container from another image unexpectedly verified' >&2; exit 1
fi
grep -Fq 'canonical_dapi_image_mismatch:' "$tmp/portable-image.err"
if PATH="$tmp/bin:$PATH" GDC_TEST_API_CONTAINER_IMAGE_ID=sha256:otherimage "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community \
  0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/archive-image.out" 2>"$tmp/archive-image.err"; then
  echo 'archive DAPI container from another image unexpectedly verified' >&2; exit 1
fi
grep -Fq 'canonical_dapi_image_mismatch:' "$tmp/archive-image.err"
if GDC_TEST_DAPI_VERSION=0.2.14 GDC_TEST_DAPI_COMMIT=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 verify_portable >"$tmp/portable-version.out" 2>"$tmp/portable-version.err"; then
  echo 'portable DAPI of another version unexpectedly verified' >&2; exit 1
fi
grep -Fq 'canonical_dapi_runtime_mismatch:' "$tmp/portable-version.err"
if verify_portable >"$tmp/portable-unstamped.out" 2>"$tmp/portable-unstamped.err"; then
  echo 'portable DAPI without build metadata unexpectedly verified' >&2; exit 1
fi
grep -Fq 'canonical_dapi_unavailable: DAPI versions endpoint lacks its own build version' "$tmp/portable-unstamped.err"
# A deployment that still names an archive keeps the receipt contract: a lost
# digest must not downgrade it to the image path.
sed 's|^DAPI_UPGRADE_URL=$|DAPI_UPGRADE_URL=https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15-post3/decentralized-api-amd64.zip|' "$portable/.env" >"$tmp/half.env"
mkdir -p "$tmp/half"; mv "$tmp/half.env" "$tmp/half/.env"; cp "$portable/compose.yaml" "$tmp/half/compose.yaml"
if PATH="$tmp/bin:$PATH" GDC_TEST_DAPI_VERSION=0.2.15-post3 GDC_TEST_DAPI_COMMIT=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 "$ROOT/02-node/verify-canonical-join-state.sh" "$tmp/half" gonka-devnet-community \
  0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/half.out" 2>"$tmp/half.err"; then
  echo 'archive deployment without its digest unexpectedly verified' >&2; exit 1
fi
grep -Fq 'canonical_dapi_unavailable: generated DAPI archive digest is missing' "$tmp/half.err"
printf 'PASS canonical JOIN verifier binds digest-qualified Core image, identity and sync state while retaining release provenance, and reads an operator-built DAPI from its own build metadata\n'
