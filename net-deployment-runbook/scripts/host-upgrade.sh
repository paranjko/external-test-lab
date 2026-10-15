#!/usr/bin/env bash
# Reconcile one Host's versiond image with the public bootstrap software contract.
set -Eeuo pipefail
umask 077

die() { printf 'host upgrade: %s\n' "$*" >&2; exit 1; }
valid_alias() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_image() { [[ "$1" =~ ^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$ ]]; }

render_versiond() {
  jq --arg image "$1" '.services.versiond.image=$image'
}

replace_compose() {
  local source="$1" destination="$2" temporary
  temporary="$(mktemp "${destination}.versiond.XXXXXX")" || return 1
  if ! install -m 0600 "$source" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  mv -f -- "$temporary" "$destination"
}

compose() {
  docker compose --project-directory "$deploy" -p "$project" "${env_args[@]}" "${file_args[@]}" "$@"
}

compose_layer() {
  docker compose --project-directory "$deploy" -p "$project" "${env_args[@]}" -f "$1" \
    --profile '*' config --format json --no-interpolate --no-normalize \
    --no-path-resolution --no-env-resolution --no-consistency
}

stable_versiond() {
  local expected="$1" deadline=$((SECONDS+120)) stable_since=0 previous='' id info signature
  while ((SECONDS < deadline)); do
    id="$(compose ps -q versiond)" || return 1
    if [[ "$id" =~ ^[0-9a-f]+$ ]] && info="$(docker inspect "$id")" &&
      jq -e --arg image "$expected" 'length == 1 and .[0].Image == $image and
        .[0].State.Running and (.[0].State.Restarting | not) and
        ((.[0].State.Health.Status // "healthy") == "healthy")' <<<"$info" >/dev/null; then
      signature="$(jq -c '.[0] | [.Id,.State.StartedAt,.RestartCount]' <<<"$info")"
      if [[ "$signature" != "$previous" ]]; then
        previous="$signature"; stable_since=$SECONDS
      elif ((SECONDS-stable_since >= 10)); then
        return 0
      fi
    else
      previous=''
      if [[ -n "${info:-}" ]] && jq -e '.[0].State.Status == "exited" or .[0].State.Status == "dead"' <<<"$info" >/dev/null; then
        return 1
      fi
    fi
    sleep 2
  done
  return 1
}

remote_upgrade() {
  local image="$1" platform="$2" chain="$3" bootstrap_sha="$4"
  [[ $EUID == 0 ]] || die 'passwordless sudo is required'
  docker compose config --help | grep -q -- '--no-env-resolution' ||
    die 'Docker Compose with --no-env-resolution is required to preserve environment files'
  if ! valid_image "$image" || ! valid_alias "$chain" ||
    [[ ! "$platform" =~ ^linux/(amd64|arm64)$ || ! "$bootstrap_sha" =~ ^[0-9a-f]{64}$ ]]; then
    die 'invalid request'
  fi
  local ids info original old_image project deploy config_files destination file candidate receipt image_id
  local -a files=() file_args=() env_args=() original_file_args=()
  ids="$(docker ps -q --filter label=com.docker.compose.service=versiond)"
  [[ "$ids" =~ ^[0-9a-f]+$ ]] || die 'expected exactly one running managed versiond service'
  original="$ids"
  info="$(docker inspect "$original")"
  old_image="$(jq -er '.[0].Image' <<<"$info")"
  deploy="$(jq -er '.[0].Config.Labels["com.docker.compose.project.working_dir"]' <<<"$info")"
  project="$(jq -er '.[0].Config.Labels["com.docker.compose.project"]' <<<"$info")"
  config_files="$(jq -er '.[0].Config.Labels["com.docker.compose.project.config_files"]' <<<"$info")"
  [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ && "$old_image" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'invalid runtime identity'
  [[ "$deploy" == /srv/dai/deploy ]] || die 'unsupported managed layout: host upgrade requires /srv/dai/deploy'
  [[ "$(realpath -e "$deploy")" == "$deploy" ]] || die 'noncanonical deployment directory'
  IFS=',' read -r -a files <<<"$config_files"
  ((${#files[@]} > 0)) || die 'no Compose files'
  for file in "${files[@]}"; do
    [[ "$file" == /srv/dai/* && -f "$file" && ! -L "$file" &&
      "$(realpath -e "$file")" == "$file" ]] || die 'unsafe Compose file'
    file_args+=(-f "$file")
  done
  original_file_args=("${file_args[@]}")
  [[ ! -f "$deploy/.env" ]] || env_args=(--env-file "$deploy/.env")
  gdc_lock_acquire "$deploy/.gdc-versiond-upgrade.lock" 0 'another versiond upgrade is running' || exit 1
  UPGRADE_LOCK="$GDC_LOCK_DIR"
  trap 'gdc_lock_release "${UPGRADE_LOCK:-}"' EXIT
  [[ "$(docker ps -q --filter label=com.docker.compose.service=versiond)" == "$original" ]] || die 'runtime changed during discovery'
  ids="$(compose ps -q node)"
  [[ "$ids" =~ ^[0-9a-f]+$ ]] || die 'expected one running chain node in the same project'
  docker exec "$ids" inferenced status | jq -e --arg chain "$chain" \
    '(.node_info.network // .NodeInfo.network // .NodeInfo.Network) == $chain' >/dev/null || die 'bootstrap chain differs from host'
  [[ ! -L "$deploy/.gdc-versiond-upgrades" ]] || die 'unsafe receipt directory'
  install -d -m 0700 "$deploy/.gdc-versiond-upgrades"
  receipt="$(mktemp -d "$deploy/.gdc-versiond-upgrades/attempt.XXXXXX")"
  printf 'Receipt: %s\n' "$receipt"
  compose --profile '*' config --format json >"$receipt/before.json"
  jq -e '.services.versiond | type == "object"' "$receipt/before.json" >/dev/null || die 'missing versiond service'
  render_versiond "$image" <"$receipt/before.json" >"$receipt/desired.json"
  docker pull --platform "$platform" "$image" >"$receipt/pull.log" 2>&1 || die "image pull failed; inspect $receipt"
  docker image inspect "$image" >"$receipt/image.json"
  jq -e --arg platform "$platform" 'length == 1 and (.[0].Os + "/" + .[0].Architecture) == $platform' \
    "$receipt/image.json" >/dev/null || die 'image platform mismatch'
  image_id="$(jq -er '.[0].Id' "$receipt/image.json")"
  if jq -e --slurpfile desired "$receipt/desired.json" '. == $desired[0]' "$receipt/before.json" >/dev/null && [[ "$old_image" == "$image_id" ]]; then
    stable_versiond "$image_id" || die 'existing versiond is not stable'
    printf 'PASS versiond already matches bootstrap; no restart; inference not tested\n'
    return
  fi
  destination="${files[${#files[@]}-1]}"
  candidate="$receipt/candidate.json"
  compose_layer "$destination" >"$receipt/layer.before.json"
  render_versiond "$image" <"$receipt/layer.before.json" >"$candidate"
  file_args[${#file_args[@]}-1]="$candidate"
  compose --profile '*' config --format json >"$receipt/trial.json"
  jq -e --slurpfile desired "$receipt/desired.json" '. == $desired[0]' "$receipt/trial.json" >/dev/null || die 'Compose layering would change more than versiond.image'
  file_args=("${original_file_args[@]}")
  cp -p "$destination" "$receipt/compose.before"
  jq -n --arg image "$image" --arg old "$old_image" --arg source "$bootstrap_sha" --arg destination "$destination" \
    '{image:$image,old_image_id:$old,bootstrap_sha256:$source,compose_file:$destination}' >"$receipt/intent.json"
  compose --profile '*' config --format json >"$receipt/recheck.json"
  jq -e --slurpfile before "$receipt/before.json" '. == $before[0]' "$receipt/recheck.json" >/dev/null || die 'configuration changed before apply'
  # Keep the Compose layer at its original path, so subsequent Host operations
  # retain the same config-file labels and cannot revert to a transient override.
  replace_compose "$candidate" "$destination"
  if compose up -d --no-deps --pull never versiond >"$receipt/up.log" 2>&1 && stable_versiond "$image_id"; then
    printf 'PASS versiond updated from bootstrap; inference not tested; receipt=%s\n' "$receipt"
    jq -n --arg image "$image" '{status:"upgraded",image:$image,serving_verified:false}' >"$receipt/result.json"
    return
  fi
  printf 'Upgrade failed; restoring previous local image\n' >&2
  cmp -s "$candidate" "$destination" || die "configuration changed concurrently; refusing rollback; inspect $receipt"
  render_versiond "$old_image" <"$receipt/layer.before.json" >"$receipt/recovery.json"
  replace_compose "$receipt/recovery.json" "$destination"
  if compose up -d --no-deps --pull never versiond >"$receipt/recovery.log" 2>&1 && stable_versiond "$old_image"; then
    replace_compose "$receipt/compose.before" "$destination"
    printf '{"status":"previous_image_running"}\n' >"$receipt/rollback.json"
    die "upgrade failed; previous image and Compose restored; inspect $receipt"
  fi
  die "upgrade and recovery failed; inspect $receipt"
}

main() {
  if [[ "${1:-}" == --remote ]]; then
    [[ $# == 5 ]] || die 'invalid remote arguments'
    shift
    remote_upgrade "$@"
    return
  fi
  local target="${1:-}" bootstrap_url='https://gonka-dev.net/gonka-devnet-community/bootstrap.json'
  local root document image platform chain sha remote_command
  valid_alias "$target" || die 'expected one SSH alias'
  shift
  if (($#)); then
    [[ $# == 2 && "$1" == --bootstrap-url ]] || die 'expected optional --bootstrap-url HTTPS_URL'
    bootstrap_url="$2"
  fi
  [[ "$bootstrap_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/%:-]+$ ]] || die 'invalid HTTPS bootstrap URL'
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib-lock.sh
  source "$root/lib-lock.sh"
  document="$(mktemp)"
  UPGRADE_DOCUMENT="$document"
  trap 'rm -f -- "$UPGRADE_DOCUMENT"' EXIT
  curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 30 \
    --max-filesize 262144 --output "$document" "$bootstrap_url"
  bash "$root/network-bootstrap.sh" software "$document" >/dev/null
  image="$(jq -er '.software.components.versiond.image' "$document")"
  platform="$(jq -er '.software.platform' "$document")"
  chain="$(jq -er '.chain_id' "$document")"
  if ! valid_image "$image" || ! valid_alias "$chain"; then die 'missing or invalid versiond selection'; fi
  sha="$(sha256sum "$document" | awk '{print $1}')"
  printf 'Host %s: versiond -> %s\nAll DevShard processes managed by this supervisor may briefly stop.\n' "$target" "$image"
  printf -v remote_command 'sudo -n bash -s -- --remote %q %q %q %q' "$image" "$platform" "$chain" "$sha"
  { declare -f gdc_lock_acquire gdc_lock_release; cat "${BASH_SOURCE[0]}"; } |
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$target" "$remote_command"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || "${1:-}" == --remote ]]; then
  main "$@"
fi
