#!/usr/bin/env bash
# Real Compose lifecycle in a disposable Docker-in-Docker host, never DevNet.
set -Eeuo pipefail
[[ "${GDC_HOST_UPGRADE_DIND:-}" == true && $EUID == 0 && ! -e /srv/dai ]] || {
  echo 'Run only through test-host-upgrade-lifecycle in a fresh disposable container' >&2
  exit 1
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dockerd-entrypoint.sh dockerd >/tmp/upgrade-dockerd.log 2>&1 &
daemon=$!
trap 'kill "$daemon" 2>/dev/null || true' EXIT
deadline=$((SECONDS+60))
until docker info >/dev/null 2>&1; do
  ((SECONDS < deadline)) || { cat /tmp/upgrade-dockerd.log; exit 1; }
  sleep 2
done
old='busybox@sha256:222ad6d973c0d198014546a65cd02c5fdedcc172123c5b4c2bf0af636550bd94'
next='alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce'
docker pull "$old"
docker pull "$next"
platform="$(docker image inspect "$next" --format '{{.Os}}/{{.Architecture}}')"
sha="$(printf '%064d' 1)"
mkdir -p /fixture /srv/dai
printf '#!/bin/sh\nprintf '\''{"node_info":{"network":"fixture-chain"}}\\n'\''\n' >/fixture/inferenced
chmod 0755 /fixture/inferenced
for layout in flat legacy nested; do
  case "$layout" in
    flat) deploy=/srv/dai/deploy ;;
    legacy) deploy=/srv/dai/node ;;
    nested) deploy=/srv/dai/deploy/fixture ;;
  esac
  mkdir -p "$deploy/data"
  printf 'FILE_VALUE=original\n' >"$deploy/runtime.env"
  printf 'preserved-state\n' >"$deploy/data/state"
  jq -n --arg old "$old" --arg data "$deploy/data" --arg name "fixture-$layout" '
    {name:$name,services:{versiond:{image:$old,command:["sh","-c",
    "if [ -f /data/reject ] && [ -f /etc/alpine-release ]; then exit 42; fi; exec sleep 3600"],
    volumes:[$data+":/data"],env_file:["runtime.env"],environment:{LITERAL:"keep$$value"}},
    node:{image:$old,command:["sleep","3600"],volumes:["/fixture/inferenced:/usr/local/bin/inferenced:ro"]},
    api:{image:$old,command:["sleep","3600"]},tmkms:{image:$old,command:["sleep","3600"]}}}' >"$deploy/compose.yaml"
  files=(-f "$deploy/compose.yaml")
  if [[ "$layout" == flat ]]; then
    printf '{"services":{"versiond":{"environment":{"OVERLAY":"keep"}}}}\n' >"$deploy/overlay.yaml"
    files+=(-f "$deploy/overlay.yaml")
  fi
  dc=(docker compose --project-directory "$deploy" "${files[@]}")
  "${dc[@]}" up -d
  unchanged="$("${dc[@]}" ps -q node api tmkms | sort)"
  invoke() {
    { cat "$ROOT/scripts/lib-lock.sh"; cat "$ROOT/scripts/host-upgrade.sh"; } |
      bash -s -- --remote "$next" "$platform" fixture-chain "$sha"
  }
  # Refuse another network without restarting anything.
  initial="$("${dc[@]}" ps -q versiond)"
  if { cat "$ROOT/scripts/lib-lock.sh"; cat "$ROOT/scripts/host-upgrade.sh"; } |
    bash -s -- --remote "$next" "$platform" wrong-chain "$sha"; then
    echo 'wrong chain accepted' >&2; exit 1
  fi
  [[ "$("${dc[@]}" ps -q versiond)" == "$initial" ]]
  # A candidate that exits must roll back the real container and exact file.
  destination="${files[${#files[@]}-1]}"
  cp "$destination" /fixture/original-compose
  touch "$deploy/data/reject"
  if invoke; then echo 'failed candidate reported success' >&2; exit 1; fi
  cmp /fixture/original-compose "$destination"
  [[ "$(docker inspect "$("${dc[@]}" ps -q versiond)" --format '{{.Image}}')" == "$(docker image inspect "$old" --format '{{.Id}}')" ]]
  rm "$deploy/data/reject"
  invoke
  running="$("${dc[@]}" ps -q versiond)"
  [[ "$(docker inspect "$running" --format '{{.Image}}')" == "$(docker image inspect "$next" --format '{{.Id}}')" ]]
  [[ "$(docker exec "$running" printenv LITERAL)" == "keep\$value" ]]
  invoke
  [[ "$("${dc[@]}" ps -q versiond)" == "$running" ]]
  [[ "$("${dc[@]}" ps -q node api tmkms | sort)" == "$unchanged" ]]
  [[ "$(cat "$deploy/data/state")" == preserved-state ]]
  "${dc[@]}" config --format json | jq -e --arg image "$next" '.services.versiond.image==$image' >/dev/null
  printf 'FILE_VALUE=future\n' >"$deploy/runtime.env"
  "${dc[@]}" config --format json | jq -e '.services.versiond.environment.FILE_VALUE=="future"' >/dev/null
  "${dc[@]}" down
  printf 'PASS %s: wrong-chain refusal, rollback, upgrade, idempotence, unrelated containers and data preserved\n' "$layout"
done
