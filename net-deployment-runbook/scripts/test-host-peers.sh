#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
source "$ROOT/scripts/host-peers.sh"
peer="$(printf '%040d' 2)@west.example.test:5000"
for mode in direct entrypoint; do
  jq -cn --arg mode "$mode" '{name:"fixture-peers",services:{node:{image:"fixture:unchanged",environment:{OTHER:"keep",CONFIG_p2p__persistent_peers:"existing",CONFIG_p2p__seeds:"retained"},
    command:(if $mode=="direct" then ["start","--home","/root/.inference","--priv_validator_laddr","tcp://0.0.0.0:26658",
      "--p2p.pex=false","--p2p.persistent_peers","obsolete","--p2p.seeds=obsolete"] else ["sh","/usr/local/bin/gdc-node-entrypoint"] end),
    volumes:["/tmp/fixture-chain:/root/.inference"]},tmkms:{image:"fixture:signer"}}}' >"$tmp/$mode.json"
  render_peers true <"$tmp/$mode.json" >"$tmp/$mode.next.json"
  jq -e --slurpfile before "$tmp/$mode.json" --arg peers "$peer" '
    .services.tmkms==$before[0].services.tmkms and .services.node.volumes==$before[0].services.node.volumes
    and .services.node.image==$before[0].services.node.image and .services.node.environment.OTHER=="keep"
    and .services.node.environment.CONFIG_p2p__persistent_peers=="existing"
    and .services.node.environment.CONFIG_p2p__seeds=="retained"
    and .services.node.environment.CONFIG_p2p__pex=="true"' "$tmp/$mode.next.json" >/dev/null
  if [[ "$mode" == direct ]]; then
    jq -e '.services.node.command | index("--p2p.pex=true")!=null and index("obsolete")!=null and index("--p2p.seeds=obsolete")!=null and index("tcp://0.0.0.0:26658")!=null' "$tmp/$mode.next.json" >/dev/null
  else
    jq -e --slurpfile before "$tmp/$mode.json" '.services.node.command==$before[0].services.node.command' "$tmp/$mode.next.json" >/dev/null
  fi
  docker compose -f "$tmp/$mode.next.json" config --quiet
done
mkdir -p "$tmp/bin"
export PEER_TEST_LOG="$tmp/ssh.log"
# Every SSH alias below is produced and handled solely by this closed mock.
ssh() {
  local alias="${*: -2:1}" operation="${*: -1}"
  printf '%s %s\n' "$alias" "$operation" >>"$PEER_TEST_LOG"
  cat >/dev/null
  [[ "$alias" == fixture.Anchor && "$operation" == *"--remote 'true'" ]] || exit 99
}
export -f ssh
bash "$ROOT/scripts/host-peers.sh" --pex true fixture.Anchor
[[ "$(wc -l <"$PEER_TEST_LOG")" == 1 ]]
grep -q '^fixture.Anchor .*--remote' "$PEER_TEST_LOG"
! grep -Eq '(reset|join|tmkms)' "$PEER_TEST_LOG"
if bash "$ROOT/scripts/host-peers.sh" --pex true fixture.Anchor fixture.West >"$tmp/duplicate.log" 2>&1; then
  echo 'multiple target aliases were accepted' >&2; exit 1
fi
printf 'PASS peer rendering, real Compose validation, arbitrary mocked aliases and target-only update\n'
