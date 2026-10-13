#!/usr/bin/env bash
# Exercise the public lifecycle entrypoint, not a helper: a completed reset
# deliberately leaves recovery evidence in GDC_HOME, and the next --plan JOIN
# must accept precisely that reset-only state before any Host mutation.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF

# Reset's remote body is not run on an operator Host: its fake SSH transport
# accepts only the recovery capture and the disposable cleanup body.
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == -G ]]; then
  printf 'hostname fixture.example.test\n'
  exit 0
fi
if [[ "$*" == *' true' ]]; then
  exit 0
fi
if [[ "$*" == *'--remote capture'* ]]; then
  cat >/dev/null
  printf '%s\n' '{"schema_version":1,"kind":"gdc-reset-dai-backup","identity_present":true,"signer_stopped":true,"chain_id":"gonka-devnet-community","archive_path":"/srv/backup/reset-fixture-dai-backup.tar","archive_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  exit 0
fi
if [[ "$*" == *'sudo -n env NODE='*'bash -s'* ]]; then
  cat >/dev/null
  exit 0
fi
printf 'unexpected SSH invocation: %s\n' "$*" >&2
exit 97
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/docker"

# A plan runs the same public-observation and profile-resolution route as a
# JOIN, but it never contacts a Host. The fixture exposes only its two seeds
# and immutable upstream metadata.
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
headers='' output='' url='' write_remote=false
while (($#)); do
  case "$1" in
    -D) headers="${2:-}"; shift 2 ;;
    -o|-H|--connect-timeout|--max-time) [[ "$1" == -o ]] && output="${2:-}"; shift 2 ;;
    --write-out) write_remote=true; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
emit() { if [[ -n "$output" ]]; then printf '%s\n' "$1" >"$output"; else printf '%s\n' "$1"; fi; }
case "$url" in
  *node0.example.test*|*node1.example.test*)
    id=0123456789abcdef0123456789abcdef01234567
    remote_ip=8.8.4.1
    if [[ "$url" == *node1.example.test* ]]; then
      id=89abcdef0123456789abcdef0123456789abcdef
      remote_ip=8.8.4.2
    fi
    case "$url" in
      */status) emit "{\"result\":{\"node_info\":{\"id\":\"$id\",\"network\":\"gonka-devnet-community\",\"version\":\"0.2.15\"},\"sync_info\":{\"catching_up\":false}}}" ;;
      */abci_info) emit '{"result":{"response":{"version":"0.2.15"}}}' ;;
      */net_info) emit '{"result":{"peers":[]}}' ;;
      */v1/versions) emit '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"0.2.16","commit":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}' ;;
      *) exit 22 ;;
    esac
    [[ "$write_remote" != true ]] || printf '\n__GDC_REMOTE_IP__=%s\n' "$remote_ip"
    ;;
  *raw.githubusercontent.com/gonka-ai/gonka/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/deploy/join/docker-compose.yml)
    emit $'services:\n  node:\n    image: ghcr.io/product-science/inferenced:0.2.15\n  api:\n    image: ghcr.io/product-science/api:0.2.15-post3'
    ;;
  *'/releases/tags/release%2Fv0.2.15') emit '{"tag_name":"release/v0.2.15","assets":[{"name":"inferenced-linux-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15/inferenced-linux-amd64.zip","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}' ;;
  *'/releases/tags/release%2Fv0.2.16') emit '{"tag_name":"release/v0.2.16","assets":[{"name":"decentralized-api-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.16/decentralized-api-amd64.zip","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}' ;;
  *'/git/matching-refs/tags/release/v0.2.15') emit '[{"ref":"refs/tags/release/v0.2.15","object":{"type":"commit","sha":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}]' ;;
  *'/git/matching-refs/tags/release/v0.2.16') emit '[{"ref":"refs/tags/release/v0.2.16","object":{"type":"commit","sha":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}]' ;;
  *'ghcr.io/token?'*) emit '{"token":"fixture-token"}' ;;
  *'ghcr.io/v2/'*'/manifests/'*)
    [[ -n "$headers" ]] || exit 2
    printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:3333333333333333333333333333333333333333333333333333333333333333\r\n' >"$headers"
    ;;
  *) exit 22 ;;
esac
EOF
cat >"$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == *host-stack-compose.yml ]]; then
  printf '%s  %s\n' d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94 "$1"
else
  /usr/bin/sha256sum "$@"
fi
EOF
chmod 0755 "$tmp/bin/curl" "$tmp/bin/sha256sum"

home="$tmp/operator"
run_gdc() {
  # The lifecycle fixture must never inherit an operator's aliases, GDC_HOME,
  # Bootstrap override or active run. Only the fixture transport is visible.
  env -i PATH="$tmp/bin:$PATH" HOME="$tmp/home" GDC_HOME="$home" \
    GDC_JOIN_PREFLIGHT_DEADLINE=30 GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 \
    "$ROOT/gdc.sh" "$@"
}
if ! run_gdc host reset fixture-node >"$tmp/reset.out" 2>&1; then
  cat "$tmp/reset.out" >&2
  exit 1
fi
[[ "$(<"$tmp/reset.out")" == *'PASS fixture-node reset'* ]]
shopt -s nullglob
reset_metadata=("$home/fixture-node/state/reset/fixture-node/reset-"*-dai-backup.json)
[[ ${#reset_metadata[@]} -eq 1 ]]
[[ -f "${reset_metadata[0]}" && "$(stat -c %a "${reset_metadata[0]}")" == 600 ]]

run_gdc host join --plan \
  --bootstrap-file "$tmp/bootstrap.json" --public-host fixture.example.test fixture-node >"$tmp/join.out"
join_output="$(<"$tmp/join.out")"
[[ "$join_output" == *'PASS JOIN preflight completed without Host mutation'* ]]
[[ "$join_output" != *'retained local state requires explicit recovery or removal'* ]]
profile="$(find "$home/fixture-node/runs" -type f -path '*/join-fixture-node/join-profile.v1.json' -print -quit)"
[[ -n "$profile" ]]
"$ROOT/scripts/join-profile.sh" validate "$profile"
printf 'PASS reset-then-JOIN retains recovery evidence and reaches a new immutable JOIN profile\n'
