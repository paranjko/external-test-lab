#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT_IDENTITY="$ROOT/02-node/init-identity.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/node.env" <<EOF
COMPOSE_PROJECT_NAME=fixture-node
KEYRING_PASSWORD=fixture-password
KEY_NAME=fixture-node-warm
NODE_NAME=fixture-node
EOF

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
case "$*" in
  *'stop tmkms')
    [[ "${FAKE_STOP_RESULT:-ok}" == ok ]]
    ;;
  ps\ -a\ --filter*)
    [[ -n "${FAKE_TMKMS_STATE:-}" ]] && printf '%s\n' "$FAKE_TMKMS_STATE"
    ;;
  *'keys show'*'--pubkey'*) printf '%s\n' '{"key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}' ;;
  *'keys show'*'-a'*) printf '%s\n' 'gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' ;;
  *'show-node-id'*) printf '%s\n' '0123456789abcdef0123456789abcdef01234567' ;;
  *'tmkms-pubkey'*) printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' ;;
  *'test -s /gdc-identity/p2p/node_key.json'*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker"

run_init() {
  local name="$1" state="${2:-}" stop_result="${3:-ok}"
  rm -f "$tmp/docker.log" "$tmp/identity.json"
  if PATH="$tmp/bin:$PATH" FAKE_DOCKER_LOG="$tmp/docker.log" \
    FAKE_TMKMS_STATE="$state" FAKE_STOP_RESULT="$stop_result" \
    "$INIT_IDENTITY" --env "$tmp/node.env" --output "$tmp/identity.json" \
    --mnemonic-output "$tmp/warm.mnemonic" >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    echo "$name unexpectedly succeeded" >&2
    return 1
  fi
}

# A stopped temporary signer is accepted and the generated identity is valid.
PATH="$tmp/bin:$PATH" FAKE_DOCKER_LOG="$tmp/docker.log" FAKE_TMKMS_STATE=exited \
  "$INIT_IDENTITY" --env "$tmp/node.env" --output "$tmp/success.json" \
  --mnemonic-output "$tmp/success.mnemonic" >/dev/null
jq -e '.node_name == "fixture-node" and .node_id == "0123456789abcdef0123456789abcdef01234567"' "$tmp/success.json" >/dev/null
grep -Fq 'stop tmkms' "$tmp/docker.log"
grep -Fq 'ps -a --filter' "$tmp/docker.log"

run_init stop-failure '' fail
grep -Fq 'Temporary TMKMS signer stop failed' "$tmp/stop-failure.err"
! grep -Fq 'ps -a --filter' "$tmp/docker.log"

for state in restarting created paused dead unknown; do
  run_init "$state" "$state"
  grep -Fq "Temporary TMKMS signer is not definitively stopped: state=$state" "$tmp/$state.err"
done

printf 'PASS temporary TMKMS stop, failure, and non-terminal state gates are fail-closed\n'
