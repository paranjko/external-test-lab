#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/network-bootstrap.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bootstrap="$tmp/bootstrap.json"
genesis="$tmp/genesis.json"
printf '%s\n' '{"chain_id":"gonka-fixture","genesis":{"sha256":"__SHA__"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://one.example/chain-rpc","p2p":"tcp://one.example:5000","api":"https://one.example"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://two.example/chain-rpc","p2p":"tcp://two.example:5000"}],"brokers":[{"api_urls":["https://broker.example/v1"]}],"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json"}' >"$bootstrap"
printf '%s\n' '{"chain_id":"gonka-fixture"}' >"$genesis"
digest="$(sha256sum "$genesis" | awk '{print $1}')"
sed -i "s/__SHA__/$digest/" "$bootstrap"

"$TOOL" verify "$bootstrap" >"$tmp/verify"
grep -Fq 'PASS offline network bootstrap' "$tmp/verify"
"$TOOL" env "$bootstrap" >"$tmp/bootstrap.env"
grep -Fq 'export SEED_NODE_RPC_URL=https://one.example/chain-rpc' "$tmp/bootstrap.env"
! grep -q 'BOOTSTRAP_RPC_REDUNDANCY' "$tmp/bootstrap.env"
single_bootstrap="$tmp/single-bootstrap.json"
jq '.bootstrap_mode="genesis-single-seed" | .seeds=[.seeds[0]] | .seeds[0].p2p="tcp://127.0.0.1:5000"' "$bootstrap" >"$single_bootstrap"
"$TOOL" verify "$single_bootstrap" >"$tmp/single-verify"
grep -Fq 'seeds=1' "$tmp/single-verify"
"$TOOL" env "$single_bootstrap" >"$tmp/single.env"
grep -Fq 'export RPC_SERVER_URL_1=https://one.example/chain-rpc' "$tmp/single.env"
grep -Fq 'export RPC_SERVER_URL_2=https://one.example/chain-rpc' "$tmp/single.env"
grep -Fq 'export BOOTSTRAP_RPC_REDUNDANCY=single-endpoint' "$tmp/single.env"
if jq 'del(.bootstrap_mode) | .seeds=[.seeds[0]]' "$bootstrap" >"$tmp/unmarked-single.json" && "$TOOL" verify "$tmp/unmarked-single.json" >/dev/null 2>&1; then
  echo 'single seed without explicit genesis mode unexpectedly validated' >&2; exit 1
fi
if jq '.bootstrap_mode="genesis-single-seed"' "$bootstrap" >"$tmp/multi-in-single-mode.json" && "$TOOL" verify "$tmp/multi-in-single-mode.json" >/dev/null 2>&1; then
  echo 'multiple seeds in genesis-single-seed mode unexpectedly validated' >&2; exit 1
fi
bad_path="$tmp/unsupported-rpc-path.json"
sed 's#https://one.example/chain-rpc#https://one.example/rpc#' "$bootstrap" >"$bad_path"
if "$TOOL" verify "$bad_path" >/dev/null 2>&1; then
  echo 'unsupported Bootstrap RPC path unexpectedly validated' >&2
  exit 1
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/inferenced" <<'EOF'
#!/usr/bin/env bash
cp "$BOOTSTRAP_TEST_GENESIS" "$3"
EOF
chmod 0755 "$tmp/bin/inferenced"

