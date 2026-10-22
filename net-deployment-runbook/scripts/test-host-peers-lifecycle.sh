#!/usr/bin/env bash
# Run only in a disposable privileged Docker-in-Docker container.
set -Eeuo pipefail
[[ ${GDC_PEERS_DIND:-} == true && $EUID == 0 && ! -e /srv/dai ]] || exit 2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dockerd-entrypoint.sh dockerd >/tmp/peers-dockerd.log 2>&1 &
daemon=$!
trap 'kill "$daemon" 2>/dev/null || true' EXIT
deadline=$((SECONDS+60))
until docker info >/dev/null 2>&1; do
  ((SECONDS<deadline)) || { cat /tmp/peers-dockerd.log; exit 1; }
  sleep 2
done
image='busybox@sha256:222ad6d973c0d198014546a65cd02c5fdedcc172123c5b4c2bf0af636550bd94'
docker pull "$image"
mkdir -p /srv/dai/deploy /srv/dai/data/inference/config /fixture
touch /srv/dai/deploy/.env
printf '#!/bin/sh\nexec sleep 3600\n' >/fixture/start
chmod 0755 /fixture/start
printf 'preserved chain state\n' >/srv/dai/data/inference/state
export ROOT
# Closed SSH transport executes exactly the stream delivered by the local CLI.
ssh() {
  [[ ${*: -2:1} == fixture.Anchor && ${*: -1} == "sudo -n bash -s -- --remote 'true'" ]] || return 99
  bash -s -- --remote true
}
export -f ssh
dc=(docker compose --project-directory /srv/dai/deploy -f /srv/dai/deploy/compose.yaml)
for mode in direct entrypoint; do
  printf '[p2p]\npex = false\npersistent_peers = "existing"\n' >/srv/dai/data/inference/config/config.toml
  jq -n --arg image "$image" --arg mode "$mode" '
    {name:"fixture-peers",services:{node:{image:$image,
      command:(if $mode=="direct" then ["start","--p2p.pex=false"] else ["sh","/usr/local/bin/start"] end),
      environment:{CONFIG_p2p__persistent_peers:"existing",CONFIG_p2p__seeds:"retained"},
      volumes:["/srv/dai/data/inference:/root/.inference","/fixture/start:/usr/local/bin/start:ro"]},
      tmkms:{image:$image,command:["sleep","3600"]},
      api:{image:$image,command:["sleep","3600"]},
      mlnode:{image:$image,command:["sleep","3600"]}}}
    | .services |= with_entries(.value.stop_grace_period="1s")' >/srv/dai/deploy/compose.yaml
  "${dc[@]}" up -d
  before="$("${dc[@]}" ps -q api tmkms mlnode | sort)"
  bash "$ROOT/scripts/host-peers.sh" --pex true fixture.Anchor
  [[ "$("${dc[@]}" ps -q api tmkms mlnode | sort)" == "$before" ]]
  [[ "$(cat /srv/dai/data/inference/state)" == 'preserved chain state' ]]
  grep -Fxq 'pex = true' /srv/dai/data/inference/config/config.toml
  grep -Fxq 'persistent_peers = "existing"' /srv/dai/data/inference/config/config.toml
  [[ ! -e /srv/dai/deploy/.gdc-peers.lock.d ]]
  "${dc[@]}" config --format json | jq -e '
    .services.node.environment.CONFIG_p2p__pex=="true" and
    .services.node.environment.CONFIG_p2p__persistent_peers=="existing" and
    .services.node.environment.CONFIG_p2p__seeds=="retained"' >/dev/null
  "${dc[@]}" down
  printf 'PASS %s: remote stdin, real Compose restart, unchanged signer/API/ML and chain state\n' "$mode"
done
