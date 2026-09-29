#!/usr/bin/env bash
# Exercise real preparation filesystem operations through a simulated Docker API.
set -Eeuo pipefail
script="$(cd "$(dirname "$0")/../02-node" && pwd)/prepare-consensus-signer-recovery.sh"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
mkdir "$temp/bin"
cat >"$temp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case " $* " in
  *' ps '*) printf '%064d\n%064d\n' 1 2 ;;
  ' inspect '*)
    jq '[{Id:("1"*64),Image:"retained-image",Name:"node",HostConfig:{RestartPolicy:{Name:.restart}},State:{Running:.running},Config:{Env:["SECRET=must-not-be-retained"],Labels:{"com.docker.compose.service":"node"}}},
      {Id:("2"*64),Image:"retained-image",Name:"tmkms",HostConfig:{RestartPolicy:{Name:.restart}},State:{Running:.running},Config:{Env:["SECRET=must-not-be-retained"],Labels:{"com.docker.compose.service":"tmkms"}}}]' "$FAKE_DOCKER_STATE" ;;
  ' update '*) jq '.restart="no"' "$FAKE_DOCKER_STATE" >"$FAKE_DOCKER_STATE.tmp"; mv "$FAKE_DOCKER_STATE.tmp" "$FAKE_DOCKER_STATE" ;;
  *' stop '*)
    [[ ${FAKE_STOP_FAIL:-0} == 0 ]] || exit 1
    jq '.running=false' "$FAKE_DOCKER_STATE" >"$FAKE_DOCKER_STATE.tmp"; mv "$FAKE_DOCKER_STATE.tmp" "$FAKE_DOCKER_STATE" ;;
  *) echo "unexpected Docker command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$temp/bin/docker"
export PATH="$temp/bin:$PATH"
fixture() {
  base="$temp/$1"; root="$base/validator"; backup="$base/backups"
  export FAKE_DOCKER_STATE="$base/docker.json" FAKE_STOP_FAIL=0
  mkdir -p "$root/deploy" "$root/signer/tmkms/secrets" "$root/signer/tmkms/state" "$root/identity"
  key="$root/signer/tmkms/secrets/priv_validator_key.softsign"
  printf synthetic-test-key >"$key"
  digest="$(sha256sum "$key" | awk '{print $1}')"
  printf '{"height":"12"}' >"$root/signer/tmkms/state/priv_validator_state.json"
  printf fixture >"$root/deploy/.env"
  printf fixture >"$root/deploy/compose.yaml"
  printf '{"running":true,"restart":"always"}' >"$FAKE_DOCKER_STATE"
}
prepare() { bash -c 'source "$1"; shift; prepare_consensus_signer_recovery "$@"' test "$script" "$root/deploy" "$backup" test-run "${1:-$digest}"; }
refuse() { if prepare "$@" >"$base/result.log" 2>&1; then echo 'unexpected preparation success' >&2; exit 1; fi; }
still_running() { jq -e '.running == true and .restart == "always"' "$FAKE_DOCKER_STATE" >/dev/null; }
fixture success
prepare
jq -e '.running == false and .restart == "no"' "$FAKE_DOCKER_STATE" >/dev/null
evidence="$backup/consensus-recovery-test-run"
jq -e '.activation_authorized == false' "$evidence/prepared.json" >/dev/null
if grep -q SECRET "$evidence/containers.json"; then echo 'FAIL retained Docker secrets' >&2; exit 1; fi
tar -xOf "$evidence/validator-before.tar" signer/tmkms/secrets/priv_validator_key.softsign | cmp - "$key"
[[ "$(sha256sum "$key" | awk '{print $1}')" == "$digest" ]]
refuse
fixture wrong-key
refuse "$(printf '%064d' 0)"
still_running
[[ ! -e "$backup" ]]
fixture stop-failure
export FAKE_STOP_FAIL=1
refuse
[[ ! -e "$backup/consensus-recovery-test-run/prepared.json" ]]
fixture nested-backup
backup="$root/backups"
refuse
still_running
fixture symlink-state
mv "$root/signer/tmkms/state" "$base/external-state"
ln -s "$base/external-state" "$root/signer/tmkms/state"
refuse
still_running
fixture missing-state
rm "$root/signer/tmkms/state/priv_validator_state.json"
refuse
still_running
echo 'PASS recovery preparation fencing, archive and refusal cases'