# RPC and P2P probes are mocked because the operator test runs without network permissions.
jq '.seeds[0].p2p="tcp://seed.example:5000" | .brokers=[]' "$single_bootstrap" >"$tmp/single-online.json"
online_genesis="$tmp/rpc-genesis.json"
printf '%s\n' '{"chain_id":"gonka-fixture","app_hash":null,"initial_height":1,"consensus":{"params":{"block":{"max_bytes":"22020096"}}}}' >"$online_genesis"
online_genesis_raw_sha=$(sha256sum "$online_genesis" | awk '{print $1}')
online_genesis_canonical_sha=$(jq -eS '
  del(.app_name, .app_version)
  | if has("app_hash") then .app_hash = (.app_hash // "") else . end
  | if has("initial_height") then .initial_height = (.initial_height | tostring) else . end
  | if .consensus.params? then .consensus_params = .consensus.params | del(.consensus) else . end
' "$online_genesis" | sha256sum | awk '{print $1}')
[[ "$online_genesis_raw_sha" != "$online_genesis_canonical_sha" ]] \
  || { echo 'fixture must distinguish raw distribution hash from canonical identity hash' >&2; exit 1; }
jq --arg sha "$online_genesis_raw_sha" '.genesis.sha256=$sha' "$tmp/single-online.json" >"$tmp/single-online-raw.json"
mv "$tmp/single-online-raw.json" "$tmp/single-online.json"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=${!#}
case "$url" in
  */one.example/chain-rpc/status) printf '{"result":{"node_info":{"id":"%s","network":"%s"}}}\n' "${BOOTSTRAP_TEST_NODE_ID:-0123456789abcdef0123456789abcdef01234567}" "$BOOTSTRAP_TEST_CHAIN_ID" ;;
  */two.example/chain-rpc/status) printf '{"result":{"node_info":{"id":"89abcdef0123456789abcdef0123456789abcdef","network":"%s"}}}\n' "$BOOTSTRAP_TEST_CHAIN_ID" ;;
  */v1/participants) printf '[]\n' ;;
  */v1/models) printf '[]\n' ;;
  *) echo "unexpected local fixture URL: $url" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"
cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BOOTSTRAP_TEST_TIMEOUT_LOG"
EOF
chmod 0755 "$tmp/bin/timeout"
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" BOOTSTRAP_TEST_TIMEOUT_LOG="$tmp/timeout.log" BOOTSTRAP_TEST_NODE_ID=0123456789abcdef0123456789abcdef01234567 BOOTSTRAP_TEST_CHAIN_ID=gonka-fixture \
  "$TOOL" online "$tmp/single-online.json" >"$tmp/single-online.out"
grep -Fq 'PASS online network bootstrap chain_id=gonka-fixture seeds=1' "$tmp/single-online.out"
grep -Fq 'seed.example/5000' "$tmp/timeout.log"
if PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" BOOTSTRAP_TEST_TIMEOUT_LOG="$tmp/timeout.log" BOOTSTRAP_TEST_NODE_ID=89abcdef0123456789abcdef0123456789abcdef BOOTSTRAP_TEST_CHAIN_ID=gonka-fixture \
  "$TOOL" online "$tmp/single-online.json" >/dev/null 2>&1; then
  echo 'single-seed online accepted a mismatched live node ID' >&2; exit 1
fi
if PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" BOOTSTRAP_TEST_TIMEOUT_LOG="$tmp/timeout.log" BOOTSTRAP_TEST_NODE_ID=0123456789abcdef0123456789abcdef01234567 BOOTSTRAP_TEST_CHAIN_ID=wrong-chain \
  "$TOOL" online "$tmp/single-online.json" >/dev/null 2>&1; then
  echo 'single-seed online accepted a mismatched live chain ID' >&2; exit 1
fi
if jq '.genesis.sha256="1111111111111111111111111111111111111111111111111111111111111111"' "$tmp/single-online.json" >"$tmp/single-wrong-genesis.json" && \
  PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" BOOTSTRAP_TEST_TIMEOUT_LOG="$tmp/timeout.log" BOOTSTRAP_TEST_NODE_ID=0123456789abcdef0123456789abcdef01234567 BOOTSTRAP_TEST_CHAIN_ID=gonka-fixture \
  "$TOOL" online "$tmp/single-wrong-genesis.json" >/dev/null 2>&1; then
  echo 'single-seed online accepted a mismatched Genesis hash' >&2; exit 1
fi

# A canonical identity digest is not a substitute for the published raw-byte
# distribution digest. Both bootstrap modes must reject it when the actual
# download has different bytes but the same canonical chain identity.
jq --arg sha "$online_genesis_canonical_sha" '.genesis.sha256=$sha' "$tmp/single-online.json" >"$tmp/single-canonical-only.json"
if PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" BOOTSTRAP_TEST_TIMEOUT_LOG="$tmp/timeout.log" BOOTSTRAP_TEST_NODE_ID=0123456789abcdef0123456789abcdef01234567 BOOTSTRAP_TEST_CHAIN_ID=gonka-fixture \
  "$TOOL" online "$tmp/single-canonical-only.json" >/dev/null 2>&1; then
  echo 'single-seed online accepted canonical hash in place of the raw distribution hash' >&2; exit 1
