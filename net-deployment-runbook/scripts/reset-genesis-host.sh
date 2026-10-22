#!/usr/bin/env bash
set -Eeuo pipefail

# Narrow Host-side reset for a fresh Genesis rebuild. This is intentionally
# separate from network reset: it never touches the independent OPS, broker,
# public edge, cache, or archive roots.
[[ $EUID -eq 0 ]] || { echo 'reset-genesis-host.sh must run as root' >&2; exit 1; }
[[ ( $# -eq 2 || ( $# -eq 4 && "$3" == --ml-project ) ) \
  && "$1" =~ ^gdc-node[0-9]+$ && "$2" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] \
  || { echo 'Usage: reset-genesis-host.sh gdc-nodeN YYYYMMDDTHHMMSSZ [--ml-project gdc-node4-ml]' >&2; exit 2; }
host="$1" stamp="$2"
short_host="${host#gdc-}"
ml_only=false
ml_project=''
if [[ $# -eq 4 ]]; then
  [[ "$host" == gdc-node9 && "$4" == gdc-node4-ml ]] \
    || { echo 'ML-only reset is permitted only for gdc-node9 with project gdc-node4-ml' >&2; exit 2; }
  ml_only=true
  ml_project="$4"
fi
data_root=/srv/dai
archive_root=/srv/dai-archives
archive="$archive_root/$stamp-$host"
if [[ "$ml_only" == true ]]; then
  projects=("$ml_project")
  managed_units=("gdc-poc-winddown-watch@$ml_project.service")
  move_roots=("/srv/dai/deploy/$ml_project")
else
  projects=("$host" "gdc-edge-$host" "gdc-monitoring-agent-$host")
  managed_units=(
    "gdc-poc-winddown-watch@$host.service"
    "gdc-version-collector@$host.timer"
    "gdc-version-collector@$host.service"
    "gdc-poc-winddown-watch@$short_host.service"
    "gdc-version-collector@$short_host.timer"
    "gdc-version-collector@$short_host.service"
  )
  move_roots=(/srv/dai/deploy /srv/dai/data "/srv/dai/$host" /srv/dai/identity /srv/dai/signer /srv/dai/shared)
fi
preserve_roots=(/srv/broker /srv/edge/node0 /srv/dai/ops /srv/dai/edge /srv/dai/broker-tests /srv/dai/hf-cache /srv/hf-cache /srv/dai/backups /srv/dai/recovery /srv/dai/caddy /srv/dai/monitoring-agent /srv/dai/identity-bootstrap)

die() { echo "reset-genesis-host: $*" >&2; exit 1; }
for command in docker jq findmnt systemctl stat mv readlink; do
  command -v "$command" >/dev/null 2>&1 || die "required Host command is unavailable: $command"
done
[[ -d "$data_root" && ! -L "$data_root" ]] || die 'canonical /srv/dai root is missing or unsafe'
[[ ! -e "$archive_root" || ( -d "$archive_root" && ! -L "$archive_root" ) ]] || die 'archive root is not a real directory'
[[ ! -e "$archive" && ! -L "$archive" ]] || die "archive destination already exists: $archive"

# Recognize only exact, observed legacy model-layout sidecar fingerprints.
# A lookalike with any different name, image, network, labels, or mount stays
# outside the inventory and blocks reset if it touches moved state.
is_approved_legacy_sidecar() {
  jq -e --arg host "$host" \
    --arg router_image 'sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609' \
    --arg mlnode_image 'sha256:1b9b7ce55feecab837f1d7ce974fc5f377ae0a04a4fb403eeeb50130e7728ee1' \
    --arg nginx_ref 'nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609' \
    '
      def exact_network($n): ((.NetworkSettings.Networks | keys) == [$n]);
      def exact_mount($src; $dst):
        (.Mounts | length) == 1 and .Mounts[0].Source == $src
        and .Mounts[0].Destination == $dst and .Mounts[0].RW == false;
      .[0] as $c |
      (
        ($host == "gdc-node2" or $host == "gdc-node10")
        and $c.Name == "/gdc-layout06-router"
        and $c.Config.Image == $router_image
        and $c.Config.Labels["gonka.layout"] == "three-models"
        and ($c.Config.Labels | has("com.docker.compose.project") | not)
        and ($c.Config.Labels | keys | sort) == ["gonka.layout", "maintainer"]
        and $c.Config.Labels.maintainer == "NGINX Docker Maintainers <docker-maint@nginx.com>"
        and ($c | exact_network($host + "_default"))
        and ($c | exact_mount("/srv/dai/deploy/.three-model-layout-sidecar/nginx.conf"; "/etc/nginx/nginx.conf"))
      ) or (
        $host == "gdc-node2"
        and $c.Name == "/gdc-layout06-mlnode"
        and $c.Config.Image == $mlnode_image
        and $c.Config.Labels["gonka.layout"] == "three-models"
        and ($c.Config.Labels | has("com.docker.compose.project") | not)
        and ($c | exact_network("gdc-node2_default"))
        and ($c | exact_mount("/srv/hf-cache/hub"; "/root/.cache/hub"))
      ) or (
        $host == "gdc-node11"
        and $c.Name == "/gdc-node11-dual-router4b-1"
        and $c.Config.Image == $nginx_ref
        and $c.Config.Labels["com.docker.compose.project"] == "gdc-node11-dual"
        and $c.Config.Labels["com.docker.compose.service"] == "router4b"
        and $c.Config.Labels["com.docker.compose.project.config_files"] == "/srv/dai/deploy/model-layout-7b-4b/compose.yaml"
        and $c.Config.Labels["com.docker.compose.project.working_dir"] == "/srv/dai/deploy/model-layout-7b-4b"
        and ($c | exact_network("gdc-node11_default"))
        and ($c | exact_mount("/srv/dai/deploy/model-layout-7b-4b/nginx.conf"; "/etc/nginx/nginx.conf"))
      )
    ' <<<"$1" >/dev/null 2>&1
}

generation_roots=()
generation_mounts=()
if [[ "$ml_only" == false && -L /srv/dai/data ]]; then
  raw_target="$(readlink /srv/dai/data)"
  case "$raw_target" in
    /srv/dai/data.generations/*) generation_id="${raw_target#/srv/dai/data.generations/}" ;;
    data.generations/*) generation_id="${raw_target#data.generations/}" ;;
    *) die "unsupported /srv/dai/data symlink target: $raw_target" ;;
  esac
  [[ "$generation_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "unsafe active data generation id: $generation_id"
  [[ -d /srv/dai/data.generations && ! -L /srv/dai/data.generations ]] \
    || die 'data.generations is not a real directory'
  active_generation="/srv/dai/data.generations/$generation_id"
  [[ -d "$active_generation" && ! -L "$active_generation" \
    && "$(readlink -e /srv/dai/data)" == "$active_generation" ]] \
    || die 'active data generation link does not resolve to an immediate real generation directory'
  generation_roots+=("$active_generation")
  generation_mounts+=(/srv/dai/data.generations)
fi

# Capture only generation directories named by the active data link or by a
# Docker bind belonging to this Host's explicitly managed projects. Never
# sweep the generations parent; unrelated, unbound generations stay put.
all_container_ids="$(docker ps -aq)" || die 'cannot enumerate all Docker containers'
legacy_sidecar_ids=()
while IFS= read -r container; do
  [[ -n "$container" ]] || continue
  inspect="$(docker inspect "$container")" || die "cannot inspect container $container"
  project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' <<<"$inspect")"
  if is_approved_legacy_sidecar "$inspect"; then legacy_sidecar_ids+=("$container"); fi
  [[ "$ml_only" == false ]] || continue
  while IFS= read -r source; do
    [[ "$source" == /srv/dai/data.generations/* ]] || continue
    relative="${source#/srv/dai/data.generations/}"
    generation_id="${relative%%/*}"
    [[ "$generation_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "unsafe Docker generation bind source: $source"
    allowed=false
    for managed in "${projects[@]}"; do [[ "$project" == "$managed" ]] && allowed=true; done
    [[ "$allowed" == true ]] \
      || die "container $container (project=${project:-unlabelled}) binds data generation: $source"
    generation_path="/srv/dai/data.generations/$generation_id"
    [[ -d "$generation_path" && ! -L "$generation_path" ]] \
      || die "Docker generation bind is not an immediate real generation directory: $source"
    generation_roots+=("$generation_path")
    generation_mounts+=(/srv/dai/data.generations)
  done < <(jq -r '.[0].Mounts[]?.Source // empty' <<<"$inspect")
done <<<"$all_container_ids"
# Both layouts have existed in the field. Only accept the canonical DATA_DIR,
# this Host's explicit legacy alias, or an exact managed generation child.
selected_data_generation=''
for env_file in /srv/dai/deploy/.env "/srv/dai/deploy/$host/.env"; do
  [[ "$ml_only" == false ]] || break
  [[ -f "$env_file" && ! -L "$env_file" ]] || continue
  value="$(awk -F= '$1 == "DATA_DIR" {print substr($0,index($0,"=")+1); exit}' "$env_file")"
  case "$value" in
    ''|/srv/dai/data|"/srv/dai/$host"|"/srv/dai/data/$host") ;;
    /srv/dai/data.generations/*)
      generation_id="${value#/srv/dai/data.generations/}"
      [[ "$generation_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || die "unrecognized DATA_DIR in $env_file: $value"
      if [[ -e /srv/dai/data.generations || -L /srv/dai/data.generations ]]; then
        [[ -d /srv/dai/data.generations && ! -L /srv/dai/data.generations ]] \
          || die "DATA_DIR generation parent is not a real directory: $value"
        [[ ! -L "$value" && ( ! -e "$value" || -d "$value" ) ]] \
          || die "DATA_DIR generation is not an immediate real directory: $value"
        generation_mounts+=(/srv/dai/data.generations)
        if [[ -d "$value" ]]; then generation_roots+=("$value"); fi
      fi
      [[ -z "$selected_data_generation" || "$selected_data_generation" == "$value" ]] \
        || die "conflicting DATA_DIR generation paths: $selected_data_generation and $value"
      selected_data_generation="$value"
      ;;
    *) die "unrecognized DATA_DIR in $env_file: $value" ;;
  esac
done

# Add only exact generation directories explicitly selected by the active
# symlink, a managed Docker bind, or DATA_DIR. Never move the generations
# parent or unrelated siblings.
if ((${#generation_roots[@]} > 0)); then
  mapfile -t generation_roots < <(printf '%s\n' "${generation_roots[@]}" | LC_ALL=C sort -u)
  move_roots+=("${generation_roots[@]}")
fi

for root in "${move_roots[@]}"; do
  if [[ "$root" == /srv/dai/data && -L "$root" ]]; then
    continue
  fi
  [[ ! -L "$root" ]] || die "refusing to archive symlink: $root"
  [[ ! -e "$root" || -d "$root" ]] || die "reset path is not a directory: $root"
done

# Reject child mounts under any path that will move. A rename across mount
# boundaries is not atomic and could leave chain state behind on the Host.
mountpoints="$(findmnt -rn -o TARGET)" || die 'cannot inspect Host mountpoints'
while IFS= read -r mountpoint; do
  for root in "${move_roots[@]}"; do
    [[ "$mountpoint" == "$root" || "$mountpoint" == "$root/"* ]] \
      && die "mounted path is inside reset archive scope: $mountpoint"
  done
  for root in "${generation_mounts[@]}"; do
    [[ "$mountpoint" == "$root" || "$mountpoint" == "$root/"* ]] \
      && die "mounted path is inside data.generations: $mountpoint"
  done
done <<<"$mountpoints"

declare -A preserved_identity=()
for path in "${preserve_roots[@]}"; do
  [[ ! -L "$path" ]] || die "preserved path is a symlink: $path"
  if [[ -e "$path" ]]; then
    preserved_identity["$path"]="$(stat -c '%d:%i' "$path")"
  fi
done

# Inspect every running container before any mutation. Unknown containers may
# not retain bind mounts into data that is about to move.
container_ids="$(docker ps -q)" || die 'cannot enumerate running containers'
while IFS= read -r container; do
  [[ -n "$container" ]] || continue
  inspect="$(docker inspect "$container")" || die "cannot inspect running container $container"
  project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' <<<"$inspect")"
  while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    owned=false
    for root in "${move_roots[@]}"; do
      [[ "$source" == "$root" || "$source" == "$root/"* ]] && owned=true
    done
    if [[ "$owned" == true ]]; then
      allowed=false
      for managed in "${projects[@]}"; do [[ "$project" == "$managed" ]] && allowed=true; done
      if [[ "$allowed" == false ]]; then
        for sidecar in "${legacy_sidecar_ids[@]}"; do
          [[ "$container" == "$sidecar" ]] && allowed=true
        done
      fi
      [[ "$allowed" == true ]] || die "running non-reset container $container (project=${project:-unlabelled}) binds reset data: $source"
    fi
  done < <(jq -r '.[0].Mounts[]?.Source // empty' <<<"$inspect")
done <<<"$container_ids"

# Snapshot the exact project-owned container IDs and mounts for the immutable
# receipt. Generic monitoring-agent is deliberately not a target project.
declare -a managed_ids=()
for project in "${projects[@]}"; do
  mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=$project")
  for container in "${ids[@]}"; do
    [[ -n "$container" ]] || continue
    inspect="$(docker inspect "$container")" || die "cannot inspect managed container $container"
    actual_project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' <<<"$inspect")"
    [[ "$actual_project" == "$project" ]] || die "container label mismatch for $container"
    managed_ids+=("$container")
  done
done
for container in "${legacy_sidecar_ids[@]}"; do
  [[ -n "$container" ]] || continue
  already_added=false
  for existing in "${managed_ids[@]}"; do [[ "$existing" == "$container" ]] && already_added=true; done
  [[ "$already_added" == true ]] || managed_ids+=("$container")
done

if [[ ! -e "$archive_root" ]]; then mkdir -m 0700 "$archive_root"; fi
mkdir -m 0700 "$archive"
intent="$archive/reset-genesis-intent.json"
jq -n -S \
  --arg host "$host" --arg stamp "$stamp" --arg archive "$archive" \
  --argjson projects "$(printf '%s\n' "${projects[@]}" | jq -R . | jq -s .)" \
  --argjson sidecars "$(printf '%s\n' "${legacy_sidecar_ids[@]}" | jq -R . | jq -s .)" \
  --argjson paths "$(printf '%s\n' "${move_roots[@]}" | jq -R . | jq -s .)" \
  '{schema_version:1,kind:"gdc-new-genesis-reset-intent",host:$host,started_utc:$stamp,archive:$archive,projects:$projects,legacy_sidecar_ids:$sidecars,paths:$paths}' \
  >"$intent"
chmod 0444 "$intent"
reset_complete=false
record_interrupted_reset() {
  local rc=$? paths='[]' root name destination source_present archive_present
  trap - EXIT
  [[ "$reset_complete" == true || ! -d "$archive" || -e "$archive/reset-genesis-receipt.json" ]] && return "$rc"
  for root in "${move_roots[@]}"; do
    name="${root#/srv/dai/}"
    [[ "$root" == /srv/dai/deploy ]] && name=deploy
    destination="$archive/$name"
    source_present=false; archive_present=false
    [[ ! -e "$root" && ! -L "$root" ]] || source_present=true
    [[ ! -e "$destination" && ! -L "$destination" ]] || archive_present=true
    paths="$(jq -c --arg source "$root" --arg destination "$destination" \
      --argjson source_present "$source_present" --argjson archive_present "$archive_present" \
      '. + [{source:$source,archive:$destination,source_present:$source_present,archive_present:$archive_present}]' <<<"$paths")"
  done
  jq -n -S --arg host "$host" --arg stamp "$stamp" --arg archive "$archive" \
    --argjson exit_code "$rc" --argjson paths "$paths" \
    '{schema_version:1,kind:"gdc-new-genesis-reset-interrupted",host:$host,started_utc:$stamp,archive:$archive,exit_code:$exit_code,path_states:$paths}' \
    >"$archive/reset-genesis-interrupted.json" || true
  chmod 0444 "$archive/reset-genesis-interrupted.json" 2>/dev/null || true
  return "$rc"
}
trap record_interrupted_reset EXIT

unit_json='[]'
for unit in "${managed_units[@]}"; do
  if ! systemctl disable --now "$unit" >/dev/null 2>&1; then
    unit_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    case "$unit_state" in
      active|activating|reloading) die "managed Host unit remains active after stop attempt: $unit" ;;
    esac
  fi
  unit_json="$(jq -c --arg unit "$unit" '. + [{unit:$unit,final_state:"inactive"}]' <<<"$unit_json")"
done

for container in "${managed_ids[@]}"; do
  state="$(docker inspect -f '{{.State.Status}}' "$container")" || die "cannot read state of $container"
  [[ "$state" != running ]] || docker stop "$container" >/dev/null
  docker update --restart=no "$container" >/dev/null \
    || die "cannot disable restart policy for managed container $container"
  restart_policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container")" \
    || die "cannot read restart policy for managed container $container"
  [[ "$restart_policy" == no ]] \
    || die "managed container restart policy is not disabled: $container ($restart_policy)"
done

# Confirm no other running Docker container retained a bind to moved state
# after the managed projects stopped.
container_ids="$(docker ps -q)" || die 'cannot re-enumerate running containers'
while IFS= read -r container; do
  [[ -n "$container" ]] || continue
  inspect="$(docker inspect "$container")" || die "cannot inspect running container $container after stop"
  project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' <<<"$inspect")"
  while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    for root in "${move_roots[@]}"; do
      if [[ "$source" == "$root" || "$source" == "$root/"* ]]; then
        die "running container $container (project=${project:-unlabelled}) still binds reset data: $source"
      fi
    done
  done < <(jq -r '.[0].Mounts[]?.Source // empty' <<<"$inspect")
done <<<"$container_ids"

# Also catch host processes holding files or a working directory below the
# roots to be renamed. Container bind ownership is checked separately above.
for proc in /proc/[0-9]*; do
  [[ -d "$proc" ]] || continue
  for handle in "$proc"/cwd "$proc"/fd/*; do
    [[ -e "$handle" || -L "$handle" ]] || continue
    target="$(readlink "$handle" 2>/dev/null || true)"
    target="${target% (deleted)}"
    for root in "${move_roots[@]}"; do
      [[ "$target" == "$root" || "$target" == "$root/"* ]] \
        || continue
      die "Host process ${proc##*/} still references reset data: $target"
    done
  done
done

before_json='[]'
for root in "${move_roots[@]}"; do
  [[ ! -e "$root" && ! -L "$root" ]] && continue
  identity="$(stat -c '%d:%i' "$root")"
  before_json="$(jq -c --arg path "$root" --arg identity "$identity" '. + [{path:$path,device_inode:$identity}]' <<<"$before_json")"
done

for root in "${move_roots[@]}"; do
  [[ -e "$root" || -L "$root" ]] || continue
  name="${root#/srv/dai/}"
  [[ "$root" == /srv/dai/deploy ]] && name=deploy
  destination="$archive/$name"
  [[ ! -e "$destination" && ! -L "$destination" ]] || die "archive path collision: $destination"
  mkdir -p "$(dirname "$destination")"
  mv -- "$root" "$destination"
done

after_json='[]'
while IFS=$'\t' read -r source identity; do
  [[ -n "$source" ]] || continue
  name="${source#/srv/dai/}"
  [[ "$source" == /srv/dai/deploy ]] && name=deploy
  destination="$archive/$name"
  [[ ( -e "$destination" || -L "$destination" ) \
    && "$(stat -c '%d:%i' "$destination")" == "$identity" ]] \
    || die "archive move verification failed: $source -> $destination"
  after_json="$(jq -c --arg before "$source" --arg after "$destination" --arg identity "$identity" '. + [{before:$before,after:$after,device_inode:$identity}]' <<<"$after_json")"
done < <(jq -r '.[] | [.path,.device_inode] | @tsv' <<<"$before_json")

for path in "${!preserved_identity[@]}"; do
  [[ -e "$path" && ! -L "$path" && "$(stat -c '%d:%i' "$path")" == "${preserved_identity[$path]}" ]] \
    || die "preserved path changed during reset: $path"
done

containers_json='[]'
for container in "${managed_ids[@]}"; do
  legacy_sidecar=false
  for sidecar in "${legacy_sidecar_ids[@]}"; do [[ "$container" == "$sidecar" ]] && legacy_sidecar=true; done
  containers_json="$(jq -c --arg id "$container" \
    --arg state "$(docker inspect -f '{{.State.Status}}' "$container")" \
    --arg restart_policy "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container")" \
    --argjson legacy_sidecar "$legacy_sidecar" \
    '. + [{id:$id,final_state:$state,restart_policy:$restart_policy,legacy_sidecar:$legacy_sidecar}]' <<<"$containers_json")"
done
jq -n -S \
  --arg host "$host" --arg stamp "$stamp" --arg archive "$archive" \
  --argjson projects "$(printf '%s\n' "${projects[@]}" | jq -R . | jq -s .)" \
  --argjson moved "$after_json" --argjson containers "$containers_json" --argjson units "$unit_json" \
  --argjson preserved "$(printf '%s\n' "${!preserved_identity[@]}" | jq -R . | jq -s .)" \
  '{schema_version:1,kind:"gdc-new-genesis-reset-receipt",host:$host,completed_utc:$stamp,archive:$archive,projects:$projects,systemd_units:$units,containers:$containers,moved_paths:$moved,preserved_paths:$preserved}' \
  >"$archive/reset-genesis-receipt.json"
chmod 0444 "$archive/reset-genesis-receipt.json"
reset_complete=true
trap - EXIT
printf 'PASS new-Genesis Host reset host=%s archive=%s receipt=%s\n' "$host" "$archive" "$archive/reset-genesis-receipt.json"
