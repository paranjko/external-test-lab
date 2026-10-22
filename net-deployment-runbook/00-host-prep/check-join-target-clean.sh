#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }

# BEGIN check-empty-generation-parent
check_empty_generation_parent() {
  local path="$1" mountpoint child
  if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
  if [[ -L "$path" || ! -d "$path" ]]; then
    printf 'JOIN_TARGET_NOT_CLEAN retained_node_state=%s\n' "$path"
    return 196
  fi
  mountpoint="$(stat -c %m -- "$path" 2>/dev/null)" || {
    printf 'JOIN_TARGET_NOT_CLEAN cannot_verify_generation_parent=%s\n' "$path"
    return 196
  }
  if [[ "$mountpoint" == "$path" ]]; then
    printf 'JOIN_TARGET_NOT_CLEAN mounted_generation_parent=%s\n' "$path"
    return 196
  fi
  child="$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || {
    printf 'JOIN_TARGET_NOT_CLEAN cannot_inspect_generation_parent=%s\n' "$path"
    return 196
  }
  if [[ -n "$child" ]]; then
    printf 'JOIN_TARGET_NOT_CLEAN retained_node_state=%s\n' "$child"
    return 196
  fi
  return 0
}
# END check-empty-generation-parent

usage() {
  echo 'Usage: check-join-target-clean.sh --host-alias ALIAS --role validator|ml-only-donor [--public-edge-owner]' >&2
  exit 2
}

host_alias=''
host_role=''
public_edge_owner=false
while (($#)); do
  case "$1" in
    --host-alias) [[ -n "${2:-}" ]] || usage; host_alias="$2"; shift 2 ;;
    --role) [[ -n "${2:-}" ]] || usage; host_role="$2"; shift 2 ;;
    --public-edge-owner) public_edge_owner=true; shift ;;
    *) usage ;;
  esac
done
[[ "$host_alias" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || usage
[[ "$host_role" == validator || "$host_role" == ml-only-donor ]] || usage
[[ "$public_edge_owner" != true || "$host_role" == validator ]] || usage

refuse() {
  printf 'JOIN_TARGET_NOT_CLEAN %s\n' "$1"
  exit 196
}

path_is_within() {
  local path="$1" root="$2"
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

check_monitoring_container() {
  local project="$1" service="$2" mounts="$3" expected
  [[ "$project" == gdc-monitoring-agent || "$project" == "gdc-monitoring-agent-$host_alias" ]] || return 1
  case "$service" in
    cadvisor)
      expected='[{"source":"/","destination":"/rootfs","rw":false},{"source":"/sys","destination":"/sys","rw":false},{"source":"/dev/disk","destination":"/dev/disk","rw":false},{"source":"/var/run","destination":"/var/run","rw":false},{"source":"/var/lib/docker","destination":"/var/lib/docker","rw":false}]'
      ;;
    node-exporter)
      expected='[{"source":"/","destination":"/host","rw":false},{"source":"/var/lib/node_exporter/textfile_collector","destination":"/textfile","rw":false}]'
      ;;
    *) return 1 ;;
  esac
  jq -e --argjson expected "$expected" '
    map({source:.Source,destination:.Destination,rw:.RW}) | sort_by(.destination)
      == ($expected | sort_by(.destination))
  ' <<<"$mounts" >/dev/null 2>&1 || return 1
  return 0
}

check_public_edge_container() {
  local project="$1" service="$2" mounts="$3" expected
  [[ "$public_edge_owner" == true ]] || return 1
  [[ "$project" == gdc-edge || "$project" == "gdc-edge-$host_alias" ]] || return 1
  case "$service" in
    public-grafana)
      expected='[{"source":"/srv/dai/edge/public-grafana/provisioning","destination":"/etc/grafana/provisioning","rw":false},{"source":"/srv/dai/edge/public-grafana/dashboards","destination":"/var/lib/grafana/dashboards","rw":false}]'
      ;;
    gateway-admission)
      expected='[{"source":"/srv/dai/edge/gateway-admission-proxy.py","destination":"/edge/gateway-admission-proxy.py","rw":false},{"source":"/srv/dai/edge/inference-diagnostics.py","destination":"/edge/inference-diagnostics.py","rw":false},{"source":"/srv/dai/edge/status","destination":"/edge/status","rw":true}]'
      ;;
    caddy)
      expected='[{"source":"/srv/dai/caddy/config","destination":"/config","rw":true},{"source":"/srv/dai/caddy/data","destination":"/data","rw":true},{"source":"/srv/dai/edge","destination":"/edge","rw":false},{"source":"/srv/dai/edge/Caddyfile","destination":"/etc/caddy/Caddyfile","rw":false},{"source":"/srv/dai/edge/site","destination":"/srv/dai/edge/site","rw":false}]'
      ;;
    gateway-route)
      expected='[{"source":"/srv/dai/edge/gateway-route-proxy.py","destination":"/edge/gateway-route-proxy.py","rw":false}]'
      ;;
    bootstrap)
      expected='[{"source":"/srv/dai/edge/join-bootstrap","destination":"/bootstrap","rw":false},{"source":"/srv/dai/edge/bootstrap-nginx.conf","destination":"/etc/nginx/conf.d/default.conf","rw":false}]'
      ;;
    *) return 1 ;;
  esac
  jq -e --argjson expected "$expected" '
    map({source:.Source,destination:.Destination,rw:.RW}) | sort_by(.destination)
      == ($expected | sort_by(.destination))
  ' <<<"$mounts" >/dev/null 2>&1 || return 1
  while IFS= read -r source; do
    [[ -e "$source" && ! -L "$source" && "$(realpath -e -- "$source" 2>/dev/null)" == "$source" ]] || return 1
  done < <(jq -r '.[].source' <<<"$expected")
}