fi
two_seed_raw="$tmp/two-seed-raw.json"
jq --arg sha "$online_genesis_raw_sha" '.genesis.sha256=$sha' "$bootstrap" >"$two_seed_raw"
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" BOOTSTRAP_TEST_TIMEOUT_LOG="$tmp/timeout.log" BOOTSTRAP_TEST_NODE_ID=0123456789abcdef0123456789abcdef01234567 BOOTSTRAP_TEST_CHAIN_ID=gonka-fixture \
  "$TOOL" online "$two_seed_raw" >"$tmp/two-seed-online.out"
grep -Fq 'PASS online network bootstrap chain_id=gonka-fixture seeds=2' "$tmp/two-seed-online.out"
jq --arg sha "$online_genesis_canonical_sha" '.genesis.sha256=$sha' "$bootstrap" >"$tmp/two-seed-canonical-only.json"
if PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" BOOTSTRAP_TEST_TIMEOUT_LOG="$tmp/timeout.log" BOOTSTRAP_TEST_NODE_ID=0123456789abcdef0123456789abcdef01234567 BOOTSTRAP_TEST_CHAIN_ID=gonka-fixture \
  "$TOOL" online "$tmp/two-seed-canonical-only.json" >/dev/null 2>&1; then
  echo 'two-seed online accepted canonical hash in place of the raw distribution hash' >&2; exit 1
fi

PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$genesis" "$TOOL" stage "$single_bootstrap" "$tmp/single-stage" >"$tmp/single-stage.out"
cmp -s "$genesis" "$tmp/single-stage/genesis.json"
grep -Fq 'export BOOTSTRAP_RPC_REDUNDANCY=single-endpoint' "$tmp/single-stage/bootstrap.env"
grep -Fq '0123456789abcdef0123456789abcdef01234567@127.0.0.1:5000' "$tmp/single-stage/genesis-seeds.txt"
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$genesis" "$TOOL" stage "$bootstrap" "$tmp/stage" >"$tmp/stage.out"
cmp -s "$genesis" "$tmp/stage/genesis.json"
[[ "$(stat -c '%a' "$tmp/stage/genesis.json")" == 600 ]]

# Stage the non-canonical RPC bytes through both descriptor modes and prove
# the downloader preserves them byte-for-byte. A canonical-only digest must
# not stage in either mode.
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" "$TOOL" stage "$tmp/single-online.json" "$tmp/single-online-stage" >"$tmp/single-online-stage.out"
cmp -s "$online_genesis" "$tmp/single-online-stage/genesis.json"
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" "$TOOL" stage "$two_seed_raw" "$tmp/two-seed-stage" >"$tmp/two-seed-stage.out"
cmp -s "$online_genesis" "$tmp/two-seed-stage/genesis.json"
if PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" "$TOOL" stage "$tmp/single-canonical-only.json" "$tmp/canonical-stage" >/dev/null 2>&1; then
  echo 'single-seed stage accepted canonical hash in place of the raw distribution hash' >&2; exit 1
fi
if PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$online_genesis" "$TOOL" stage "$tmp/two-seed-canonical-only.json" "$tmp/canonical-stage" >/dev/null 2>&1; then
  echo 'two-seed stage accepted canonical hash in place of the raw distribution hash' >&2; exit 1
fi

if INFERENCED=missing-inferenced "$TOOL" stage "$bootstrap" "$tmp/missing-cli-stage" >"$tmp/missing-cli.out" 2>"$tmp/missing-cli.err"; then
  echo 'bootstrap staging unexpectedly worked without inferenced' >&2
  exit 1
fi
grep -Fq 'stage=dependency field=inferenced' "$tmp/missing-cli.err"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
cp "$BOOTSTRAP_TEST_DOCUMENT" "$output"
printf '200'
EOF
cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
echo 'python3 must not be called by the operator bootstrap path' >&2
exit 127
EOF
chmod 0755 "$tmp/bin/curl" "$tmp/bin/python3"
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_DOCUMENT="$bootstrap" "$ROOT/scripts/fetch-network-bootstrap.sh" --url https://bootstrap.example/bootstrap.json --output "$tmp/fetched.json" >"$tmp/fetch.out"
cmp -s "$bootstrap" "$tmp/fetched.json"
grep -Fq 'PASS downloaded and validated network bootstrap' "$tmp/fetch.out"

