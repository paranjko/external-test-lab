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
PATH="$tmp/bin:$PATH" BOOTSTRAP_TEST_GENESIS="$genesis" "$TOOL" stage "$bootstrap" "$tmp/stage" >"$tmp/stage.out"
cmp -s "$genesis" "$tmp/stage/genesis.json"
[[ "$(stat -c '%a' "$tmp/stage/genesis.json")" == 600 ]]

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
mkdir -p "$staging_root/home/bin/$profile_id"
: >"$staging_root/home/bin/$profile_id/inferenced"
chmod 0755 "$staging_root/home/bin/$profile_id/inferenced"
printf '{"profile_id":"%s"}\n' "$profile_id" >"$staging_root/profile.json"

# Extract the real function: sourcing the tool would run its dispatcher.
awk '/^resolve_inferenced_cli\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$TOOL" >"$staging_root/resolver.sh"
[[ -s "$staging_root/resolver.sh" ]] || { echo 'resolve_inferenced_cli not found in network-bootstrap.sh' >&2; exit 1; }

resolve_with() {
  env -u INFERENCED "$@" bash -c '
    set -Eeuo pipefail
    . "$0"
    resolve_inferenced_cli
  ' "$staging_root/resolver.sh"
}

observed="$(GDC_JOIN_PROFILE="$staging_root/profile.json" GDC_HOME="$staging_root/home" resolve_with env)"
[[ "$observed" == "$staging_root/home/bin/$profile_id/inferenced" ]] || {
  echo "network-bootstrap must resolve the profile-bound CLI, got: $observed" >&2; exit 1; }

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
ln -sf "$staging_root/home/bin/$profile_id/inferenced" "$staging_root/home/bin/$profile_id/linked"
mkdir -p "$staging_root/home2/bin/$profile_id"
ln -sf /bin/sh "$staging_root/home2/bin/$profile_id/inferenced"
observed="$(GDC_JOIN_PROFILE="$staging_root/profile.json" GDC_HOME="$staging_root/home2" resolve_with env)"
[[ "$observed" == inferenced ]] || {
  echo "a symlinked profile CLI must be refused, got: $observed" >&2; exit 1; }

# The Genesis download must actually use the resolver, not the bare lookup.
grep -Fq 'cli="$(resolve_inferenced_cli)"' "$TOOL"

echo 'PASS bootstrap Genesis download resolves the profile-bound inferenced CLI'
