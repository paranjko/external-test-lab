#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
runbook="$tmp/runbook"
mkdir -p "$tmp/bin" "$tmp/home/accounts" "$tmp/out" "$tmp/mnemonics" "$tmp/secrets" "$tmp/remote" \
  "$runbook/01-identities-genesis" "$runbook/02-node" "$runbook/scripts"
cp "$ROOT/01-identities-genesis/collect-identities.sh" "$runbook/01-identities-genesis/collect-identities.sh"
cp "$ROOT/scripts/lib.sh" "$runbook/scripts/lib.sh"
cat >"$tmp/inventory.env" <<EOF
GDC_NODE_ALIASES=test-node
GDC_NODE_PUBLIC_HOSTS='test-node=join.example.test'
GDC_NODE_P2P_PORTS='test-node=5000'
GDC_NODE_ML_HOSTS=''
GDC_JOIN_ROLE_INPUT=true
GDC_JOIN_NETWORK_HOST=join.example.test
EOF
printf '%s\n' '{"profile_id":"fixture-join-profile","spec":{"network":{"chain_id":"fixture"},"components":{"core":{"expected_runtime":{"version":"0.2.15","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"dapi":{"expected_runtime":{"version":"0.2.15-post3","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}}' >"$tmp/join-profile.json"
printf 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour\n' >"$tmp/mnemonics/test-node-warm.mnemonic"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift 2 ;;
    -T) shift ;;
    *) break ;;
  esac
done
host="$1"; shift
command="$*"
case "$command" in
  true) exit 0 ;;
  *'rm -rf'*) mkdir -p "$TEST_REMOTE"; exit 0 ;;
  *'./init-identity.sh'*)
    printf '%s\n' '{"node_name":"test-node","node_id":"0123456789abcdef0123456789abcdef01234567","consensus_pubkey":"YQ==","warm_address":"gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq","warm_pubkey_b64":"Yg=="}' >"$TEST_REMOTE/test-node.json"
    exit 255
    ;;
  *"test -s '/srv/dai/identity-bootstrap/test-node.json'"*) test -s "$TEST_REMOTE/test-node.json" ;;
  *'docker ps -a --filter'*) printf 'exited\n' ;;
  *'docker ps --filter'*) printf '\n' ;;
  *'test -s'*) exit 1 ;;
  *'rm -f'*) rm -f "$TEST_REMOTE/test-node.json"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) shift ;;
    -o) shift 2 ;;
    *) break ;;
  esac
done
source="$1" destination="$2"
if [[ "$source" == test-node:/srv/dai/identity-bootstrap/test-node.json ]]; then
  cp "$TEST_REMOTE/test-node.json" "$destination"
elif [[ "$destination" == test-node:/srv/dai/identity-bootstrap/bootstrap.env ]]; then
  cp "$source" "$TEST_REMOTE/bootstrap.env"
fi
EOF
cat >"$tmp/bin/rsync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$runbook/02-node/render-node-env.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
printf '%s\n' "$@" >"$RENDER_ARGS_LOG"
profile=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --join-profile) profile="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$profile" == "$GDC_JOIN_PROFILE" ]] || { echo 'generated profile was not supplied to renderer' >&2; exit 1; }
printf 'COMPOSE_PROJECT_NAME=test-node\nINFERENCED_IMAGE=example/inferenced@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$output"
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/scp" "$tmp/bin/rsync" "$runbook/01-identities-genesis/collect-identities.sh" "$runbook/02-node/render-node-env.sh"

GDC_HOME="$tmp/home" TEST_REMOTE="$tmp/remote" RENDER_ARGS_LOG="$tmp/render-args" \
  GDC_JOIN_PROFILE="$tmp/join-profile.json" PATH="$tmp/bin:$PATH" \
  "$runbook/01-identities-genesis/collect-identities.sh" "$tmp/inventory.env" "$tmp/secrets" "$tmp/out" "$tmp/mnemonics" test-node >"$tmp/out.log"
jq -e '.node_name == "test-node" and .node_id == "0123456789abcdef0123456789abcdef01234567"' "$tmp/out/test-node.json" >/dev/null
grep -Fq 'completed before SSH interruption; signer is stopped and public identity was re-read' "$tmp/out.log"
grep -Fxq -- '--join-profile' "$tmp/render-args"
grep -Fxq -- "$tmp/join-profile.json" "$tmp/render-args"
grep -Fxq 'INFERENCED_IMAGE=example/inferenced@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/remote/bootstrap.env"
printf 'PASS interrupted identity bootstrap is resumed only after identity and signer readback\n'
