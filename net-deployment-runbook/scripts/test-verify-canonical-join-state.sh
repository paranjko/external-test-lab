#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
deploy="$tmp/deploy"
mkdir -p "$tmp/bin" "$tmp/deploy"
printf '%s\n' \
  'INFERENCED_IMAGE=ghcr.io/product-science/inferenced:0.2.15@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'DAPI_IMAGE=ghcr.io/product-science/api:0.2.15-post3@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' >"$tmp/deploy/.env"
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
  *'inspect --format {{.Image}} abcdef012345') printf '%s\n' sha256:apiimage ;;
  *'image inspect '*api:0.2.15-post3*) printf '%s\n' sha256:apiimage ;;
  *'inspect --format {{.State.Running}} fedcba987654') [[ "${GDC_TEST_TMKMS_RUNNING:-false}" == true ]] && printf '%s\n' true || printf '%s\n' false ;;
  *'exec 0123456789ab readlink -f /proc/1/exe') printf '%s\n' /root/.inference/cosmovisor/current/bin/inferenced ;;
  *'exec 0123456789ab /root/.inference/cosmovisor/current/bin/inferenced version --long') printf '%s\n' 'version: 0.2.15' 'commit: 4d687ed6782bcea3931d2d9135bf322f84e190ab' ;;
  *'exec abcdef012345 readlink -f /proc/1/exe') printf '%s\n' /root/.dapi/cosmovisor/current/bin/decentralized-api ;;
  *) echo "unexpected docker invocation: $args" >&2; exit 2 ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
if [[ "${GDC_TEST_CATCHING_UP:-false}" == true ]]; then catching=true; else catching=false; fi
api_version="${GDC_TEST_DAPI_VERSION:-0.2.15-post3}"
case "$url" in
  */status) printf '%s\n' "{\"result\":{\"node_info\":{\"network\":\"gonka-devnet-community\",\"id\":\"0123456789abcdef0123456789abcdef01234567\",\"version\":\"0.38.19\"},\"sync_info\":{\"catching_up\":$catching,\"latest_block_height\":\"5000\"}}}" ;;
  */abci_info) printf '%s\n' '{"result":{"response":{"version":"0.2.15"}}}' ;;
  */v1/versions) printf '{"api_version":{"version":"%s","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}}\n' "$api_version" ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker" "$tmp/bin/curl"
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
if PATH="$tmp/bin:$PATH" GDC_TEST_DAPI_VERSION=0.2.16 "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 4d687ed6782bcea3931d2d9135bf322f84e190ab 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/dapi.out" 2>"$tmp/dapi.err"; then
  echo 'mismatched running DAPI unexpectedly verified canonical state' >&2; exit 1
fi
grep -Fq 'canonical_dapi_version_mismatch:' "$tmp/dapi.err"
if PATH="$tmp/bin:$PATH" "$ROOT/02-node/verify-canonical-join-state.sh" "$deploy" gonka-devnet-community 0123456789abcdef0123456789abcdef01234567 0.2.15 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0.2.15-post3 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0 >"$tmp/core.out" 2>"$tmp/core.err"; then
  echo 'mismatched running Core unexpectedly verified canonical state' >&2; exit 1
fi
grep -Fq 'canonical_core_commit_mismatch:' "$tmp/core.err"
printf 'PASS canonical JOIN verifier binds signerless Core image, identity and sync state\n'
