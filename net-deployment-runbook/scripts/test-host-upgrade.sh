#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-upgrade.sh
source "$ROOT/scripts/host-upgrade.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
image="ghcr.io/example/versiond:fixture@sha256:$(printf '%064d' 1)"
valid_image "$image"
if valid_image 'ghcr.io/example/versiond:latest'; then exit 1; fi
if valid_alias '-oProxyCommand=unsafe'; then exit 1; fi
if valid_alias 'node;command'; then exit 1; fi
for layout in flat layered; do
  mkdir "$tmp/$layout"
  jq -n '{name:"upgrade-fixture",services:{versiond:{image:"old:fixture",
    environment:{PASSWORD:"keep$$dollar",UNCHANGED:"yes"},
    volumes:["/fixture/bin:/opt/versiond/bin","/fixture/data:/opt/versiond/data"]},
    node:{image:"${NODE_RUNTIME:-chain:unchanged}"},api:{image:"api:unchanged"},tmkms:{image:"signer:unchanged"}}}' >"$tmp/$layout/compose.json"
  args=(-f "$tmp/$layout/compose.json")
  if [[ "$layout" == layered ]]; then
    printf '{"services":{"versiond":{"environment":{"OVERLAY":"retained"}}}}\n' >"$tmp/$layout/overlay.json"
    args+=(-f "$tmp/$layout/overlay.json")
  fi
  docker compose "${args[@]}" config --format json >"$tmp/$layout/before.json"
  render_versiond "$image" <"$tmp/$layout/before.json" >"$tmp/$layout/desired.json"
  deploy="$tmp/$layout"; project=upgrade-fixture; env_args=()
  compose_layer "${args[${#args[@]}-1]}" | render_versiond "$image" >"$tmp/$layout/next.json"
  args[${#args[@]}-1]="$tmp/$layout/next.json"
  docker compose "${args[@]}" config --format json >"$tmp/$layout/after.json"
  jq -e --slurpfile desired "$tmp/$layout/desired.json" '. == $desired[0]' "$tmp/$layout/after.json" >/dev/null
  jq -e --slurpfile before "$tmp/$layout/before.json" '
    .services.versiond.environment.PASSWORD == "keep$$dollar" and
    (del(.services.versiond.image) == ($before[0] | del(.services.versiond.image)))
  ' "$tmp/$layout/after.json" >/dev/null
  NODE_RUNTIME=chain:future docker compose "${args[@]}" config --format json |
    jq -e '.services.node.image=="chain:future"' >/dev/null
done
export UPGRADE_FIXTURE="$tmp/bootstrap.json" UPGRADE_CALLS="$tmp/ssh.calls" UPGRADE_PAYLOAD="$tmp/remote.sh"
jq --arg image "$image" '.software.components.versiond={version:"fixture",image:$image}' \
  "$ROOT/../bootstrap/examples/software-v1.json" >"$UPGRADE_FIXTURE"
curl() {
  local output=''
  [[ "${*: -1}" == https://gonka-dev.net/gonka-devnet-community/bootstrap.json ]] || return 99
  while (($#)); do
    if [[ "$1" == --output ]]; then output="$2"; shift; fi
    shift
  done
  [[ -n "$output" ]] || return 99
  cp "$UPGRADE_FIXTURE" "$output"
}
ssh() {
  [[ $# == 7 && "$1" == -T && "$2" == -o && "$3" == BatchMode=yes &&
    "$4" == -o && "$5" == ConnectTimeout=10 && "$6" == fixture.Host &&
    "$7" == 'sudo -n bash -s -- --remote ghcr.io/example/versiond:fixture@sha256:'* ]] || return 99
  printf 'called\n' >>"$UPGRADE_CALLS"
  cat >"$UPGRADE_PAYLOAD"
  bash -n "$UPGRADE_PAYLOAD"
}
export -f curl ssh
GDC_HOME="$tmp/operator" bash "$ROOT/gdc.sh" host upgrade fixture.Host
[[ "$(wc -l <"$UPGRADE_CALLS")" == 1 ]]
grep -Fq 'gdc_lock_acquire ()' "$UPGRADE_PAYLOAD"
if GDC_HOME="$tmp/operator" bash "$ROOT/gdc.sh" --release v2026.08.06 host upgrade fixture.Host >"$tmp/refused" 2>&1; then
  echo 'release override accepted' >&2; exit 1
fi
jq 'del(.software.components.versiond)' "$UPGRADE_FIXTURE" >"$tmp/missing.json"
cp "$tmp/missing.json" "$UPGRADE_FIXTURE"
if GDC_HOME="$tmp/operator" bash "$ROOT/gdc.sh" host upgrade fixture.Host >"$tmp/missing.log" 2>&1; then
  echo 'missing versiond accepted' >&2; exit 1
fi
[[ "$(wc -l <"$UPGRADE_CALLS")" == 1 ]]
printf 'PASS image/alias validation and real Compose image-only rendering (not runtime lifecycle acceptance)\n'