# JOIN never reuses validator-owned state. The shared public edge is a narrow
# exception only for the configured public-edge Host: phase-join deliberately
# skips installing a participant edge there, leaving this TLS/data root intact.
protected_paths=(
  /srv/dai/deploy /srv/dai/data /srv/dai/identity /srv/dai/signer /srv/dai/agent
  /srv/dai/inference /srv/dai/node
)
if [[ "$public_edge_owner" == true ]]; then
  edge_root=/srv/dai/edge
  [[ -d "$edge_root" && ! -L "$edge_root" \
    && -f "$edge_root/compose.yaml" && ! -L "$edge_root/compose.yaml" \
    && -f "$edge_root/Caddyfile" && ! -L "$edge_root/Caddyfile" ]] \
    || refuse 'public_edge_layout_unverified=true'
else
  protected_paths+=(/srv/dai/edge)
fi
protected_mount_paths=("${protected_paths[@]}" /srv/dai/edge)
for path in "${protected_paths[@]}"; do
  if [[ -e "$path" || -L "$path" ]]; then
    refuse "retained_node_state=$path"
  fi
done

# The reset workflow may move the active generation itself while leaving its
# empty parent directory behind. Only that exact residue is reusable; mounted,
# non-directory, symlinked or non-empty paths remain a clean-target refusal.
check_empty_generation_parent /srv/dai/data.generations || exit $?

if command -v docker >/dev/null 2>&1; then
  running_ids="$(docker ps -q 2>/dev/null)" || refuse 'cannot_inspect_running_containers=true'
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    inspect="$(docker inspect "$container_id" 2>/dev/null)" || refuse 'cannot_inspect_running_container=true'
    container_name="$(jq -er '.[0].Name | ltrimstr("/")' <<<"$inspect" 2>/dev/null)" \
      || refuse 'container_name_unavailable=true'
    project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' <<<"$inspect")"
    service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // ""' <<<"$inspect")"
    mounts="$(jq -cer '.[0].Mounts | map({Source,Destination,RW})' <<<"$inspect" 2>/dev/null)" \
      || refuse "container_mounts_unavailable=$container_name"

    [[ "$project" != "$host_alias" ]] || refuse "validator_project_running=$project"
    if [[ "$project" =~ ^gdc-node[0-9]+(-ml)?$ ]]; then
      case "$service" in node|tmkms|mlnode|inference) refuse "validator_service_running=$service" ;; esac
    fi
    if [[ "$container_name" == *"$host_alias"* && ( -z "$project" || -z "$service" ) ]]; then
      refuse "host_container_unclassified=$container_name"
    fi

    if check_monitoring_container "$project" "$service" "$mounts"; then
      continue
    fi
    if [[ "$project" == gdc-monitoring-agent || "$project" == "gdc-monitoring-agent-$host_alias" ]]; then
      refuse "monitoring_container_layout_unverified=$service"
    fi
    if check_public_edge_container "$project" "$service" "$mounts"; then
      continue
    fi
    if [[ "$project" == gdc-edge || "$project" == "gdc-edge-$host_alias" ]]; then
      refuse "public_edge_container_layout_unverified=$service"
    fi

    [[ -n "$project" && -n "$service" ]] || refuse "container_owner_unverified=$container_name"
    while IFS= read -r source; do
      [[ -n "$source" ]] || continue
      source="$(realpath -m -- "$source")"
      for path in "${protected_mount_paths[@]}" /srv/dai/data.generations; do
        if path_is_within "$source" "$path" || path_is_within "$path" "$source"; then
          refuse "container_mount_overlaps_validator_state=$container_name"
        fi
      done
    done < <(jq -r '.[].Source' <<<"$mounts")
  done <<<"$running_ids"
fi

echo 'READY JOIN target is clean'