printf '%s\n' '{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","$schema":"https://gonka-dev.net/v1.bootstrap.schema.json"}' >"$tmp/duplicate.json"
if "$TOOL" verify "$tmp/duplicate.json" >/dev/null 2>&1; then
  echo 'duplicate bootstrap keys unexpectedly validated' >&2
  exit 1
fi
printf 'PASS operator bootstrap shell path has no Python dependency\n'

# JOIN installs the CLI off PATH; network-bootstrap.sh must still find it.
staging_root="$(mktemp -d)"
trap 'rm -rf -- "$staging_root"' EXIT
profile_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
version=9.9.9
mkdir -p "$staging_root/home/bin/$version"
cat >"$staging_root/home/bin/$version/inferenced" <<'EOF'
#!/usr/bin/env bash
printf 'inferenced v9.9.9\n'
EOF
chmod 0755 "$staging_root/home/bin/$version/inferenced"
archive_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
binary_sha="$(sha256sum "$staging_root/home/bin/$version/inferenced" | awk '{print $1}')"
printf 'archive_sha256=%s\nplatform=LINUX_AMD64\nbinary_sha256=%s\n' "$archive_sha" "$binary_sha" >"$staging_root/home/bin/$version/artifact.env"
printf '{"profile_id":"%s","spec":{"components":{"core":{"expected_runtime":{"version":"%s"},"installation":{"binary":{"sha256":"%s"}}}}}}\n' "$profile_id" "$version" "$archive_sha" >"$staging_root/profile.json"

# Extract the real function: sourcing the tool would run its dispatcher.
awk '/^resolve_inferenced_cli\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$TOOL" >"$staging_root/resolver.sh"
cp "$ROOT/scripts/resolve-shared-inferenced-cli.sh" "$staging_root/resolve-shared-inferenced-cli.sh"
[[ -s "$staging_root/resolver.sh" ]] || { echo 'resolve_inferenced_cli not found in network-bootstrap.sh' >&2; exit 1; }

resolve_with() {
  env -u INFERENCED "$@" bash -c '
    set -Eeuo pipefail
    . "$0"
    resolve_inferenced_cli
  ' "$staging_root/resolver.sh"
}

observed="$(GDC_JOIN_PROFILE="$staging_root/profile.json" GDC_HOME="$staging_root/home" resolve_with env)"
[[ "$observed" == "$staging_root/home/bin/$version/inferenced" ]] || {
  echo "network-bootstrap must resolve the profile-bound CLI, got: $observed" >&2; exit 1; }

conflicting_profile="$staging_root/conflicting-profile.json"
jq '.spec.components.core.installation.binary.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$staging_root/profile.json" >"$conflicting_profile"
if GDC_JOIN_PROFILE="$conflicting_profile" GDC_HOME="$staging_root/home" resolve_with env \
  >"$staging_root/conflict.out" 2>"$staging_root/conflict.err"; then
  echo 'bootstrap resolver accepted a same-version alternate archive' >&2; exit 1
fi

# Outside a JOIN the plain PATH lookup must be unchanged.
observed="$(resolve_with env)"
[[ "$observed" == inferenced ]] || {
  echo "network-bootstrap must fall back to PATH outside a JOIN, got: $observed" >&2; exit 1; }

# An explicit override still wins.
observed="$(GDC_JOIN_PROFILE="$staging_root/profile.json" GDC_HOME="$staging_root/home" \
  env INFERENCED=/usr/bin/true bash -c '. "$0"; resolve_inferenced_cli' "$staging_root/resolver.sh")"
[[ "$observed" == /usr/bin/true ]] || {
  echo "explicit INFERENCED must win, got: $observed" >&2; exit 1; }

# A symlink does not count: the profile is the authority for JOIN tools.
ln -sf "$staging_root/home/bin/$version/inferenced" "$staging_root/home/bin/$version/linked"
mkdir -p "$staging_root/home2/bin/$version"
ln -sf /bin/sh "$staging_root/home2/bin/$version/inferenced"
if GDC_JOIN_PROFILE="$staging_root/profile.json" GDC_HOME="$staging_root/home2" resolve_with env \
  >"$staging_root/symlink.out" 2>"$staging_root/symlink.err"; then
  echo 'a symlinked profile CLI must fail closed' >&2; exit 1
fi

# The Genesis download must actually use the resolver, not the bare lookup.
grep -Fq 'cli="$(resolve_inferenced_cli)"' "$TOOL"

echo 'PASS bootstrap Genesis download resolves the profile-bound inferenced CLI'
